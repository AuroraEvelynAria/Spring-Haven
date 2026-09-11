extends Node3D

const TEXT_SANITIZER := preload("res://scripts/domain/TextSanitizer.gd")
const DIALOG_SCENE_PATH := "res://scenes/GameWorld/GameWorld.tscn"
const PLAYER_SPAWN := Vector3(-2.5, 0.05, 2.7)
const LING_SPAWN := Vector3(-1.1, 0.05, 2.6)
const NAVIGATION_BAKE_TIMEOUT_SECONDS := 15.0
const CHAT_ROLE_ID := "ling"
const CHAT_TEXT_LIMIT := 3000
const CHAT_LOG_LINE_LIMIT := 6
const CHAT_LOG_TEXT_LIMIT := 260

var _navigation_ready := false
var _navigation_sync_pending := false
var _returning_to_dialog := false
var _recovering_bodies: Dictionary = {}
var _ai_waiting := false
var _thinking_elapsed := 0.0
var _thinking_step := -1
var _pending_ai_request_id := ""
var _pending_user_message_id := ""
var _pending_scene_actions: Array[Dictionary] = []
var _chat_log_lines: Array[String] = []
var _wander_elapsed := 0.0
var _next_wander_seconds := 45.0
var _wander_rng := RandomNumberGenerator.new()
var _plant_photo_pending := false
var _global_state: Node
var _global_state_configured := false

@onready var _navigation_region: NavigationRegion3D = $NavigationRegion3D
@onready var _graybox_room: Node3D = $NavigationRegion3D/GrayboxRoom
@onready var _local_room_visual: Node3D = $LocalRoomVisual
@onready var _sun: DirectionalLight3D = $Sun
@onready var _living_warm_light: OmniLight3D = $LivingWarmLight
@onready var _dining_warm_light: OmniLight3D = $DiningWarmLight
@onready var _player: CharacterBody3D = $Player3D
@onready var _ling_agent: CharacterBody3D = $LingAgent3D
@onready var _dining_anchor: Marker3D = $NavigationRegion3D/GrayboxRoom/DiningSeatLing
@onready var _sofa_anchor: Marker3D = $NavigationRegion3D/GrayboxRoom/SofaSpot
@onready var _plant_photo_anchor: Marker3D = $NavigationRegion3D/GrayboxRoom/PlantPhotoSpot
@onready var _kill_plane: Area3D = $KillPlane
@onready var _ai_controller: ExplorationAIController = $ExplorationAIController

@onready var _return_button: Button = $HUD/SafeMargin/CommandPanel/PanelMargin/Commands/ReturnButton
@onready var _dining_button: Button = $HUD/SafeMargin/CommandPanel/PanelMargin/Commands/DiningButton
@onready var _sofa_button: Button = $HUD/SafeMargin/CommandPanel/PanelMargin/Commands/SofaButton
@onready var _follow_button: Button = $HUD/SafeMargin/CommandPanel/PanelMargin/Commands/FollowButton
@onready var _stop_button: Button = $HUD/SafeMargin/CommandPanel/PanelMargin/Commands/StopButton
@onready var _status_label: Label = $HUD/SafeMargin/CommandPanel/PanelMargin/Commands/StatusLabel
@onready var _chat_log: RichTextLabel = $HUD/SafeMargin/CommandPanel/PanelMargin/Commands/ChatLog
@onready var _chat_input: LineEdit = $HUD/SafeMargin/CommandPanel/PanelMargin/Commands/ChatInputRow/ChatInput
@onready var _chat_send_button: Button = $HUD/SafeMargin/CommandPanel/PanelMargin/Commands/ChatInputRow/ChatSendButton
@onready var _ai_waiting_label: Label = $HUD/SafeMargin/CommandPanel/PanelMargin/Commands/AIWaitingLabel


func _ready() -> void:
	_wander_rng.randomize()
	_next_wander_seconds = _random_exploration_interval()
	if not _global_state_configured:
		_global_state = get_node_or_null("/root/Global")
	_player.global_position = PLAYER_SPAWN
	_ling_agent.global_position = LING_SPAWN
	_connect_interface()
	var life_sim := get_node_or_null("/root/LifeSim")
	if is_instance_valid(life_sim) and life_sim.has_signal("autonomous_action"):
		life_sim.connect("autonomous_action", Callable(self, "_on_life_autonomous_action"))
	_restore_chat_log()
	_set_ai_waiting(false)
	_set_command_buttons_enabled(false)
	_show_status("正在从房间碰撞体烘焙导航网格……", Color("e8c67a"))
	_bake_navigation.call_deferred()
	_watch_navigation_bake.call_deferred()


func set_global_state_node(global_state: Node) -> void:
	_global_state_configured = true
	_global_state = global_state
	var controller := get_node_or_null("ExplorationAIController") as ExplorationAIController
	if controller != null:
		controller.set_global_state_node(global_state)


func _physics_process(_delta: float) -> void:
	# Area3D 是主要兜底；额外的高度检查避免高速穿过检测区后无限下坠。
	if _player.global_position.y < -12.0:
		_queue_character_recovery(_player, PLAYER_SPAWN, "玩家")
	if _ling_agent.global_position.y < -12.0:
		_queue_character_recovery(_ling_agent, LING_SPAWN, "小玲")


func _process(delta: float) -> void:
	_update_autonomous_exploration(delta)
	if not _ai_waiting:
		return
	_thinking_elapsed += delta
	var step := int(floor(_thinking_elapsed / 0.42)) % 4
	if step == _thinking_step:
		return
	_thinking_step = step
	var dots := ".".repeat(step)
	_ai_waiting_label.text = "● DeepSeek-V4-Flash · 小玲思考中%s" % dots
	var pulse_color := Color("9ed6e8")
	pulse_color.a = 0.62 + 0.28 * sin(_thinking_elapsed * 3.6)
	_ai_waiting_label.modulate = pulse_color


func _connect_interface() -> void:
	_return_button.pressed.connect(_on_return_button_pressed)
	_dining_button.pressed.connect(_on_dining_button_pressed)
	_sofa_button.pressed.connect(_on_sofa_button_pressed)
	_follow_button.pressed.connect(_on_follow_button_pressed)
	_stop_button.pressed.connect(_on_stop_button_pressed)
	_chat_send_button.pressed.connect(_on_chat_send_button_pressed)
	_chat_input.text_submitted.connect(_on_chat_input_submitted)
	_kill_plane.body_entered.connect(_on_kill_plane_body_entered)
	if _ling_agent.has_signal("action_state_changed"):
		_ling_agent.connect("action_state_changed", Callable(self, "_on_ling_action_state_changed"))
	if _ling_agent.has_signal("destination_reached"):
		_ling_agent.connect("destination_reached", Callable(self, "_on_ling_destination_reached"))
	_ai_controller.status_changed.connect(_on_ai_status_changed)
	_ai_controller.reply_ready.connect(_on_ai_reply_ready)
	_ai_controller.action_applied.connect(_on_ai_action_applied)
	if _local_room_visual.has_signal("load_finished"):
		_local_room_visual.connect("load_finished", Callable(self, "_on_local_room_load_finished"))


func _on_local_room_load_finished(success: bool, _resource_path: String) -> void:
	if _graybox_room.has_method("set_visuals_visible"):
		_graybox_room.call("set_visuals_visible", not success)
	var using_baked_lightmap := (
		success
		and _local_room_visual.has_method("is_using_baked_lightmap")
		and bool(_local_room_visual.call("is_using_baked_lightmap"))
	)
	# The baked local scene contains its own static lights. Keep the outer lights
	# only for the plain-GLB fallback, otherwise the room is lit twice.
	_sun.visible = not using_baked_lightmap
	_living_warm_light.visible = not using_baked_lightmap
	_dining_warm_light.visible = not using_baked_lightmap
	if success and _navigation_ready:
		var lighting_label := "预烘焙光照" if using_baked_lightmap else "实时补光"
		_show_status("正式客餐厅已加载 · %s · 导航已就绪" % lighting_label, Color("9ed6bd"))


func _bake_navigation() -> void:
	var navigation_mesh := _navigation_region.navigation_mesh
	if navigation_mesh == null:
		navigation_mesh = NavigationMesh.new()
		_navigation_region.navigation_mesh = navigation_mesh

	# Match the 5 cm voxel grid exactly to avoid bake rounding warnings.
	navigation_mesh.agent_height = 1.65
	navigation_mesh.agent_radius = 0.30
	navigation_mesh.agent_max_climb = 0.25
	navigation_mesh.agent_max_slope = 42.0
	navigation_mesh.cell_size = 0.05
	navigation_mesh.cell_height = 0.05
	navigation_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	navigation_mesh.geometry_source_geometry_mode = (
		NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	)
	navigation_mesh.geometry_collision_mask = 1
	var navigation_map := _navigation_region.get_navigation_map()
	NavigationServer3D.map_set_cell_size(navigation_map, navigation_mesh.cell_size)
	NavigationServer3D.map_set_cell_height(navigation_map, navigation_mesh.cell_height)

	if not _navigation_region.bake_finished.is_connected(_on_navigation_bake_finished):
		_navigation_region.bake_finished.connect(_on_navigation_bake_finished, CONNECT_ONE_SHOT)
	_navigation_region.bake_navigation_mesh(true)


func _on_navigation_bake_finished() -> void:
	var navigation_mesh := _navigation_region.navigation_mesh
	if navigation_mesh == null or navigation_mesh.get_vertices().is_empty():
		_navigation_ready = false
		_show_status("导航网格为空：请检查灰盒碰撞层。", Color("ef8b7a"))
		push_error("ExplorationWorld：运行时导航网格烘焙完成，但没有生成顶点。")
		return

	# 先让 bake_finished 的信号栈完整返回，NavigationRegion 才会把新资源提交给服务器。
	if not _navigation_sync_pending:
		_navigation_sync_pending = true
		_finalize_navigation_after_map_sync.call_deferred()


func _finalize_navigation_after_map_sync() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	if not is_inside_tree():
		return
	var navigation_map := _navigation_region.get_navigation_map()
	if navigation_map.is_valid():
		NavigationServer3D.map_force_update(navigation_map)
	await get_tree().physics_frame
	if not is_inside_tree():
		return
	_navigation_sync_pending = false
	_navigation_ready = true
	_set_command_buttons_enabled(true)
	_show_status("导航已就绪 · 小玲：待命", Color("9ed6bd"))


func _watch_navigation_bake() -> void:
	await get_tree().create_timer(NAVIGATION_BAKE_TIMEOUT_SECONDS).timeout
	if not is_inside_tree() or _navigation_ready:
		return
	_set_command_buttons_enabled(false)
	_show_status("导航准备超时，可返回对话后重试。", Color("ef8b7a"))
	push_warning("ExplorationWorld：导航网格烘焙超过 15 秒。")


func _on_dining_button_pressed() -> void:
	_issue_move_command(_dining_anchor, "餐桌")
	_release_button_focus(_dining_button)


func _on_sofa_button_pressed() -> void:
	_issue_move_command(_sofa_anchor, "沙发")
	_release_button_focus(_sofa_button)


func _issue_move_command(anchor: Node3D, label_text: String) -> void:
	if not _navigation_ready:
		_show_status("导航仍在准备，请稍候。", Color("e8c67a"))
		return
	if not _ling_agent.has_method("command_move_to"):
		_show_status("小玲控制器缺少 command_move_to 接口。", Color("ef8b7a"))
		return
	_show_status("已下达指令：小玲前往%s。" % label_text, Color("d8e5ee"))
	_ling_agent.call("command_move_to", anchor.global_position, label_text)


func _on_follow_button_pressed() -> void:
	if not _navigation_ready:
		_show_status("导航仍在准备，请稍候。", Color("e8c67a"))
		return
	if _ling_agent.has_method("command_follow"):
		_show_status("小玲开始跟随玩家。", Color("d8e5ee"))
		_ling_agent.call("command_follow", _player)
	else:
		_show_status("小玲控制器缺少 command_follow 接口。", Color("ef8b7a"))
	_release_button_focus(_follow_button)


func _on_stop_button_pressed() -> void:
	if _ling_agent.has_method("command_stop"):
		_show_status("小玲已停止，保持待命。", Color("d8e5ee"))
		_ling_agent.call("command_stop")
	else:
		_show_status("小玲控制器缺少 command_stop 接口。", Color("ef8b7a"))
	_release_button_focus(_stop_button)


func _on_chat_send_button_pressed() -> void:
	_send_scene_chat()
	_release_button_focus(_chat_send_button)


func _on_chat_input_submitted(_submitted_text: String) -> void:
	_send_scene_chat()


func _send_scene_chat() -> void:
	var message := _normalize_chat_text(_chat_input.text, CHAT_TEXT_LIMIT)
	if message.is_empty():
		_show_status("消息不能为空。", Color("e8c67a"))
		return
	if _ai_waiting or _ai_controller.has_pending_request():
		_show_status("小玲仍在思考；当前输入已保留，稍后可以再发送。", Color("e8c67a"))
		return
	if not is_instance_valid(_global_state):
		_show_status("共享对话状态尚未就绪。", Color("ef8b7a"))
		return
	var life_sim := get_node_or_null("/root/LifeSim")
	if is_instance_valid(life_sim) and life_sim.has_method("note_user_activity"):
		life_sim.call("note_user_activity")

	var message_id := str(_global_state.call("new_local_id", "user"))
	var entry := {
		"id": message_id,
		"sender": "user",
		"role": CHAT_ROLE_ID,
		"target_role": CHAT_ROLE_ID,
		"text": message,
		"status": "pending",
		"event_type": "chat",
		"kind": "exploration_chat",
		"source_scene": "living_dining_room",
		"retryable": true,
		"created_at": int(Time.get_unix_time_from_system()),
	}
	if not _append_history_entry_transactional(entry):
		_show_status("消息未能写入共享对话记录：%s" % _global_save_error(), Color("ef8b7a"))
		return

	_pending_user_message_id = message_id
	_pending_scene_actions.clear()
	_append_chat_log_line("你", message)
	var request_id := _ai_controller.send_player_message(message)
	if request_id.is_empty():
		_finish_ai_failure("未能创建小玲的 Companion Core 请求")
		return

	_pending_ai_request_id = request_id
	_chat_input.clear()
	_set_ai_waiting(true)
	_show_status("消息已发送；你仍可移动、观察和使用场景按钮。", Color("9ed6bd"))

func _update_autonomous_exploration(delta: float) -> void:
	if not _navigation_ready or _ai_waiting:
		return
	_wander_elapsed += delta
	if _wander_elapsed < _next_wander_seconds:
		return
	_wander_elapsed = 0.0
	_next_wander_seconds = _random_exploration_interval()
	if not _ling_agent.has_method("get_action_state") or not _ling_agent.has_method("command_move_to"):
		return
	var state_variant = _ling_agent.call("get_action_state")
	if not state_variant is Dictionary:
		return
	var mode := str((state_variant as Dictionary).get("mode", "idle"))
	var status := str((state_variant as Dictionary).get("status", "idle"))
	if mode != "idle" or status in ["navigating", "following", "replanning", "recovering"]:
		return
	var destination_index := _wander_rng.randi_range(0, 2)
	var target: Marker3D = _dining_anchor
	var label := "餐桌附近"
	match destination_index:
		1:
			target = _sofa_anchor
			label = "沙发附近"
		2:
			target = _plant_photo_anchor
			label = "绿植旁"
	_ling_agent.call("command_move_to", target.global_position, label)
	_show_status("小玲正在房间里随意走走。", Color("9ed6bd"))

func _random_exploration_interval() -> float:
	var minimum := float(Settings.get_runtime_tuning_value("exploration_min_seconds", 45))
	var maximum := float(Settings.get_runtime_tuning_value("exploration_max_seconds", 120))
	return _wander_rng.randf_range(minimum, maxf(minimum, maximum))

func _on_ling_destination_reached(label: String, _position: Vector3) -> void:
	if label != "绿植旁" or _plant_photo_pending:
		return
	_plant_photo_pending = true
	_capture_and_share_plant_photo.call_deferred()

func _capture_and_share_plant_photo() -> void:
	var sub_viewport := SubViewport.new()
	sub_viewport.name = "PlantPhotoViewport"
	sub_viewport.size = Vector2i(640, 360)
	sub_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	sub_viewport.world_3d = get_world_3d()
	add_child(sub_viewport)
	var camera := Camera3D.new()
	camera.fov = 48.0
	camera.near = 0.05
	camera.far = 30.0
	sub_viewport.add_child(camera)
	var subject_position := _plant_photo_anchor.global_position + Vector3(0.78, 0.9, -0.04)
	var camera_position := _plant_photo_anchor.global_position + Vector3(-1.55, 1.35, 1.65)
	camera.look_at_from_position(camera_position, subject_position, Vector3.UP)
	camera.current = true
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var photo_result: Dictionary = {}
	var photos := get_node_or_null("/root/Photos")
	if is_instance_valid(photos) and photos.has_method("capture_viewport"):
		var photo_variant = photos.call("capture_viewport", sub_viewport, "ling", "house_plant")
		if photo_variant is Dictionary:
			photo_result = photo_variant
	sub_viewport.queue_free()
	_plant_photo_pending = false
	if not bool(photo_result.get("ok", false)):
		_show_status("小玲想给绿植拍照，但本地相册写入失败。", Color("e8c67a"))
		return
	var visual_summary := ""
	var vision := get_node_or_null("/root/Vision")
	if is_instance_valid(vision) and vision.has_method("discover_model"):
		var discovery_variant = await vision.call("discover_model")
		if not is_inside_tree():
			return
		if discovery_variant is Dictionary and bool((discovery_variant as Dictionary).get("ok", false)):
			var vision_variant = await vision.call(
				"describe_image",
				str(photo_result.get("absolute_path", "")),
				{"subject": "house_plant", "symbolic_state": "叶片良好，盆土略干"}
			)
			if not is_inside_tree():
				return
			if vision_variant is Dictionary and bool((vision_variant as Dictionary).get("ok", false)):
				visual_summary = str((vision_variant as Dictionary).get("text", "")).strip_edges().left(800)
	var life_sim := get_node_or_null("/root/LifeSim")
	if is_instance_valid(life_sim) and life_sim.has_method("request_proactive_message"):
		life_sim.call("request_proactive_message", "ling", "plant_photo", {
			"photo_path": str(photo_result.get("path", "")),
			"photo_name": str(photo_result.get("absolute_path", "")).get_file(),
			"visual_summary": visual_summary,
		})
	_show_status("小玲给绿植拍了张照片，已存入本地相册。", Color("9ed6bd"))

func _on_life_autonomous_action(event: Dictionary) -> void:
	if str(event.get("role_id", "")) != "ling" or not _navigation_ready:
		return
	var scene_action_variant = event.get("scene_action", {})
	if scene_action_variant is Dictionary:
		var scene_action: Dictionary = scene_action_variant
		if int(scene_action.get("schema_version", 0)) == 1 and str(scene_action.get("action", "")) == "move_to":
			var target_id := str(scene_action.get("target_id", ""))
			if target_id == "dining_table":
				_ling_agent.call("command_move_to", _dining_anchor.global_position, "自主生活 · 餐桌")
				_append_chat_log_line("生活", str(event.get("description", "小玲去餐桌边照顾自己")))
				return
			if target_id == "sofa":
				_ling_agent.call("command_move_to", _sofa_anchor.global_position, "自主生活 · 沙发")
				_append_chat_log_line("生活", str(event.get("description", "小玲去沙发边休息")))
				return
	var action := str(event.get("action", ""))
	match action:
		"eat", "drink", "home_check", "evening_home_check", "morning_window_watch", "night_patrol":
			_ling_agent.call("command_move_to", _dining_anchor.global_position, "自主生活 · 餐桌")
		"rest", "sunbathe", "read_by_window", "quiet_curl", "gentle_rest", "quiet_companion", "comfort_partner":
			_ling_agent.call("command_move_to", _sofa_anchor.global_position, "自主生活 · 沙发")
		_:
			return
	_append_chat_log_line("生活", str(event.get("description", "小玲开始照顾自己")))


func _on_ai_status_changed(status: String, message: String) -> void:
	match status:
		"waiting_reply":
			_set_ai_waiting(true)
		"busy":
			_show_status(message, Color("e8c67a"))
		"failed", "unavailable":
			_finish_ai_failure(message)
		"rejected":
			if not _pending_user_message_id.is_empty():
				_finish_ai_failure(message)
			else:
				_show_status(message, Color("e8c67a"))
		"action_rejected", "action_failed":
			# 动作失败不应吞掉文本回复；让对话请求继续完成。
			_show_status("小玲没有执行场景动作：%s" % message, Color("e8c67a"))


func _on_ai_action_applied(action: Dictionary) -> void:
	var safe_action := action.duplicate(true)
	_pending_scene_actions.append(safe_action)
	var description := _describe_scene_action(safe_action)
	_append_chat_log_line("场景", description)
	_show_status(description, Color("9ed6bd"))


func _on_ai_reply_ready(text: String) -> void:
	var reply_text := _normalize_chat_text(text, CHAT_TEXT_LIMIT)
	if reply_text.is_empty():
		_finish_ai_failure("小玲返回了空回复")
		return
	var saved := _commit_ai_reply_transactionally(reply_text)
	_append_chat_log_line("小玲", reply_text + ("" if saved else "（本地保存失败）"))
	_pending_ai_request_id = ""
	_pending_user_message_id = ""
	_pending_scene_actions.clear()
	_set_ai_waiting(false)
	if saved:
		_show_status("已收到小玲回复；共享上下文已保存。", Color("9ed6bd"))
	else:
		_show_status("已收到回复，但共享对话保存失败：%s" % _global_save_error(), Color("ef8b7a"))


func _set_ai_waiting(waiting: bool) -> void:
	_ai_waiting = waiting
	_thinking_elapsed = 0.0
	_thinking_step = -1
	# 等待期间不禁用输入、移动或任何场景按钮，使用动态状态点表达忙碌。
	_chat_input.editable = true
	_chat_send_button.disabled = false
	_chat_send_button.text = "发送"
	_ai_waiting_label.modulate = Color.WHITE
	if waiting:
		_ai_waiting_label.text = "● DeepSeek-V4-Flash · 小玲思考中"
	else:
		_ai_waiting_label.text = "● DeepSeek-V4-Flash · 无视觉 · 就绪"


func _finish_ai_failure(message: String) -> void:
	var failure_message := _normalize_chat_text(message, 500)
	if failure_message.is_empty():
		failure_message = "Companion Core 请求失败"
	if not _pending_user_message_id.is_empty():
		_mark_history_message_failed(_pending_user_message_id, failure_message)
	_pending_ai_request_id = ""
	_pending_user_message_id = ""
	_pending_scene_actions.clear()
	_set_ai_waiting(false)
	_show_status("小玲回复失败：%s" % failure_message, Color("ef8b7a"))


func _append_history_entry_transactional(entry: Dictionary) -> bool:
	if not is_instance_valid(_global_state):
		return false
	var previous_history := _get_shared_history()
	if not bool(_global_state.call("append_conversation_entry", entry, false)):
		return false
	if bool(_global_state.call("save_default_state")):
		return true
	_global_state.set("conversation_history", previous_history)
	return false


func _commit_ai_reply_transactionally(reply_text: String) -> bool:
	if not is_instance_valid(_global_state):
		return false
	var previous_history := _get_shared_history()
	if (
		not _pending_user_message_id.is_empty()
		and not bool(_global_state.call(
			"update_conversation_entry",
			_pending_user_message_id,
			{"status": "sent", "retryable": false, "error": ""},
			false
		))
	):
		return false
	var reply_entry := {
		"id": str(_global_state.call("new_local_id", "ai")),
		"sender": "ai",
		"role": CHAT_ROLE_ID,
		"text": reply_text,
		"status": "sent",
		"event_type": "chat",
		"kind": "exploration_reply",
		"source_scene": "living_dining_room",
		"in_reply_to": _pending_user_message_id,
		"created_at": int(Time.get_unix_time_from_system()),
	}
	if not _pending_scene_actions.is_empty():
		reply_entry["scene_actions"] = _pending_scene_actions.duplicate(true)
	if not bool(_global_state.call("append_conversation_entry", reply_entry, false)):
		_global_state.set("conversation_history", previous_history)
		return false
	if bool(_global_state.call("save_default_state")):
		return true
	_global_state.set("conversation_history", previous_history)
	return false


func _mark_history_message_failed(message_id: String, error_message: String) -> void:
	if not is_instance_valid(_global_state):
		return
	var previous_history := _get_shared_history()
	if not bool(_global_state.call(
		"update_conversation_entry",
		message_id,
		{"status": "failed", "error": error_message, "retryable": true},
		false
	)):
		return
	if not bool(_global_state.call("save_default_state")):
		_global_state.set("conversation_history", previous_history)


func _restore_chat_log() -> void:
	_chat_log_lines.clear()
	var history := _get_shared_history()
	var start_index := maxi(0, history.size() - CHAT_LOG_LINE_LIMIT)
	for index in range(start_index, history.size()):
		var entry: Dictionary = history[index]
		if str(entry.get("status", "sent")) != "sent":
			continue
		var sender := str(entry.get("sender", ""))
		var speaker := "你"
		if sender == "ai":
			var role_id := str(entry.get("role", ""))
			if role_id not in ["ling", "nai"]:
				continue
			speaker = "小玲" if role_id == "ling" else "小奈"
		elif sender != "user":
			continue
		_append_chat_log_line(speaker, str(entry.get("text", "")), false)
	_refresh_chat_log()


func _append_chat_log_line(speaker: String, text: String, refresh := true) -> void:
	var display_text := _normalize_chat_text(text, CHAT_LOG_TEXT_LIMIT)
	display_text = display_text.replace("\r", " ").replace("\n", " ")
	if display_text.is_empty():
		return
	_chat_log_lines.append("%s：%s" % [speaker, display_text])
	while _chat_log_lines.size() > CHAT_LOG_LINE_LIMIT:
		_chat_log_lines.pop_front()
	if refresh:
		_refresh_chat_log()


func _refresh_chat_log() -> void:
	if _chat_log_lines.is_empty():
		_chat_log.text = "可以直接告诉小玲去餐桌、沙发，或让她跟随你。"
		return
	_chat_log.text = "\n\n".join(_chat_log_lines)


func _describe_scene_action(action: Dictionary) -> String:
	match str(action.get("action", "")):
		"move_to":
			var target_id := str(action.get("target_id", ""))
			var target_name := "餐桌" if target_id == "dining_table" else "沙发"
			return "小玲决定前往%s。" % target_name
		"follow_player":
			return "小玲决定跟随你。"
		"stop":
			return "小玲决定停下。"
		_:
			return "小玲的场景动作已执行。"


func _normalize_chat_text(value: String, limit: int) -> String:
	var normalized := TEXT_SANITIZER.strip_nul(value).strip_edges()
	if normalized.length() > limit:
		normalized = normalized.left(limit)
	return normalized


func _get_shared_history() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not is_instance_valid(_global_state):
		return result
	var history_value = _global_state.get("conversation_history")
	if not history_value is Array:
		return result
	for entry_value in history_value:
		if entry_value is Dictionary:
			result.append((entry_value as Dictionary).duplicate(true))
	return result


func _global_save_error() -> String:
	if not is_instance_valid(_global_state) or not _global_state.has_method("get_last_save_error"):
		return "共享状态不可用"
	var message := str(_global_state.call("get_last_save_error")).strip_edges()
	return message if not message.is_empty() else "未知保存错误"


func _on_ling_action_state_changed(state: Dictionary) -> void:
	_show_status(_format_ling_state(state), _state_color(String(state.get("status", ""))))


func _format_ling_state(state: Dictionary) -> String:
	var mode_code := String(state.get("mode", "idle"))
	var status_code := String(state.get("status", "idle"))
	var target_label := String(state.get("label", "目标"))
	var recovery_count := int(state.get("recovery_count", 0))
	var mode_labels := {
		"idle": "待命",
		"move": "定点移动",
		"move_to": "定点移动",
		"moving": "定点移动",
		"follow": "跟随玩家",
		"following": "跟随玩家",
	}
	var status_labels := {
		"idle": "待命",
		"moving": "移动中",
		"navigating": "移动中",
		"following": "跟随中",
		"path_pending": "路径准备中",
		"replanning": "重新规划路径",
		"waiting_for_follow_target": "保持跟随距离",
		"arrived": "已抵达",
		"blocked": "路径不可达",
		"edge_blocked": "前方无安全地面",
		"recovering": "正在脱困",
		"stopped": "已停止",
	}
	var mode_text := String(mode_labels.get(mode_code, mode_code))
	var status_text := String(status_labels.get(status_code, status_code))
	if status_code.begins_with("recovering_"):
		status_text = "正在脱困"
	elif status_code.begins_with("failed_"):
		status_text = "动作失败"
	var result := "小玲：%s · %s" % [mode_text, status_text]
	if target_label != "" and (mode_code != "idle" or status_code == "arrived"):
		result += " · %s" % target_label
	if recovery_count > 0:
		result += " · 脱困 %d 次" % recovery_count
	return result


func _state_color(status_code: String) -> Color:
	if status_code.begins_with("failed_") or status_code in ["blocked", "edge_blocked"]:
		return Color("ef8b7a")
	if status_code.begins_with("recovering_") or status_code in ["recovering", "replanning"]:
		return Color("e8c67a")
	match status_code:
		"arrived", "idle", "stopped":
			return Color("9ed6bd")
		_:
			return Color("d8e5ee")


func _on_return_button_pressed() -> void:
	if _returning_to_dialog:
		return
	if _ai_waiting or _ai_controller.has_pending_request():
		_show_status("请等小玲完成当前回复再返回；按钮与场景仍保持可交互。", Color("e8c67a"))
		_release_button_focus(_return_button)
		return
	_returning_to_dialog = true
	_set_command_buttons_enabled(false)
	_return_button.disabled = true
	if _player.has_method("set_input_enabled"):
		_player.call("set_input_enabled", false)
	if _ling_agent.has_method("command_stop"):
		_ling_agent.call("command_stop")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_show_status("正在返回对话……", Color("e8c67a"))
	var ui_manager := get_node_or_null("/root/UI")
	if ui_manager and ui_manager.has_method("switch_scene"):
		var accepted := bool(ui_manager.call("switch_scene", DIALOG_SCENE_PATH))
		if not accepted:
			_restore_after_return_failure("场景切换正在进行或请求被拒绝")
	else:
		var error := get_tree().change_scene_to_file(DIALOG_SCENE_PATH)
		if error != OK:
			_restore_after_return_failure(error_string(error))


func _restore_after_return_failure(reason: String) -> void:
	_returning_to_dialog = false
	_return_button.disabled = false
	_set_command_buttons_enabled(_navigation_ready)
	if _player.has_method("set_input_enabled"):
		_player.call("set_input_enabled", true)
	_show_status("返回对话失败：%s" % reason, Color("ef8b7a"))


func _on_kill_plane_body_entered(body: Node3D) -> void:
	if body == _player:
		_queue_character_recovery(_player, PLAYER_SPAWN, "玩家")
	elif body == _ling_agent:
		_queue_character_recovery(_ling_agent, LING_SPAWN, "小玲")


func _queue_character_recovery(
	body: CharacterBody3D, fallback_position: Vector3, label_text: String
) -> void:
	var instance_id := body.get_instance_id()
	if _recovering_bodies.has(instance_id):
		return
	_recovering_bodies[instance_id] = true
	call_deferred("_recover_character", body, fallback_position, label_text)


func _recover_character(
	body: CharacterBody3D, fallback_position: Vector3, label_text: String
) -> void:
	if not is_instance_valid(body):
		return
	body.velocity = Vector3.ZERO
	body.global_position = fallback_position
	if body == _ling_agent and _ling_agent.has_method("command_stop"):
		_ling_agent.call("command_stop")
	_recovering_bodies.erase(body.get_instance_id())
	_show_status("%s触发防坠落保护，已回到安全位置。" % label_text, Color("e8c67a"))


func _set_command_buttons_enabled(enabled: bool) -> void:
	_dining_button.disabled = not enabled
	_sofa_button.disabled = not enabled
	_follow_button.disabled = not enabled
	_stop_button.disabled = not enabled


func _show_status(message: String, color: Color) -> void:
	_status_label.text = message
	_status_label.modulate = color


func _release_button_focus(button: Button) -> void:
	if button.has_focus():
		button.release_focus()
