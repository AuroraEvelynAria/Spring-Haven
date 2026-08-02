extends Node

const LIFE_LAB_SCENE := preload("res://scenes/LifeLab/LifeLabWorld.tscn")

var _failures: Array[String] = []


func _ready() -> void:
	print("LIFE_LAB_WORLD_CHECK: START")
	var world := LIFE_LAB_SCENE.instantiate()
	for agent_path in ["LingChibi", "NaiChibi"]:
		var diagnostic_agent := world.get_node_or_null(agent_path)
		if is_instance_valid(diagnostic_agent):
			diagnostic_agent.set("load_local_placeholder_model", false)
	add_child(world)
	print("LIFE_LAB_WORLD_CHECK: SCENE_READY")
	var controller: LifeLabTaskController = world.get_task_controller()
	controller.set_autonomous_enabled(false)
	var deadline := Time.get_ticks_msec() + 15000
	while not world.is_navigation_ready() and Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
	if not world.is_navigation_ready():
		_fail("生活实验室导航网格在 15 秒内未就绪")
		_finish()
		return
	print("LIFE_LAB_WORLD_CHECK: NAVIGATION_READY")
	_validate_structure(world)
	_validate_text_commands(world, controller)
	_validate_social_events(world, controller)
	_validate_offline_life_action(world, controller)
	print("LIFE_LAB_WORLD_CHECK: OFFLINE_ACTION_VALIDATED")
	if OS.get_environment("SPRING_HAVEN_FAST_CHECK") == "1":
		_validate_fall_recovery(world)
		_finish()
		return
	var stress_rounds := 4
	var configured_rounds := OS.get_environment("SPRING_HAVEN_STRESS_ROUNDS").strip_edges()
	if configured_rounds.is_valid_int():
		stress_rounds = clampi(int(configured_rounds), 1, 12)
	var stress_report: Dictionary = await world.run_stress_test(stress_rounds)
	if not bool(stress_report.get("ok", false)):
		_fail("双角色导航压力测试失败：%s" % JSON.stringify(stress_report))
	if int(stress_report.get("completed_tasks", 0)) != stress_rounds * 2:
		_fail("压力测试完成任务数不正确：%s" % JSON.stringify(stress_report))
	if float(stress_report.get("minimum_agent_separation", 0.0)) < 0.68:
		_fail("双角色运行时中心间距过小：%s" % JSON.stringify(stress_report))
	_validate_fall_recovery(world)
	_finish()


func _validate_structure(world: Node) -> void:
	for model_path in [
		"res://local_assets/life_lab/ling_chibi.glb",
		"res://local_assets/life_lab/nai_chibi.glb",
		"res://local_assets/life_lab/nai_full.glb",
	]:
		if not ResourceLoader.exists(model_path, "PackedScene"):
			_fail("本地模型未完成 Godot 导入：%s" % model_path)
	for role in ["ling", "nai"]:
		var agent = world.get_agent(role)
		if not is_instance_valid(agent):
			_fail("缺少角色代理：%s" % role)
			continue
		if not str(agent.local_model_path).begins_with("res://local_assets/life_lab/"):
			_fail("角色未配置生活实验室团子模型：%s" % role)
	var room := world.get_node("NavigationRegion3D/LifeLabRoom")
	for station_id in ["water", "food", "dining", "rest", "toilet", "plant", "dance", "social"]:
		if not is_instance_valid(room.call("get_station", station_id)):
			_fail("缺少生活站点：%s" % station_id)
		continue
		var ling_target: Vector3 = room.call("get_station_target", station_id, "ling")
		var nai_target: Vector3 = room.call("get_station_target", station_id, "nai")
		if _planar_distance(ling_target, nai_target) < 1.0:
			_fail("生活站点双槽位间距过小：%s" % station_id)


func _validate_text_commands(world: Node, controller: LifeLabTaskController) -> void:
	var result: Dictionary = world.execute_command("小奈过来我这", "ling")
	if not bool(result.get("ok", false)) or result.get("roles", []) != ["nai"] or str(result.get("action", "")) != "follow_player":
		_fail("‘小奈过来我这’解析错误：%s" % JSON.stringify(result))
	controller.request_action("nai", "stop")
	for command in [
		["她们一起做饭", "cook"], ["小玲泡茶", "brew_tea"], ["小奈读书", "read"],
		["她们一起看节目", "watch"], ["小奈玩游戏", "game"], ["小玲听音乐", "music"],
		["她们一起收拾房间", "clean"], ["小奈给花拍照", "photo"],
		["她们一起抱抱", "cuddle"], ["她们一起聊今天", "share_day"],
	]:
		result = world.execute_command(str(command[0]), "ling")
		if not bool(result.get("ok", false)) or str(result.get("action", "")) != str(command[1]):
			_fail("生活行为解析错误：%s -> %s" % [str(command[0]), JSON.stringify(result)])
		controller.request_action("ling", "stop")
		controller.request_action("nai", "stop")
	result = world.execute_command("小玲跟着小奈", "ling")
	if (
		not bool(result.get("ok", false))
		or result.get("roles", []) != ["ling"]
		or str(result.get("action", "")) != "follow_role"
		or str(result.get("target_role", "")) != "nai"
	):
		_fail("‘小玲跟着小奈’解析错误：%s" % JSON.stringify(result))
	controller.request_action("ling", "stop")
	result = world.execute_command("她们一起喝水", "ling")
	if not bool(result.get("ok", false)) or result.get("roles", []) != ["ling", "nai"]:
		_fail("双角色生活指令解析错误：%s" % JSON.stringify(result))
	controller.request_action("ling", "stop")
	controller.request_action("nai", "stop")


func _validate_social_events(world: Node, controller: LifeLabTaskController) -> void:
	var events: Array[Dictionary] = []
	controller.social_event_ready.connect(func(event: Dictionary): events.append(event))
	controller.call("_maybe_emit_social_event", {
		"id": "diagnostic-social-event",
		"role_id": "ling",
		"action": "read",
		"station_id": "rest",
		"initiated_by": "user",
	})
	if events.size() != 1:
		_fail("单人社会行为没有产生一次生活事件")
		return
	var event := events[0]
	if str(event.get("protocol", "")) != "spring_haven.life_lab.social_event.v1":
		_fail("生活事件协议错误：%s" % JSON.stringify(event))
	if event.get("participant_role_ids", []) != ["ling", "nai"]:
		_fail("单人生活事件没有把另一角色作为观察者：%s" % JSON.stringify(event))
	world.set("_social_dialogue_enabled", false)


func _validate_offline_life_action(world: Node, controller: LifeLabTaskController) -> void:
	world.call("_on_life_autonomous_action", {
		"role_id": "nai",
		"action": "self_care_drink",
		"description": "小奈离线期间自己去喝水",
		"source": "companion_core_offline_life",
		"scene_action": {"schema_version": 1, "action": "move_to", "target_id": "dining_table"},
	})
	var task := controller.get_task("nai")
	if str(task.get("action", "")) != "drink":
		_fail("Core 离线生活动作没有映射到双角色导航任务：%s" % JSON.stringify(task))
	controller.request_action("nai", "stop")


func _validate_fall_recovery(world: Node) -> void:
	var agent: CharacterBody3D = world.get_agent("nai")
	world.force_fall_recovery("nai")
	for _index in 12:
		await get_tree().physics_frame
	if agent.global_position.y < -1.0:
		_fail("小奈跌落后没有返回最近安全位置")


func _planar_distance(from: Vector3, to: Vector3) -> float:
	var offset := to - from
	offset.y = 0.0
	return offset.length()


func _fail(message: String) -> void:
	_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("LIFE_LAB_WORLD_CHECK: PASS")
		get_tree().quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		print("LIFE_LAB_WORLD_CHECK: FAIL (%d)" % _failures.size())
		get_tree().quit(1)
