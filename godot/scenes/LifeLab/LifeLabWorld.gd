extends Node3D

signal navigation_ready
signal stress_test_finished(report: Dictionary)

const MAIN_MENU_PATH := "res://scenes/MainMenu/MainMenu.tscn"
const NAI_CHIBI_PATH := "res://local_assets/life_lab/nai_chibi.glb"
const NAI_FULL_PATH := "res://local_assets/life_lab/nai_full.glb"
const NAVIGATION_BAKE_TIMEOUT_SECONDS := 20.0
const ROLE_NAMES := {"ling": "小玲", "nai": "小奈"}
const SOCIAL_QUEUE_LIMIT := 8
const SOCIAL_DIALOGUE_COOLDOWN_SECONDS := 24.0
const SOCIAL_DIALOGUE_MAX_ATTEMPTS := 3
const SOCIAL_DIALOGUE_RETRY_BASE_SECONDS := 0.35

@onready var _navigation_region: NavigationRegion3D = $NavigationRegion3D
@onready var _room: Node3D = $NavigationRegion3D/LifeLabRoom
@onready var _player: CharacterBody3D = $PlayerMarker
@onready var _ling: CharacterBody3D = $LingChibi
@onready var _nai: CharacterBody3D = $NaiChibi
@onready var _task_controller: LifeLabTaskController = $LifeLabTaskController

var _navigation_is_ready := false
var _nai_uses_full_model := false
var _selected_role := "ling"
var _stress_running := false
var _vision_busy := false
var _stress_task_results: Dictionary = {}
var _event_lines: Array[String] = []
var _social_event_queue: Array[Dictionary] = []
var _social_history: Array[Dictionary] = []
var _social_dialogue_busy := false
var _social_dialogue_enabled := true
var _last_social_dialogue_msec := -24000

var _status_label: Label
var _ling_state_label: Label
var _nai_state_label: Label
var _command_input: LineEdit
var _role_selector: OptionButton
var _autonomy_toggle: CheckButton
var _stress_button: Button
var _model_button: Button
var _vision_button: Button
var _vision_result: Label
var _event_feed: Label
var _social_feed: RichTextLabel
var _social_toggle: CheckButton
var _command_buttons: Array[BaseButton] = []


func _ready() -> void:
	for agent in [_ling, _nai]:
		var name_label := agent.get_node_or_null("NameLabel") as Label3D
		if is_instance_valid(name_label):
			name_label.layers = 2
	_build_interface()
	_connect_signals()
	_set_controls_enabled(false)
	_show_status("正在烘焙团子生活实验室导航网格……")
	_bake_navigation.call_deferred()
	_watch_navigation_bake.call_deferred()


func _physics_process(_delta: float) -> void:
	for entry in [[_player, Vector3(0.0, 0.05, 4.35)], [_ling, Vector3(2.0, 0.05, 3.5)], [_nai, Vector3(-2.0, 0.05, 3.5)]]:
		var body := entry[0] as CharacterBody3D
		if is_instance_valid(body) and body.global_position.y < -8.0:
			body.global_position = entry[1]
			body.velocity = Vector3.ZERO


func is_navigation_ready() -> bool:
	return _navigation_is_ready


func get_task_controller() -> LifeLabTaskController:
	return _task_controller


func get_agent(role: String) -> CharacterBody3D:
	return _ling if role == "ling" else (_nai if role == "nai" else null)


func execute_command(text: String, default_role := "") -> Dictionary:
	if not _navigation_is_ready:
		return {"ok": false, "message": "导航尚未就绪"}
	return _task_controller.execute_text(
		text,
		default_role if default_role in ["ling", "nai"] else _selected_role
	)


func capture_role_view(role: String) -> Image:
	var agent := get_agent(role)
	if not is_instance_valid(agent):
		return Image.new()
	var viewport := SubViewport.new()
	viewport.name = "RoleVision_%s" % role
	viewport.size = Vector2i(512, 320)
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	viewport.world_3d = get_viewport().world_3d
	add_child(viewport)
	var camera := Camera3D.new()
	camera.fov = 72.0
	camera.near = 0.05
	camera.far = 24.0
	camera.cull_mask = 1
	viewport.add_child(camera)
	var visual_pivot := agent.get_node_or_null("VisualPivot") as Node3D
	var forward := Vector3.FORWARD
	if is_instance_valid(visual_pivot):
		forward = -visual_pivot.global_transform.basis.z.normalized()
	var eye_position := agent.global_position + Vector3(0, 0.78, 0) + forward * 0.22
	camera.global_position = eye_position
	camera.look_at(eye_position + forward * 6.0 + Vector3(0, -1.0, 0), Vector3.UP)
	await RenderingServer.frame_post_draw
	await get_tree().process_frame
	var image := viewport.get_texture().get_image()
	viewport.queue_free()
	return image


func observe_role_with_vision(role: String) -> Dictionary:
	if role not in ["ling", "nai"]:
		return {"ok": false, "message": "未知观察角色"}
	var result := await _describe_role_view(role)
	if bool(result.get("ok", false)):
		_task_controller.set_visual_context(
			role,
			str(result.get("description", "")),
			str(result.get("provider", "unknown"))
		)
	return result


func force_fall_recovery(role := "nai") -> void:
	var agent := get_agent(role)
	if not is_instance_valid(agent):
		return
	agent.global_position = Vector3(4.8, -5.0, 2.7)
	agent.velocity = Vector3(0, -2.0, 0)
	_log_event("%s进入跌落恢复测试" % ROLE_NAMES.get(role, role))


func run_stress_test(rounds := 6) -> Dictionary:
	if _stress_running or not _navigation_is_ready:
		return {"ok": false, "message": "压力测试不可用"}
	_stress_running = true
	_stress_task_results.clear()
	_task_controller.set_autonomous_enabled(false)
	if is_instance_valid(_autonomy_toggle):
		_autonomy_toggle.button_pressed = false
	if is_instance_valid(_stress_button):
		_stress_button.disabled = true
	var actions := ["drink", "dance", "eat", "plant", "rest", "socialize", "dine"]
	var completed := 0
	var failed := 0
	var timeouts := 0
	var minimum_agent_separation := INF
	var started_msec := Time.get_ticks_msec()
	for round_index in clampi(rounds, 1, 40):
		var ling_action := str(actions[round_index % actions.size()])
		var nai_action := str(actions[(round_index + 3) % actions.size()])
		var ids: Array[String] = []
		for request in [["ling", ling_action], ["nai", nai_action]]:
			var result := _task_controller.request_action(str(request[0]), str(request[1]))
			if bool(result.get("ok", false)):
				ids.append(str(result.get("task_id", "")))
			else:
				failed += 1
		var deadline := Time.get_ticks_msec() + 15000
		while Time.get_ticks_msec() < deadline and not _all_tasks_finished(ids):
			minimum_agent_separation = minf(
				minimum_agent_separation,
				_planar_distance(_ling.global_position, _nai.global_position)
			)
			await get_tree().physics_frame
		for task_id in ids:
			var final_status := str(_stress_task_results.get(task_id, "timeout"))
			if final_status == "completed":
				completed += 1
			elif final_status == "timeout":
				timeouts += 1
			else:
				failed += 1
		if timeouts > 0:
			break
	var report := {
		"ok": failed == 0 and timeouts == 0 and minimum_agent_separation >= 0.68,
		"rounds_requested": clampi(rounds, 1, 40),
		"completed_tasks": completed,
		"failed_tasks": failed,
		"timed_out_tasks": timeouts,
		"elapsed_msec": Time.get_ticks_msec() - started_msec,
		"minimum_agent_separation": minimum_agent_separation,
	}
	_stress_running = false
	if is_instance_valid(_stress_button):
		_stress_button.disabled = false
	_show_status(
		"压力测试完成：%d 成功 / %d 失败 / %d 超时" % [completed, failed, timeouts]
	)
	stress_test_finished.emit(report.duplicate(true))
	return report


func _all_tasks_finished(task_ids: Array[String]) -> bool:
	for task_id in task_ids:
		if not _stress_task_results.has(task_id):
			return false
	return true


func _planar_distance(from: Vector3, to: Vector3) -> float:
	var offset := to - from
	offset.y = 0.0
	return offset.length()


func _bake_navigation() -> void:
	var navigation_mesh := _navigation_region.navigation_mesh
	if navigation_mesh == null:
		navigation_mesh = NavigationMesh.new()
		_navigation_region.navigation_mesh = navigation_mesh
	navigation_mesh.agent_height = 0.95
	navigation_mesh.agent_radius = 0.35
	navigation_mesh.agent_max_climb = 0.20
	navigation_mesh.agent_max_slope = 42.0
	navigation_mesh.cell_size = 0.05
	navigation_mesh.cell_height = 0.05
	navigation_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	navigation_mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	navigation_mesh.geometry_collision_mask = 1
	var navigation_map := _navigation_region.get_navigation_map()
	NavigationServer3D.map_set_cell_size(navigation_map, navigation_mesh.cell_size)
	NavigationServer3D.map_set_cell_height(navigation_map, navigation_mesh.cell_height)
	_navigation_region.bake_finished.connect(_on_navigation_bake_finished, CONNECT_ONE_SHOT)
	_navigation_region.bake_navigation_mesh(true)


func _on_navigation_bake_finished() -> void:
	var navigation_mesh := _navigation_region.navigation_mesh
	if navigation_mesh == null or navigation_mesh.get_vertices().is_empty():
		_show_status("导航网格为空，请检查实验室碰撞体。")
		push_error("LifeLabWorld: navigation mesh has no vertices")
		return
	_finalize_navigation.call_deferred()


func _finalize_navigation() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	if not is_inside_tree():
		return
	var navigation_map := _navigation_region.get_navigation_map()
	if navigation_map.is_valid():
		NavigationServer3D.map_force_update(navigation_map)
	await get_tree().physics_frame
	_navigation_is_ready = true
	_set_controls_enabled(true)
	_show_status("导航已就绪；小玲和小奈会开始自主生活")
	navigation_ready.emit()


func _watch_navigation_bake() -> void:
	await get_tree().create_timer(NAVIGATION_BAKE_TIMEOUT_SECONDS).timeout
	if is_inside_tree() and not _navigation_is_ready:
		_show_status("导航烘焙超时；可返回后重新进入实验室")


func _connect_signals() -> void:
	_task_controller.task_changed.connect(_on_task_changed)
	_task_controller.needs_changed.connect(_on_needs_changed)
	_task_controller.command_result.connect(_on_command_result)
	_task_controller.social_event_ready.connect(_on_social_event_ready)
	var life_sim := get_node_or_null("/root/LifeSim")
	if is_instance_valid(life_sim) and life_sim.has_signal("autonomous_action"):
		life_sim.connect("autonomous_action", Callable(self, "_on_life_autonomous_action"))
	for role in ["ling", "nai"]:
		var agent := get_agent(role)
		if agent.has_signal("action_state_changed"):
			agent.connect("action_state_changed", _on_agent_action_state.bind(role))
		if agent.has_signal("local_visual_loaded"):
			agent.connect("local_visual_loaded", _on_local_visual_loaded.bind(role))

func _on_life_autonomous_action(event: Dictionary) -> void:
	if not _navigation_is_ready or str(event.get("source", "")) != "companion_core_offline_life":
		return
	var role := str(event.get("role_id", ""))
	if role not in ["ling", "nai"]:
		return
	var task := _task_controller.get_task(role)
	if str(task.get("status", "")) in ["planned", "moving", "executing", "interacting"]:
		return
	var event_action := str(event.get("action", ""))
	var action := "wander"
	match event_action:
		"self_care_eat": action = "eat"
		"self_care_drink": action = "drink"
		"rest", "quiet_time": action = "rest"
		"daily_moment": action = "wander"
	_task_controller.request_action(role, action)


func _build_interface() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "HUD"
	canvas.layer = 20
	add_child(canvas)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	margin.offset_left = 14
	margin.offset_top = 14
	margin.offset_right = 374
	margin.offset_bottom = -14
	canvas.add_child(margin)
	var panel := PanelContainer.new()
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.055, 0.06, 0.065, 0.91)
	panel_style.border_color = Color(0.86, 0.72, 0.45, 0.48)
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(8)
	panel.add_theme_stylebox_override("panel", panel_style)
	margin.add_child(panel)
	var panel_margin := MarginContainer.new()
	panel_margin.add_theme_constant_override("margin_left", 14)
	panel_margin.add_theme_constant_override("margin_top", 12)
	panel_margin.add_theme_constant_override("margin_right", 14)
	panel_margin.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(panel_margin)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel_margin.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)
	scroll.add_child(content)
	var title := Label.new()
	title.text = "🍡 双团子生活实验室"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color("f1d48b"))
	content.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "俯视观察 · 双角色寻路 · 本地沙盒数值"
	subtitle.add_theme_font_size_override("font_size", 12)
	subtitle.add_theme_color_override("font_color", Color(0.78, 0.82, 0.84, 0.78))
	content.add_child(subtitle)
	_status_label = Label.new()
	_status_label.custom_minimum_size.y = 44
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_status_label)
	_ling_state_label = _make_role_state_label("🐾 小玲 · 准备中")
	content.add_child(_ling_state_label)
	_nai_state_label = _make_role_state_label("🐇 小奈 · 准备中")
	content.add_child(_nai_state_label)
	content.add_child(HSeparator.new())
	_role_selector = OptionButton.new()
	_role_selector.add_item("小玲", 0)
	_role_selector.add_item("小奈", 1)
	_role_selector.add_item("两个人", 2)
	_role_selector.item_selected.connect(_on_role_selected)
	content.add_child(_role_selector)
	var input_row := HBoxContainer.new()
	content.add_child(input_row)
	_command_input = LineEdit.new()
	_command_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_command_input.placeholder_text = "例如：小奈过来我这"
	_command_input.text_submitted.connect(func(_text: String): _submit_command())
	input_row.add_child(_command_input)
	var send_button := Button.new()
	send_button.text = "➤"
	send_button.tooltip_text = "执行生活指令"
	send_button.pressed.connect(_submit_command)
	input_row.add_child(send_button)
	_command_buttons.append(send_button)
	var quick_grid := GridContainer.new()
	quick_grid.columns = 2
	quick_grid.add_theme_constant_override("h_separation", 6)
	quick_grid.add_theme_constant_override("v_separation", 6)
	content.add_child(quick_grid)
	for quick in [
		["💧 喝水", "喝水"], ["🍚 吃饭", "吃饭"],
		["🛋 休息", "休息"], ["🌱 照料花", "照料绿植"],
		["🍳 做饭", "一起做饭"], ["🍵 泡茶", "一起泡茶"],
		["📖 阅读", "一起读书"], ["🎬 看节目", "一起看节目"],
		["🎮 游戏", "一起玩游戏"], ["🎵 音乐", "一起听音乐"],
		["🧹 清洁", "一起收拾房间"], ["📷 拍照", "一起给花拍照"],
		["🤗 依偎", "一起抱抱"], ["💬 分享今天", "一起聊今天"],
		["💃 排练", "排练"], ["📍 来我这", "过来我这"],
	]:
		var button := Button.new()
		button.text = str(quick[0])
		button.custom_minimum_size = Vector2(150, 34)
		button.pressed.connect(_execute_quick.bind(str(quick[1])))
		quick_grid.add_child(button)
		_command_buttons.append(button)
	_autonomy_toggle = CheckButton.new()
	_autonomy_toggle.text = "自主探索"
	_autonomy_toggle.button_pressed = true
	_autonomy_toggle.toggled.connect(_task_controller.set_autonomous_enabled)
	content.add_child(_autonomy_toggle)
	_social_toggle = CheckButton.new()
	_social_toggle.text = "生活事件触发双 AI 对话"
	_social_toggle.tooltip_text = "角色完成具有交流意义的生活行为后，以独立生活实验室会话依次发言；不会污染正式聊天记录。"
	_social_toggle.button_pressed = true
	_social_toggle.toggled.connect(func(enabled: bool):
		_social_dialogue_enabled = enabled
		if not enabled:
			_social_event_queue.clear()
	)
	content.add_child(_social_toggle)
	var event_title := Label.new()
	event_title.text = "📋 最近生活事件"
	event_title.add_theme_font_size_override("font_size", 12)
	event_title.add_theme_color_override("font_color", Color("f1d48b"))
	content.add_child(event_title)
	_event_feed = Label.new()
	_event_feed.text = "等待角色开始活动…"
	_event_feed.custom_minimum_size.y = 58
	_event_feed.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_event_feed.add_theme_font_size_override("font_size", 11)
	_event_feed.add_theme_color_override("font_color", Color(0.82, 0.86, 0.88, 0.96))
	content.add_child(_event_feed)
	var dialogue_title := Label.new()
	dialogue_title.text = "💭 双角色生活对话"
	dialogue_title.add_theme_font_size_override("font_size", 12)
	dialogue_title.add_theme_color_override("font_color", Color("f1d48b"))
	content.add_child(dialogue_title)
	_social_feed = RichTextLabel.new()
	_social_feed.bbcode_enabled = true
	_social_feed.fit_content = false
	_social_feed.scroll_active = true
	_social_feed.custom_minimum_size = Vector2(0, 150)
	_social_feed.text = "完成共同生活行为后，小玲和小奈会在这里依次交流。"
	content.add_child(_social_feed)
	_stress_button = Button.new()
	_stress_button.text = "▶ 导航压力测试（6 轮）"
	_stress_button.pressed.connect(func(): run_stress_test(6))
	content.add_child(_stress_button)
	_command_buttons.append(_stress_button)
	var fall_button := Button.new()
	fall_button.text = "↩ 小奈跌落恢复测试"
	fall_button.pressed.connect(func(): force_fall_recovery("nai"))
	content.add_child(fall_button)
	_command_buttons.append(fall_button)
	_model_button = Button.new()
	_model_button.text = "⇄ 小奈切换完整模型（对照）"
	_model_button.pressed.connect(_toggle_nai_model)
	content.add_child(_model_button)
	_vision_button = Button.new()
	_vision_button.text = "👁 Gemma 角色视角观察"
	_vision_button.tooltip_text = "从所选团子的眼部方向截取一帧；自动使用 API 视觉模型或本地 LM Studio 转述"
	_vision_button.pressed.connect(_observe_selected_roles)
	content.add_child(_vision_button)
	_command_buttons.append(_vision_button)
	_vision_result = Label.new()
	_vision_result.text = "视觉观察尚未运行"
	_vision_result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_vision_result.add_theme_font_size_override("font_size", 12)
	_vision_result.add_theme_color_override("font_color", Color(0.68, 0.83, 0.88, 0.9))
	content.add_child(_vision_result)
	var hint := Label.new()
	hint.text = "WASD 移动主人位置 · 鼠标中键平移 · 右键旋转 · 滚轮缩放"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.72, 0.75, 0.78, 0.72))
	content.add_child(hint)
	var return_button := Button.new()
	return_button.text = "← 返回主菜单"
	return_button.pressed.connect(func(): UI.switch_scene(MAIN_MENU_PATH))
	content.add_child(return_button)


func _make_role_state_label(initial_text: String) -> Label:
	var label := Label.new()
	label.text = initial_text
	label.custom_minimum_size.y = 54
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 13)
	return label


func _set_controls_enabled(enabled: bool) -> void:
	for button in _command_buttons:
		if is_instance_valid(button):
			button.disabled = not enabled
	if is_instance_valid(_command_input):
		_command_input.editable = enabled
	if is_instance_valid(_role_selector):
		_role_selector.disabled = not enabled


func _on_role_selected(index: int) -> void:
	_selected_role = "ling" if index == 0 else ("nai" if index == 1 else "both")


func _submit_command() -> void:
	var text := _command_input.text.strip_edges()
	if text.is_empty():
		return
	if _selected_role == "both" and not ("小玲" in text or "小奈" in text or "她们" in text):
		text = "她们一起" + text
	var result := execute_command(text, "ling" if _selected_role == "both" else _selected_role)
	if bool(result.get("ok", false)):
		_command_input.clear()


func _execute_quick(command: String) -> void:
	var text := command
	if _selected_role == "both":
		text = "她们一起" + command
	elif _selected_role == "nai":
		text = "小奈" + command
	else:
		text = "小玲" + command
	execute_command(text)


func _toggle_nai_model() -> void:
	var target_path := NAI_CHIBI_PATH if _nai_uses_full_model else NAI_FULL_PATH
	var target_scale := 0.82 if _nai_uses_full_model else 0.34
	if not _nai.call("set_local_visual", target_path, target_scale, Vector3.ZERO, Vector3.ZERO):
		_show_status("模型仍在加载，请稍后再切换")
		return
	_nai_uses_full_model = not _nai_uses_full_model
	_model_button.disabled = true
	_show_status("正在加载小奈%s模型……" % ("完整" if _nai_uses_full_model else "团子"))


func _observe_selected_roles() -> void:
	if _vision_busy:
		return
	_vision_busy = true
	_vision_button.disabled = true
	var roles: Array[String] = []
	if _selected_role == "both":
		roles.assign(["ling", "nai"])
	else:
		roles.append(_selected_role)
	var summaries: Array[String] = []
	var providers: Array[String] = []
	for role in roles:
		_show_status("正在从%s的角色视角截取画面……" % ROLE_NAMES[role])
		var result := await observe_role_with_vision(role)
		if bool(result.get("ok", false)):
			var description := str(result.get("description", "")).strip_edges()
			summaries.append("%s：%s" % [ROLE_NAMES[role], description.left(700)])
			var provider := str(result.get("provider", "unknown"))
			if provider not in providers:
				providers.append(provider)
		else:
			summaries.append("%s：观察失败 · %s" % [ROLE_NAMES[role], str(result.get("message", "未知错误"))])
	_vision_result.text = "\n\n".join(summaries)
	var backend_name := "视觉模型"
	if providers == ["companion_core"]:
		backend_name = "API 视觉模型"
	elif providers == ["lm_studio"]:
		backend_name = "本地视觉模型"
	elif providers.size() > 1:
		backend_name = "混合视觉模型"
	_show_status("%s角色视角观察完成" % backend_name)
	_vision_busy = false
	_vision_button.disabled = false


func _describe_role_view(role: String) -> Dictionary:
	var vision := get_node_or_null("/root/Vision")
	if not is_instance_valid(vision) or not vision.has_method("describe_image"):
		return {"ok": false, "message": "视觉客户端不可用"}
	var image := await capture_role_view(role)
	if image == null or image.is_empty():
		return {"ok": false, "message": "角色视角截图为空"}
	var directory := "user://SpringHaven/multimodal_frames"
	var absolute_directory := ProjectSettings.globalize_path(directory)
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute_directory)
	if directory_error not in [OK, ERR_ALREADY_EXISTS]:
		return {"ok": false, "message": error_string(directory_error)}
	var frame_id := "%s-%d" % [role, Time.get_ticks_msec()]
	var frame_path := directory.path_join("life_lab_%s.png" % frame_id)
	var save_error := image.save_png(frame_path)
	if save_error != OK:
		return {"ok": false, "message": error_string(save_error)}
	var symbolic_context := {
		"protocol": "spring_heaven.life_lab.vision.v1",
		"scene": "life_lab",
		"observer_role_id": role,
		"observer_name": ROLE_NAMES[role],
		"trusted_state": _task_controller.get_snapshot(),
		"trusted_station_ids": _room.call("get_station_ids"),
	}
	var vision_result_variant = await vision.call("describe_image", frame_path, symbolic_context)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(frame_path))
	if not vision_result_variant is Dictionary:
		return {"ok": false, "message": "视觉模型返回格式无效"}
	var vision_result: Dictionary = vision_result_variant
	if not bool(vision_result.get("ok", false)):
		return vision_result
	return {
		"ok": true,
		"description": str(vision_result.get("text", "")).strip_edges(),
		"provider": str(vision_result.get("provider", "unknown")),
		"backend_mode": str(vision_result.get("backend_mode", "unknown")),
	}


func _on_local_visual_loaded(success: bool, path: String, role: String) -> void:
	if role == "nai" and is_instance_valid(_model_button):
		_model_button.disabled = false
		_model_button.text = (
			"⇄ 小奈切回团子模型" if _nai_uses_full_model else "⇄ 小奈切换完整模型（对照）"
		)
	_log_event("%s模型%s：%s" % [ROLE_NAMES[role], "已加载" if success else "加载失败", path.get_file()])


func _on_task_changed(role: String, task: Dictionary) -> void:
	var task_id := str(task.get("id", ""))
	var status := str(task.get("status", "idle"))
	if not task_id.is_empty() and status in ["completed", "failed"]:
		_stress_task_results[task_id] = status
	var action := str(task.get("action", ""))
	var description := str(LifeLabTaskController.ACTION_LABELS.get(action, "自由活动"))
	_log_event("%s · %s · %s" % [ROLE_NAMES[role], description, _status_name(status)])
	_refresh_role_label(role)


func _on_needs_changed(role: String, _needs: Dictionary) -> void:
	_refresh_role_label(role)


func _on_agent_action_state(_state: Dictionary, role: String) -> void:
	_refresh_role_label(role)


func _on_command_result(result: Dictionary) -> void:
	_show_status(str(result.get("message", "指令已处理")))


func _on_social_event_ready(event: Dictionary) -> void:
	var label := str(event.get("action_label", event.get("action", "生活事件")))
	var participants: Array[String] = []
	for role in event.get("participant_role_ids", []):
		if str(role) in ROLE_NAMES:
			participants.append(str(role))
	_log_event("%s · %s" % [_role_names(participants), label])
	if not _social_dialogue_enabled or _stress_running:
		return
	if _social_event_queue.size() >= SOCIAL_QUEUE_LIMIT:
		var removable := -1
		for index in _social_event_queue.size():
			if str(_social_event_queue[index].get("initiated_by", "autonomous")) != "user":
				removable = index
				break
		if removable >= 0:
			_social_event_queue.remove_at(removable)
		else:
			return
	_social_event_queue.append(event.duplicate(true))
	_process_social_event_queue.call_deferred()


func _process_social_event_queue() -> void:
	if _social_dialogue_busy or not _social_dialogue_enabled:
		return
	_social_dialogue_busy = true
	while not _social_event_queue.is_empty() and _social_dialogue_enabled:
		var elapsed_seconds := float(Time.get_ticks_msec() - _last_social_dialogue_msec) / 1000.0
		if elapsed_seconds < SOCIAL_DIALOGUE_COOLDOWN_SECONDS:
			await get_tree().create_timer(SOCIAL_DIALOGUE_COOLDOWN_SECONDS - elapsed_seconds).timeout
			if not is_inside_tree():
				return
		var event: Dictionary = _social_event_queue.pop_front()
		await _run_social_dialogue(event)
		_last_social_dialogue_msec = Time.get_ticks_msec()
	_social_dialogue_busy = false


func _run_social_dialogue(event: Dictionary) -> void:
	var core_client := get_node_or_null("/root/CompanionCore")
	if not is_instance_valid(core_client) or not core_client.has_method("orchestrate_chat"):
		_append_social_line("系统", "独立 Companion Core 客户端不可用。", "#D9534F")
		return
	var actor_role := str(event.get("actor_role_id", "ling"))
	if actor_role not in ROLE_NAMES:
		actor_role = "ling"
	var reply_roles: Array[String] = [actor_role]
	for role in event.get("participant_role_ids", []):
		var role_id := str(role)
		if role_id in ROLE_NAMES and role_id not in reply_roles:
			reply_roles.append(role_id)
	for role in ["ling", "nai"]:
		if role not in reply_roles:
			reply_roles.append(role)
	if str(event.get("action", "")) == "photo" and str(event.get("initiated_by", "")) == "user" and str(event.get("visual_summary", "")).is_empty():
		var vision_result := await observe_role_with_vision(actor_role)
		if bool(vision_result.get("ok", false)):
			event["visual_summary"] = str(vision_result.get("description", "")).left(1200)
	var action_label := str(event.get("action_label", event.get("action", "生活互动")))
	var event_text := "刚刚在生活实验室里完成了“%s”。请结合这次共同经历和你们各自的状态，自然交流一两句；不要把它写成系统报告。" % action_label
	_append_social_line("生活事件", "%s · %s" % [_role_names(reply_roles), action_label], "#D9A441")
	var conversation_id := "%s_life_lab" % str(core_client.call("get_save_id")).left(52)
	var request_id := _social_dialogue_request_id(conversation_id, event)
	var result: Dictionary = {}
	for attempt in SOCIAL_DIALOGUE_MAX_ATTEMPTS:
		result = await core_client.call(
			"orchestrate_chat",
			event_text,
			actor_role,
			reply_roles,
			_social_history,
			conversation_id,
			"action",
			{"life_lab_event": event},
			{},
			request_id
		)
		if not is_inside_tree():
			return
		if bool(result.get("ok", false)):
			break
		if not bool(result.get("retryable", false)) or attempt >= SOCIAL_DIALOGUE_MAX_ATTEMPTS - 1:
			break
		_show_status("生活对话暂时中断，正在重试（%d/%d）……" % [attempt + 1, SOCIAL_DIALOGUE_MAX_ATTEMPTS - 1])
		await get_tree().create_timer(
			SOCIAL_DIALOGUE_RETRY_BASE_SECONDS * pow(2.0, float(attempt))
		).timeout
		if not is_inside_tree():
			return
	if not bool(result.get("ok", false)):
		_append_social_line("系统", "生活对话失败：%s" % str(result.get("message", "网络请求失败")), "#D9534F")
		return
	var response_data = result.get("data", {})
	var replies = (response_data as Dictionary).get("replies", []) if response_data is Dictionary else []
	if not replies is Array:
		_append_social_line("系统", "Companion Core 返回了无效的编排结果。", "#D9534F")
		return
	_social_history.append({"id": str(event.get("event_id", "event")), "sender": "user", "text": event_text, "event_type": "action"})
	for reply_variant in replies:
		if not reply_variant is Dictionary:
			continue
		var reply: Dictionary = reply_variant
		var role_id := str(reply.get("role_id", ""))
		var text := str(reply.get("reply", "")).strip_edges()
		if role_id not in ROLE_NAMES or text.is_empty():
			continue
		_append_social_line(str(ROLE_NAMES[role_id]), text, "#A9D6CB" if role_id == "ling" else "#EAB6C6")
		_social_history.append({
			"id": "%s:%s" % [str(event.get("event_id", "event")), role_id],
			"sender": "ai",
			"role_id": role_id,
			"text": text,
			"event_type": "action",
		})
	while _social_history.size() > 24:
		_social_history.pop_front()


func _social_dialogue_request_id(conversation_id: String, event: Dictionary) -> String:
	var event_id := str(event.get("event_id", "event")).strip_edges()
	var source := "%s|%s" % [conversation_id, event_id]
	return "life-lab-" + source.sha256_text().left(48)


func _append_social_line(speaker: String, text: String, color: String) -> void:
	if not is_instance_valid(_social_feed):
		return
	if _social_feed.text == "完成共同生活行为后，小玲和小奈会在这里依次交流。":
		_social_feed.clear()
	_social_feed.append_text("[color=%s][b]%s[/b][/color]  %s\n\n" % [color, speaker, text.left(1600)])
	_social_feed.scroll_to_line(maxi(0, _social_feed.get_line_count() - 1))


func _role_names(roles: Array[String]) -> String:
	var names: Array[String] = []
	for role in roles:
		if role in ROLE_NAMES:
			names.append(str(ROLE_NAMES[role]))
	return "、".join(names)


func _refresh_role_label(role: String) -> void:
	var label := _ling_state_label if role == "ling" else _nai_state_label
	if not is_instance_valid(label):
		return
	var needs := _task_controller.get_needs(role)
	var task := _task_controller.get_task(role)
	var action := str(task.get("action", ""))
	var task_text := str(LifeLabTaskController.ACTION_LABELS.get(action, "观察环境"))
	var status := _status_name(str(task.get("status", "idle")))
	label.text = "%s %s · %s / %s\n饥饿 %.0f  口渴 %.0f  体力 %.0f  心情 %.0f" % [
		"🐾" if role == "ling" else "🐇",
		ROLE_NAMES[role],
		task_text,
		status,
		float(needs.get("hunger", 0.0)),
		float(needs.get("thirst", 0.0)),
		float(needs.get("stamina", 0.0)),
		float(needs.get("mood", 0.0)),
	]


func _status_name(status: String) -> String:
	return {
		"planned": "已计划", "moving": "移动中", "interacting": "互动中",
		"executing": "持续执行", "completed": "完成", "failed": "失败",
	}.get(status, "待命")


func _show_status(text: String) -> void:
	if is_instance_valid(_status_label):
		_status_label.text = text


func _log_event(text: String) -> void:
	_event_lines.append(text.left(120))
	while _event_lines.size() > 8:
		_event_lines.pop_front()
	if is_instance_valid(_event_feed):
		_event_feed.text = "\n".join(_event_lines.slice(maxi(0, _event_lines.size() - 4)))
