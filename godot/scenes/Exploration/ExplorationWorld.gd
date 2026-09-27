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
# ADR 探索阶段①(SLG 交互层):可感知组件与角色交互动词
const PERCEIVABLE_SCRIPT := preload("res://scenes/Exploration/Perception/Perceivable3D.gd")
const LING_INTERACT_RANGE := 2.4

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

# ADR 探索阶段①:玩家交互提示(代码创建,挂 HUD)
var _interact_hint: Label
# SLG 交互层:动作菜单 + 角色本体交互
var _interact_menu: PanelContainer
var _interact_menu_list: VBoxContainer
var _interact_menu_open := false
var _menu_target: Dictionary = {}
var _ray_target_active := false
var _ling_nearby := false
var _ling_perceivable: Node


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
	# ADR 探索阶段①:玩家交互(按 E) → 动词执行 → 事件进 Heartloom
	if is_instance_valid(_player):
		_player.connect("interact_target_changed", Callable(self, "_on_interact_target_changed"))
		_player.connect("interact_requested", Callable(self, "_on_player_interact_requested"))
	_build_interact_hint()
	_build_interact_menu()
	_attach_ling_perceivable()
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
	_update_ling_proximity()
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


# ===== ADR 探索阶段①:玩家交互(按 E)=====

func _build_interact_hint() -> void:
	if _interact_hint != null:
		return
	_interact_hint = Label.new()
	_interact_hint.name = "InteractHint"
	_interact_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_interact_hint.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_interact_hint.offset_left = -240.0
	_interact_hint.offset_right = 240.0
	_interact_hint.offset_top = 48.0
	_interact_hint.offset_bottom = 78.0
	_interact_hint.add_theme_font_size_override("font_size", 14)
	_interact_hint.modulate.a = 0.0
	_interact_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var hud := $HUD
	if is_instance_valid(hud):
		hud.add_child(_interact_hint)


func _pick_interact_action(actions_variant: Array) -> String:
	var preferred := ["observe", "water", "drink", "photograph", "sit", "eat", "rest", "refill", "place_item"]
	var available := {}
	for item in actions_variant:
		available[str(item)] = true
	for action in preferred:
		if available.has(action):
			return action
	for action in available:
		return str(action)
	return ""


func _action_label(action: String) -> String:
	var labels := {
		"observe": "观察", "water": "浇水", "drink": "喝一口", "photograph": "拍照",
		"sit": "坐下", "eat": "吃点东西", "rest": "休息", "refill": "续满",
		"place_item": "放个小东西",
		"talk": "交谈", "pat_head": "摸摸头", "brew_tea": "一起泡茶",
	}
	return str(labels.get(action, action))


func _on_interact_target_changed(target: Dictionary) -> void:
	if _interact_hint == null:
		return
	var snapshot: Dictionary = target.get("snapshot", {})
	_ray_target_active = not snapshot.is_empty()
	if _interact_menu_open:
		return
	if snapshot.is_empty():
		_set_interact_hint("", false)
		return
	var object_name := str(snapshot.get("name", "物件"))
	var action := _pick_interact_action(snapshot.get("available_actions", []))
	var verb_label := _action_label(action) if not action.is_empty() else "观察"
	if snapshot.get("available_actions", []).size() > 1:
		_set_interact_hint("按 E · %s（打开动作菜单）" % object_name, false)
	else:
		_set_interact_hint("按 E · %s（%s）" % [object_name, verb_label], false)


func _on_player_interact_requested(target: Dictionary) -> void:
	# SLG 交互层:按 E 打开动作菜单而不是直接执行第一个动词
	_open_interact_menu(target)


func _build_interact_menu() -> void:
	_interact_menu = PanelContainer.new()
	_interact_menu.name = "InteractMenu"
	_interact_menu.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_interact_menu.offset_left = -150.0
	_interact_menu.offset_right = 150.0
	_interact_menu.offset_top = 40.0
	_interact_menu.offset_bottom = 40.0
	_interact_menu.visible = false
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 10)
	_interact_menu.add_child(margin)
	_interact_menu_list = VBoxContainer.new()
	_interact_menu_list.add_theme_constant_override("separation", 6)
	margin.add_child(_interact_menu_list)
	var hud := $HUD
	if is_instance_valid(hud):
		hud.add_child(_interact_menu)


func _open_interact_menu(target: Dictionary) -> void:
	var snapshot: Dictionary = target.get("snapshot", {})
	var actions: Array = snapshot.get("available_actions", [])
	if actions.is_empty() or _interact_menu == null:
		return
	_menu_target = target
	_interact_menu_open = true
	for child in _interact_menu_list.get_children():
		child.queue_free()
	var object_name := str(snapshot.get("name", "物件"))
	var title := Label.new()
	title.text = "· %s ·" % object_name
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 14)
	_interact_menu_list.add_child(title)
	var hotkey := 1
	for action_variant in actions:
		var action := str(action_variant)
		var button := Button.new()
		button.text = "%d. %s" % [hotkey, _action_label(action)]
		button.alignment = HORIZONTAL_ALIGNMENT_CENTER
		button.pressed.connect(_on_interact_menu_action.bind(action))
		_interact_menu_list.add_child(button)
		hotkey += 1
	var cancel := Button.new()
	cancel.text = "取消（右键）"
	cancel.flat = true
	cancel.pressed.connect(_close_interact_menu)
	_interact_menu_list.add_child(cancel)
	_interact_menu.visible = true
	_interact_menu.modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(_interact_menu, "modulate:a", 1.0, 0.14)
	# 菜单打开期间:释放鼠标、停用移动,把选择权交给菜单
	if is_instance_valid(_player):
		_player.call("set_input_enabled", false)
		_player.call("set_mouse_captured", false)
	_set_interact_hint("", false)


func _on_interact_menu_action(action: String) -> void:
	var target := _menu_target
	_close_interact_menu()
	_execute_interact_action(action, target)


func _close_interact_menu(reassume_controls := true) -> void:
	if not _interact_menu_open:
		return
	_interact_menu_open = false
	if _interact_menu != null:
		_interact_menu.visible = false
	_menu_target = {}
	if is_instance_valid(_player):
		_player.set_input_enabled(true)
		if reassume_controls:
			_player.call("set_mouse_captured", true)


func _unhandled_input(event: InputEvent) -> void:
	# SLG 交互层:走近小玲时按 E 打开她的交互菜单;右键/ESC 关闭菜单
	if _interact_menu_open:
		if event is InputEventMouseButton:
			var mouse_event := event as InputEventMouseButton
			if mouse_event.pressed and mouse_event.button_index == MOUSE_BUTTON_RIGHT:
				_close_interact_menu()
				get_viewport().set_input_as_handled()
		return
	if _ling_nearby and not _ray_target_active and event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo:
			if key_event.physical_keycode == KEY_E or key_event.keycode == KEY_E:
				_open_interact_menu(_ling_menu_target())
				get_viewport().set_input_as_handled()


func _ling_menu_target() -> Dictionary:
	return {
		"perceivable": _ling_perceivable,
		"entity_id": "ling",
		"snapshot": {
			"name": "小玲",
			"available_actions": ["talk", "pat_head", "brew_tea"],
		},
	}


func _update_ling_proximity() -> void:
	var near := (
		is_instance_valid(_ling_agent)
		and is_instance_valid(_player)
		and _ling_agent.global_position.distance_to(_player.global_position) <= LING_INTERACT_RANGE
	)
	if near != _ling_nearby:
		_ling_nearby = near
		if _ling_nearby and not _ray_target_active and not _interact_menu_open:
			_set_interact_hint("按 E · 小玲（交谈）", false)
		elif not _ray_target_active and not _interact_menu_open:
			_set_interact_hint("", false)


func _execute_interact_action(action: String, target: Dictionary) -> void:
	var perceivable_variant = target.get("perceivable")
	var snapshot: Dictionary = target.get("snapshot", {})
	var object_name := str(snapshot.get("name", "物件"))
	# 角色本体交互:交谈直接切到聊天输入,不产生第三方描述
	if action == "talk":
		_append_chat_log_line("小玲", "转过身来，安静地看着你，等你开口。")
		_chat_input.grab_focus()
		return
	if perceivable_variant == null or not is_instance_valid(perceivable_variant):
		# 小玲的摸头/泡茶不需要物件本体
		_record_role_interaction(action, object_name)
		return
	var perceivable: Node = perceivable_variant
	# 最小动词效果:容器水位可变,其余动词以记录为主
	if action == "water":
		perceivable.set("fill_ratio", 1.0)
	elif action == "drink":
		perceivable.set("fill_ratio", maxf(0.0, float(perceivable.get("fill_ratio") or 0.0) - 0.35))
	# ADR 探索阶段③前置:拍照动词 → 截帧 → DeepSeek 视觉描述 → 小玲"看见"的内容
	var visual_note := ""
	if action == "photograph":
		_set_interact_hint("正在给%s拍照……" % object_name, false)
		var snapshot_result: Dictionary = await _capture_object_snapshot(perceivable, object_name)
		if bool(snapshot_result.get("ok", false)):
			visual_note = str(snapshot_result.get("visual_summary", "")).strip_edges()
	var templates := {
		"observe": "主人在客餐厅仔细观察了{obj}",
		"water": "主人给{obj}浇了水",
		"drink": "主人从{obj}里喝了一口",
		"photograph": "主人给{obj}拍了一张照片",
		"sit": "主人在{obj}上坐了一会儿",
		"eat": "主人在{obj}前吃了点东西",
		"rest": "主人在{obj}旁休息了片刻",
		"refill": "主人把{obj}重新续满",
		"place_item": "主人在{obj}上放了一样小东西",
	}
	var description := str(templates.get(action, "主人在客餐厅与{obj}互动")).format({"obj": object_name})
	var detail := str(snapshot.get("description", "")).strip_edges()
	if not detail.is_empty():
		description += "（%s）" % detail.left(80)
	if not visual_note.is_empty():
		description += " 小玲看到：%s" % visual_note.left(220)
		_append_chat_log_line("小玲", "我看了看拍下来的%s——%s" % [object_name, visual_note.left(160)])
	var life_sim := get_node_or_null("/root/LifeSim")
	var queued := false
	if is_instance_valid(life_sim) and life_sim.has_method("queue_player_action_event"):
		queued = bool(life_sim.call("queue_player_action_event", action, description, "ling"))
	if _interact_hint == null:
		return
	if queued:
		_set_interact_hint("✓ %s（已记进心织）" % _action_label(action), true)
		get_tree().create_timer(1.4).timeout.connect(func():
			if is_instance_valid(_interact_hint) and is_instance_valid(_player):
				_on_interact_target_changed(_player.call("get_interact_target"))
		)
	else:
		_set_interact_hint("这次互动没能记录下来", true)
		get_tree().create_timer(1.4).timeout.connect(func():
			if is_instance_valid(_interact_hint):
				_set_interact_hint("", false)
		)


func _record_role_interaction(action: String, object_name: String) -> void:
	var descriptions := {
		"pat_head": "主人揉了揉小玲的头发，她的尾巴愉快地晃了两下",
		"brew_tea": "主人和小玲一起泡了一壶茶，茶香漫过餐桌",
	}
	var description := str(descriptions.get(action, "主人和%s互动" % object_name))
	_append_chat_log_line("小玲", {"pat_head": "眯起眼睛，尾巴晃了两下。", "brew_tea": "起身去烧水：'那就泡一壶吧。'"}.get(action, "轻轻点了点头。"))
	var life_sim := get_node_or_null("/root/LifeSim")
	if is_instance_valid(life_sim) and life_sim.has_method("queue_player_action_event"):
		life_sim.call("queue_player_action_event", action, description, "ling")


## 泛化的物件拍照:SubViewport 对准任意可感知物件 → 相册落盘 → 视觉模型描述。
## 复用绿植拍照的既有管线(Photos + Vision),不再只限绿植。
func _capture_object_snapshot(perceivable: Node, object_name: String) -> Dictionary:
	var result := {"ok": false, "absolute_path": "", "visual_summary": ""}
	if perceivable == null or not is_instance_valid(perceivable) or not perceivable is Node3D:
		return result
	var subject_position := (perceivable as Node3D).global_position + Vector3(0.0, 0.55, 0.0)
	var sub_viewport := SubViewport.new()
	sub_viewport.name = "ObjectPhotoViewport"
	sub_viewport.size = Vector2i(640, 400)
	sub_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	sub_viewport.world_3d = get_world_3d()
	add_child(sub_viewport)
	var camera := Camera3D.new()
	camera.fov = 50.0
	camera.near = 0.05
	camera.far = 30.0
	sub_viewport.add_child(camera)
	# 相机放在玩家与物件之间的斜上方,看向物件中心
	var toward_player := _player.global_position - subject_position
	var flat := Vector3(toward_player.x, 0.0, toward_player.z)
	if flat.length() < 0.8:
		flat = Vector3(0.0, 0.0, 1.0)
	flat = flat.normalized()
	var camera_position := subject_position + flat * 1.7 + Vector3(0.0, 0.72, 0.0)
	camera.look_at_from_position(camera_position, subject_position, Vector3.UP)
	camera.current = true
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var photos := get_node_or_null("/root/Photos")
	if is_instance_valid(photos) and photos.has_method("capture_viewport"):
		var photo_variant = photos.call("capture_viewport", sub_viewport, "ling", "explore3d")
		if photo_variant is Dictionary:
			result.merge(photo_variant, true)
	sub_viewport.queue_free()
	if not bool(result.get("ok", false)):
		return result
	var vision := get_node_or_null("/root/Vision")
	if is_instance_valid(vision) and vision.has_method("discover_model"):
		var discovery_variant = await vision.call("discover_model")
		if not is_inside_tree():
			return result
		if discovery_variant is Dictionary and bool((discovery_variant as Dictionary).get("ok", false)):
			var vision_variant = await vision.call(
				"describe_image",
				str(result.get("absolute_path", "")),
				{"subject": "explore3d", "object_name": object_name}
			)
			if not is_inside_tree():
				return result
			if vision_variant is Dictionary and bool((vision_variant as Dictionary).get("ok", false)):
				result["visual_summary"] = str((vision_variant as Dictionary).get("text", "")).strip_edges().left(800)
	return result


func _set_interact_hint(text: String, fade_after: bool) -> void:
	if _interact_hint == null:
		return
	_interact_hint.text = text
	var target_alpha := 1.0 if not text.is_empty() else 0.0
	var tween := create_tween()
	tween.tween_property(_interact_hint, "modulate:a", target_alpha, 0.16)
	if fade_after and not text.is_empty():
		tween.tween_interval(1.2)
		tween.tween_property(_interact_hint, "modulate:a", 0.0, 0.3)


## SLG 交互层:给小玲 3D 本体挂感知组件 —— 准星射线与走近交互都能找到她
func _attach_ling_perceivable() -> void:
	if _ling_perceivable != null or not is_instance_valid(_ling_agent):
		return
	var perceivable := PERCEIVABLE_SCRIPT.new()
	perceivable.name = "Perceivable3D"
	perceivable.entity_id = "ling"
	perceivable.display_name = "小玲"
	perceivable.description = "小玲就站在这里，可以和她说话，或者摸摸她的头。"
	perceivable.available_actions = ["talk", "pat_head", "brew_tea"] as Array[String]
	_ling_agent.add_child(perceivable)
	_ling_perceivable = perceivable
