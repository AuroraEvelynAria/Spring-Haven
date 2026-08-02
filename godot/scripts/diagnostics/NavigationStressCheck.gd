extends SceneTree

const EXPLORATION_SCENE := preload("res://scenes/Exploration/ExplorationWorld.tscn")
const NAVIGATION_TIMEOUT_FRAMES := 600
const MOVE_TIMEOUT_FRAMES := 720
const ROUTE_CYCLES := 4
const ARRIVAL_TOLERANCE := 0.8
const FOLLOW_TOLERANCE := 2.1

var _checks := 0
var _failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var world := EXPLORATION_SCENE.instantiate()
	world.call("set_global_state_node", null)
	root.add_child(world)
	await process_frame
	await physics_frame

	var ling := world.get_node("LingAgent3D") as CharacterBody3D
	var player := world.get_node("Player3D") as CharacterBody3D
	var dining := world.get_node(
		"NavigationRegion3D/GrayboxRoom/DiningSeatLing"
	) as Marker3D
	var sofa := world.get_node(
		"NavigationRegion3D/GrayboxRoom/SofaSpot"
	) as Marker3D
	_expect(await _wait_for_navigation(world), "压力测试前导航未就绪")

	if _failures.is_empty():
		for cycle in ROUTE_CYCLES:
			await _move_and_check(ling, dining, "餐桌-%d" % cycle)
			await _move_and_check(ling, sofa, "沙发-%d" % cycle)
		await _follow_stop_cycle(ling, player, dining, "餐桌")
		await _follow_stop_cycle(ling, player, sofa, "沙发")
		await _fall_recovery_cycle(world, ling, player)

	world.queue_free()
	await process_frame
	if _failures.is_empty():
		print("NAVIGATION_STRESS_CHECK passed=", _checks, " cycles=", ROUTE_CYCLES)
		quit(0)
		return
	for failure in _failures:
		printerr("NAVIGATION_STRESS_CHECK failure=", failure)
	quit(1)


func _wait_for_navigation(world: Node) -> bool:
	for _frame in NAVIGATION_TIMEOUT_FRAMES:
		if bool(world.get("_navigation_ready")):
			return true
		await physics_frame
	return false


func _move_and_check(ling: CharacterBody3D, anchor: Marker3D, label: String) -> void:
	ling.call("command_move_to", anchor.global_position, label)
	var state := await _wait_for_terminal_state(ling)
	var distance := _planar_distance(ling.global_position, anchor.global_position)
	_expect(str(state.get("status", "")) == "arrived", "%s 未抵达：%s" % [label, state])
	_expect(distance <= ARRIVAL_TOLERANCE, "%s 抵达误差过大：%.3f" % [label, distance])
	_expect(ling.global_position.y > -1.0, "%s 后小玲掉入虚空" % label)
	_expect(int(state.get("recovery_count", 0)) <= 2, "%s 脱困次数异常" % label)


func _wait_for_terminal_state(ling: CharacterBody3D) -> Dictionary:
	for _frame in MOVE_TIMEOUT_FRAMES:
		var state: Dictionary = ling.call("get_action_state")
		var status := str(state.get("status", ""))
		if status == "arrived" or status.begins_with("failed_"):
			return state
		await physics_frame
	return ling.call("get_action_state")


func _follow_stop_cycle(
	ling: CharacterBody3D,
	player: CharacterBody3D,
	anchor: Marker3D,
	label: String
) -> void:
	player.velocity = Vector3.ZERO
	player.global_position = anchor.global_position
	await physics_frame
	ling.call("command_follow", player)
	var entered_follow_distance := false
	for _frame in MOVE_TIMEOUT_FRAMES:
		if _planar_distance(ling.global_position, player.global_position) <= FOLLOW_TOLERANCE:
			entered_follow_distance = true
			break
		await physics_frame
	_expect(entered_follow_distance, "跟随%s时没有进入安全距离" % label)
	ling.call("command_stop")
	var stopped_at := ling.global_position
	for _frame in 30:
		await physics_frame
	var drift := _planar_distance(stopped_at, ling.global_position)
	var state: Dictionary = ling.call("get_action_state")
	_expect(str(state.get("status", "")) == "stopped", "跟随%s后停止状态错误" % label)
	_expect(drift <= 0.08, "跟随%s后停止仍漂移：%.3f" % [label, drift])


func _fall_recovery_cycle(
	world: Node,
	ling: CharacterBody3D,
	player: CharacterBody3D
) -> void:
	player.velocity = Vector3.ZERO
	ling.velocity = Vector3.ZERO
	player.global_position = Vector3(0.0, -13.0, 0.0)
	ling.global_position = Vector3(0.0, -13.0, 0.0)
	for _frame in 20:
		await physics_frame
	_expect(player.global_position.y > -1.0, "压力测试后玩家没有防坠复位")
	_expect(ling.global_position.y > -1.0, "压力测试后小玲没有防坠复位")
	var recovering_bodies: Dictionary = world.get("_recovering_bodies")
	_expect(recovering_bodies.is_empty(), "防坠恢复队列没有清空")


func _planar_distance(from: Vector3, to: Vector3) -> float:
	var offset := to - from
	offset.y = 0.0
	return offset.length()


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
