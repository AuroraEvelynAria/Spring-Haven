extends SceneTree

const CLIENT_SCRIPT := preload("res://scripts/autoload/CompanionCoreClient.gd")
const EXPLORATION_SCENE := preload("res://scenes/Exploration/ExplorationWorld.tscn")
const DIAGNOSTIC_SAVE_ID := "diagnostic-exploration-ai"
const CONNECTION_TIMEOUT_SECONDS := 20.0
const REPLY_TIMEOUT_SECONDS := 100.0
const NAVIGATION_TIMEOUT_FRAMES := 600
const ARRIVAL_TIMEOUT_FRAMES := 900

var _client: Node
var _world: Node3D
var _reply := ""
var _last_error := ""
var _action: Dictionary = {}
var _event_order: Array[String] = []
var _raw_scene_actions: Array = []
var _statuses: Array[String] = []
var _checks := 0
var _failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_client = CLIENT_SCRIPT.new()
	_client.name = "CompanionCoreDiagnostic"
	root.add_child(_client)
	await process_frame
	if not bool(_client.call("has_credentials")):
		printerr("EXPLORATION_AI_FLOW_CHECK core_key_missing")
		quit(2)
		return
	_client.call("set_save_id", DIAGNOSTIC_SAVE_ID)
	_client.connect("scene_actions_received", Callable(self, "_on_raw_scene_actions_received"))
	_client.call("connect_to_core")
	if not await _wait_until_connected():
		printerr("EXPLORATION_AI_FLOW_CHECK connect_failed error=", _last_error)
		quit(3)
		return

	var reset_before: Dictionary = await _client.call("reset_session", DIAGNOSTIC_SAVE_ID)
	if not bool(reset_before.get("ok", false)):
		printerr("EXPLORATION_AI_FLOW_CHECK reset_failed error=", reset_before.get("message", "unknown"))
		quit(4)
		return

	_world = EXPLORATION_SCENE.instantiate()
	_world.call("set_global_state_node", null)
	var isolated_controller := _world.get_node("ExplorationAIController")
	isolated_controller.call("set_core_client", _client)
	root.add_child(_world)
	await process_frame
	await physics_frame
	var navigation_ready := await _wait_for_navigation()
	_expect(navigation_ready, "导航网格未在时限内就绪")
	if navigation_ready:
		await _exercise_real_scene_flow()

	var cleanup: Dictionary = await _client.call("reset_session", DIAGNOSTIC_SAVE_ID)
	_expect(bool(cleanup.get("ok", false)), "诊断会话清理失败")
	if is_instance_valid(_world):
		_world.queue_free()
	_client.call("disconnect_from_core")
	await process_frame
	if _failures.is_empty():
		print("EXPLORATION_AI_FLOW_CHECK passed=", _checks)
		quit(0)
		return
	for failure in _failures:
		printerr("EXPLORATION_AI_FLOW_CHECK failure=", failure)
	quit(1)


func _exercise_real_scene_flow() -> void:
	var controller := _world.get_node("ExplorationAIController")
	var ling := _world.get_node("LingAgent3D") as CharacterBody3D
	var dining_anchor := _world.get_node(
		"NavigationRegion3D/GrayboxRoom/DiningSeatLing"
	) as Marker3D
	controller.reply_ready.connect(_on_reply_ready)
	controller.action_applied.connect(_on_action_applied)
	controller.status_changed.connect(_on_status_changed)

	var context: Dictionary = controller.call("build_scene_state")
	_expect(context.get("vision_available", true) == false, "真实请求上下文未声明无视觉")
	_expect(str(context.get("actor_role_id", "")) == "ling", "真实请求角色边界错误")
	var request_id: String = controller.call(
		"send_player_message",
		"这是自动化场景联调。请明确告诉我你要去餐桌，并立即使用场景动作前往餐桌；不要跟随，也不要停止。"
	)
	_expect(not request_id.is_empty(), "未创建真实场景请求")
	if request_id.is_empty():
		return

	var started_at := Time.get_ticks_msec()
	while (
		_reply.is_empty()
		and _last_error.is_empty()
		and Time.get_ticks_msec() - started_at < int(REPLY_TIMEOUT_SECONDS * 1000.0)
	):
		await create_timer(0.05).timeout
	_expect(_last_error.is_empty(), "真实场景请求失败：%s" % _last_error)
	_expect(not _reply.is_empty(), "真实场景回复超时或为空")
	_expect(not _reply.to_lower().contains("<scene_action"), "动作标签泄露到玩家可见回复")
	_expect(not _action.is_empty(), "DeepSeek-V4-Flash 未返回场景动作")
	_expect(str(_action.get("action", "")) == "move_to", "真实动作不是 move_to")
	_expect(str(_action.get("target_id", "")) == "dining_table", "真实动作目标不是餐桌")
	_expect(_action.size() == 3, "Godot 安全动作包含额外字段")
	_expect(
		_event_order == ["action", "reply"],
		"动作与回复信号顺序错误：%s" % str(_event_order)
	)
	print(
		"EXPLORATION_AI_FLOW_TRACE=",
		JSON.stringify({"raw_actions": _raw_scene_actions, "statuses": _statuses, "event_order": _event_order})
	)

	if str(_action.get("target_id", "")) == "dining_table":
		var arrived := false
		for _frame in ARRIVAL_TIMEOUT_FRAMES:
			var state: Dictionary = ling.call("get_action_state")
			if str(state.get("status", "")) == "arrived":
				arrived = true
				break
			if str(state.get("status", "")).begins_with("failed_"):
				break
			await physics_frame
		_expect(arrived, "真实 AI 动作未能导航到餐桌")
		var planar_offset := ling.global_position - dining_anchor.global_position
		planar_offset.y = 0.0
		_expect(planar_offset.length() <= 0.8, "真实 AI 抵达餐桌误差过大")


func _wait_until_connected() -> bool:
	var started_at := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_at < int(CONNECTION_TIMEOUT_SECONDS * 1000.0):
		if bool(_client.call("is_active")):
			return true
		await create_timer(0.05).timeout
	return false


func _wait_for_navigation() -> bool:
	for _frame in NAVIGATION_TIMEOUT_FRAMES:
		if _world.get("_navigation_ready") == true:
			return true
		await physics_frame
	return false


func _on_action_applied(action: Dictionary) -> void:
	_action = action.duplicate(true)
	_event_order.append("action")


func _on_reply_ready(text: String) -> void:
	_reply = text.strip_edges()
	_event_order.append("reply")


func _on_status_changed(status: String, message: String) -> void:
	_statuses.append("%s:%s" % [status, message])
	if status in ["failed", "unavailable", "rejected"]:
		_last_error = message


func _on_raw_scene_actions_received(_request_id: String, actions: Array) -> void:
	_raw_scene_actions = actions.duplicate(true)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
