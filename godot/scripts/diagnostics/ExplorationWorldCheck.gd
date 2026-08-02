extends Node

const EXPLORATION_SCENE := preload("res://scenes/Exploration/ExplorationWorld.tscn")
const NAVIGATION_TIMEOUT_FRAMES := 600
const MOVE_TIMEOUT_FRAMES := 600
const ARRIVAL_TOLERANCE := 0.8
const FOLLOW_TOLERANCE := 2.1

var _checks := 0
var _failures: Array[String] = []


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var world := EXPLORATION_SCENE.instantiate()
	get_tree().root.add_child(world)
	await get_tree().process_frame
	await get_tree().physics_frame

	var player := world.get_node("Player3D") as CharacterBody3D
	var ling := world.get_node("LingAgent3D") as CharacterBody3D
	var ai_controller := world.get_node_or_null("ExplorationAIController")
	var dining_anchor := world.get_node(
		"NavigationRegion3D/GrayboxRoom/DiningSeatLing"
	) as Marker3D
	var sofa_anchor := world.get_node(
		"NavigationRegion3D/GrayboxRoom/SofaSpot"
	) as Marker3D

	_expect(is_instance_valid(player), "缺少玩家节点")
	_expect(is_instance_valid(ling), "缺少小玲节点")
	_expect(is_instance_valid(ai_controller), "缺少小玲无视觉 AI 控制器")
	_expect(is_instance_valid(dining_anchor), "缺少餐桌锚点")
	_expect(is_instance_valid(sofa_anchor), "缺少沙发锚点")
	if is_instance_valid(player) and is_instance_valid(ling):
		_check_character_scale(player, ling)
	if _failures.is_empty():
		var navigation_ready := await _wait_for_navigation(world)
		_expect(navigation_ready, "运行时导航网格未在时限内完成")
		if navigation_ready:
			_check_scene_context(ai_controller)
			_check_waiting_ui_remains_interactive(world)
			await _check_move(ling, dining_anchor, "餐桌")
			await _check_move(ling, sofa_anchor, "沙发")
			await _check_follow(ling, player, dining_anchor)
			_check_stop(ling)
			await _check_fall_recovery(player, ling)

	world.queue_free()
	await get_tree().process_frame
	if _failures.is_empty():
		print("EXPLORATION_WORLD_CHECK passed=", _checks)
		get_tree().quit(0)
		return
	for failure in _failures:
		printerr("EXPLORATION_WORLD_CHECK failure=", failure)
	get_tree().quit(1)


func _check_character_scale(player: CharacterBody3D, ling: CharacterBody3D) -> void:
	var player_collision := player.get_node_or_null("CollisionShape3D") as CollisionShape3D
	var player_capsule := player_collision.shape as CapsuleShape3D if player_collision else null
	var player_visual := player.get_node_or_null("VisualRoot") as Node3D
	_expect(player_capsule != null, "玩家缺少胶囊碰撞体")
	_expect(
		player_capsule != null and absf(player_capsule.height - 1.66) <= 0.01,
		"玩家碰撞高度没有随视觉缩小"
	)
	_expect(
		player_visual != null and absf(player_visual.scale.y - 0.68) <= 0.01,
		"玩家视觉比例不是目标 1.65 米档"
	)

	var ling_collision := ling.get_node_or_null("CollisionShape3D") as CollisionShape3D
	var ling_capsule := ling_collision.shape as CapsuleShape3D if ling_collision else null
	var ling_visual := ling.get_node_or_null("VisualPivot") as Node3D
	var navigation_agent := ling.get_node_or_null("NavigationAgent3D") as NavigationAgent3D
	_expect(ling_capsule != null, "小玲缺少胶囊碰撞体")
	_expect(
		ling_capsule != null and absf(ling_capsule.height - 1.62) <= 0.01,
		"小玲碰撞高度没有随视觉缩小"
	)
	_expect(
		ling_visual != null and absf(ling_visual.scale.y - 0.75) <= 0.01,
		"小玲回退视觉比例不是目标 1.61 米档"
	)
	_expect(
		navigation_agent != null
		and absf(navigation_agent.height - 1.62) <= 0.01
		and absf(navigation_agent.radius - 0.31) <= 0.01,
		"小玲导航代理没有与新体型同步"
	)


func _wait_for_navigation(world: Node) -> bool:
	for _frame in NAVIGATION_TIMEOUT_FRAMES:
		if world.get("_navigation_ready") == true:
			return true
		await get_tree().physics_frame
	return false


func _check_scene_context(ai_controller: Node) -> void:
	var context_variant = ai_controller.call("build_scene_state")
	_expect(context_variant is Dictionary, "AI 场景上下文不是字典")
	if not context_variant is Dictionary:
		return
	var context: Dictionary = context_variant
	_expect(
		str(context.get("protocol", "")) == "spring_heaven.scene_actions.v1",
		"AI 场景协议标识错误"
	)
	_expect(int(context.get("schema_version", 0)) == 1, "AI 场景 schema_version 错误")
	_expect(context.get("vision_available", true) == false, "无视觉声明未固定为 false")
	_expect(str(context.get("actor_role_id", "")) == "ling", "场景动作角色不是小玲")
	_expect(not _contains_forbidden_visual_or_motion_data(context), "场景上下文泄露视觉、坐标或速度字段")
	var entities = context.get("entities", [])
	_expect(entities is Array and entities.size() == 3, "场景实体白名单数量错误")
	var perception_variant = ai_controller.call("build_perception_state")
	_expect(perception_variant is Dictionary, "AI 感知状态不是字典")
	if perception_variant is Dictionary:
		var perception: Dictionary = perception_variant
		_expect(
			str(perception.get("protocol", "")) == "spring_heaven.perception.v1",
			"AI 感知协议标识错误"
		)
		_expect(str(perception.get("role_id", "")) == "ling", "AI 感知角色绑定错误")
		_expect(
			not _contains_forbidden_visual_or_motion_data(perception),
			"AI 感知状态泄漏了坐标或运动数据"
		)


func _check_waiting_ui_remains_interactive(world: Node) -> void:
	world.call("_set_ai_waiting", true)
	var input := world.get_node(
		"HUD/SafeMargin/CommandPanel/PanelMargin/Commands/ChatInputRow/ChatInput"
	) as LineEdit
	var send_button := world.get_node(
		"HUD/SafeMargin/CommandPanel/PanelMargin/Commands/ChatInputRow/ChatSendButton"
	) as Button
	var dining_button := world.get_node(
		"HUD/SafeMargin/CommandPanel/PanelMargin/Commands/DiningButton"
	) as Button
	var return_button := world.get_node(
		"HUD/SafeMargin/CommandPanel/PanelMargin/Commands/ReturnButton"
	) as Button
	_expect(input.editable, "等待回复时文本框被锁定")
	_expect(not send_button.disabled, "等待回复时发送按钮变灰")
	_expect(not dining_button.disabled, "等待回复时场景动作按钮变灰")
	_expect(not return_button.disabled, "等待回复时返回按钮变灰")
	world.call("_set_ai_waiting", false)


func _contains_forbidden_visual_or_motion_data(value: Variant) -> bool:
	if value is Dictionary:
		for key_variant in value:
			var key := str(key_variant).to_lower()
			if key in [
				"position",
				"world_position",
				"coordinates",
				"velocity",
				"speed",
				"transform",
				"node_path",
				"screenshot",
				"image",
			]:
				return true
			if _contains_forbidden_visual_or_motion_data(value[key_variant]):
				return true
	elif value is Array:
		for item in value:
			if _contains_forbidden_visual_or_motion_data(item):
				return true
	return false


func _check_move(ling: CharacterBody3D, anchor: Marker3D, label: String) -> void:
	ling.call("command_move_to", anchor.global_position, label)
	var state := await _wait_for_terminal_state(ling)
	var distance := _planar_distance(ling.global_position, anchor.global_position)
	_expect(str(state.get("status", "")) == "arrived", "小玲未能抵达%s：%s" % [label, state])
	_expect(distance <= ARRIVAL_TOLERANCE, "小玲抵达%s的误差过大：%.3f" % [label, distance])


func _wait_for_terminal_state(ling: CharacterBody3D) -> Dictionary:
	for _frame in MOVE_TIMEOUT_FRAMES:
		var state: Dictionary = ling.call("get_action_state")
		var status := str(state.get("status", ""))
		if status == "arrived" or status.begins_with("failed_"):
			return state
		await get_tree().physics_frame
	return ling.call("get_action_state")


func _check_follow(
	ling: CharacterBody3D,
	player: CharacterBody3D,
	target_anchor: Marker3D
) -> void:
	player.velocity = Vector3.ZERO
	player.global_position = target_anchor.global_position
	await get_tree().physics_frame
	var start_distance := _planar_distance(ling.global_position, player.global_position)
	ling.call("command_follow", player)
	var reached_follow_distance := false
	for _frame in MOVE_TIMEOUT_FRAMES:
		if _planar_distance(ling.global_position, player.global_position) <= FOLLOW_TOLERANCE:
			reached_follow_distance = true
			break
		await get_tree().physics_frame
	var final_distance := _planar_distance(ling.global_position, player.global_position)
	_expect(start_distance > FOLLOW_TOLERANCE, "跟随测试起点距离不足")
	_expect(reached_follow_distance, "小玲未进入跟随距离：%.3f" % final_distance)


func _check_stop(ling: CharacterBody3D) -> void:
	ling.call("command_stop")
	var state: Dictionary = ling.call("get_action_state")
	_expect(str(state.get("status", "")) == "stopped", "停止指令状态错误：%s" % state)


func _check_fall_recovery(player: CharacterBody3D, ling: CharacterBody3D) -> void:
	player.velocity = Vector3.ZERO
	player.global_position = Vector3(0.0, -13.0, 0.0)
	ling.velocity = Vector3.ZERO
	ling.global_position = Vector3(0.0, -13.0, 0.0)
	for _frame in 12:
		await get_tree().physics_frame
	_expect(player.global_position.y > -1.0, "玩家坠落后没有复位")
	_expect(ling.global_position.y > -1.0, "小玲坠落后没有复位")


func _planar_distance(from: Vector3, to: Vector3) -> float:
	var offset := to - from
	offset.y = 0.0
	return offset.length()


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
