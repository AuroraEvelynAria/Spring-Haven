extends SceneTree

const CONTRACT := preload("res://scripts/domain/SceneActionContract.gd")

var _checks := 0
var _failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var actor_input := {
		"actor_role_id": "ling",
		"mode": "follow",
		"status": "recovering_stuck",
		"target_id": "player",
		"semantic_position": "near_player",
		"can_move": true,
		"target_position": Vector3(1.0, 2.0, 3.0),
		"distance_remaining": 3.0,
	}
	var player_input := {
		"status": "moving",
		"semantic_position": "near_sofa",
		"is_present": true,
		"position": Vector3.ZERO,
	}
	var entities_input := [
		{
			"id": "dining_table",
			"label": "恶意覆盖标签",
			"distance_m": 2.345,
			"reachable": true,
			"position": Vector3.ONE,
		},
		{"id": "sofa", "distance_m": true, "reachable": 1},
		{"id": "player", "distance_m": INF, "reachable": true},
		{"id": "outside", "distance_m": 1.0, "reachable": true},
	]
	var inputs_snapshot := [
		actor_input.duplicate(true),
		player_input.duplicate(true),
		entities_input.duplicate(true),
	]
	var context: Dictionary = CONTRACT.build_scene_context(
		"living_dining_room",
		7,
		actor_input,
		player_input,
		entities_input
	)

	_expect(not context.is_empty(), "合法上下文构建失败")
	_expect(str(context.get("protocol", "")) == CONTRACT.PROTOCOL, "协议标记错误")
	_expect(int(context.get("schema_version", 0)) == 1, "上下文 schema_version 错误")
	_expect(str(context.get("scene_id", "")) == "living_dining_room", "scene_id 错误")
	_expect(int(context.get("revision", -1)) == 7, "revision 错误")
	_expect(context.get("vision_available", true) == false, "无视觉标记错误")
	_expect(str(context.get("actor_role_id", "")) == "ling", "角色绑定错误")
	_expect(
		context.keys() == [
			"protocol",
			"schema_version",
			"scene_id",
			"revision",
			"vision_available",
			"actor_role_id",
			"actor_state",
			"player_state",
			"entity_whitelist",
			"entities",
			"available_actions",
		],
		"上下文顶层字段不稳定"
	)

	var actor_state: Dictionary = context.get("actor_state", {})
	var player_state: Dictionary = context.get("player_state", {})
	_expect(str(actor_state.get("mode", "")) == "follow_player", "follow 模式未规范化")
	_expect(str(actor_state.get("status", "")) == "recovering", "恢复状态未语义化")
	_expect(not actor_state.has("target_position"), "actor_state 泄露了坐标")
	_expect(not actor_state.has("distance_remaining"), "actor_state 泄露了低层距离")
	_expect(not player_state.has("position"), "player_state 泄露了坐标")
	_expect(
		context.get("entity_whitelist", []) == ["dining_table", "sofa", "player"],
		"实体白名单错误"
	)
	var entities: Array = context.get("entities", [])
	_expect(entities.size() == 3, "实体语义数组没有固定为三个白名单实体")
	_expect(str(entities[0].get("label", "")) == "餐桌", "调用方覆盖了固定实体标签")
	_expect(is_equal_approx(float(entities[0].get("distance_m", -1.0)), 2.35), "距离未规范到两位小数")
	_expect(float(entities[1].get("distance_m", 0.0)) == -1.0, "bool 被当作实体距离")
	_expect(bool(entities[1].get("reachable", true)) == false, "数字被当作 reachable bool")
	_expect(float(entities[2].get("distance_m", 0.0)) == -1.0, "Inf 实体距离未被清除")
	var context_json := JSON.stringify(context)
	_expect(not context_json.contains("target_position"), "上下文 JSON 泄露目标坐标")
	_expect(not context_json.contains("\"position\":"), "上下文 JSON 泄露原始坐标字段")
	_expect(
		JSON.stringify([actor_input, player_input, entities_input])
		== JSON.stringify(inputs_snapshot),
		"构建上下文原地修改了输入"
	)

	var normalized := CONTRACT.normalize_scene_context(context)
	_expect(JSON.stringify(normalized) == JSON.stringify(context), "上下文规范化不幂等")
	var detached_context := CONTRACT.normalize_scene_context(context)
	(detached_context["actor_state"] as Dictionary)["status"] = "tampered"
	(detached_context["entities"] as Array)[0]["label"] = "tampered"
	_expect(str(context["actor_state"].get("status", "")) == "recovering", "actor_state 没有深拷贝")
	_expect(str(context["entities"][0].get("label", "")) == "餐桌", "entities 没有深拷贝")

	_expect(CONTRACT.build_scene_context("other_scene", 1).is_empty(), "接受了未知场景")
	for invalid_revision in [true, -1, 1.5, NAN, INF, "1", 2_147_483_648]:
		_expect(
			CONTRACT.build_scene_context("living_dining_room", invalid_revision).is_empty(),
			"接受了非法 revision：%s" % str(invalid_revision)
		)
	var visual_context := context.duplicate(true)
	visual_context["vision_available"] = true
	_expect(CONTRACT.normalize_scene_context(visual_context).is_empty(), "接受了视觉能力伪装")
	var bool_schema_context := context.duplicate(true)
	bool_schema_context["schema_version"] = true
	_expect(CONTRACT.normalize_scene_context(bool_schema_context).is_empty(), "bool 被当作上下文 schema_version")

	_check_valid_actions(context)
	_check_rejected_actions(context)
	_check_action_arrays(context)

	if _failures.is_empty():
		print("SCENE_ACTION_CONTRACT_CHECK passed=", _checks)
		quit(0)
		return
	for failure in _failures:
		printerr("SCENE_ACTION_CONTRACT_CHECK failure=", failure)
	quit(1)


func _check_valid_actions(context: Dictionary) -> void:
	for target_id in ["dining_table", "sofa"]:
		var raw := {
			"schema_version": 1,
			"action": "move_to",
			"target_id": target_id,
		}
		var result: Dictionary = CONTRACT.validate_action(raw, context)
		_expect(bool(result.get("ok", false)), "合法 move_to 被拒绝：%s" % target_id)
		_expect(
			result.get("action", {}).get("target_id", "") == target_id,
			"move_to 目标规范化错误"
		)
		raw["target_id"] = "tampered"
		_expect(
			result.get("action", {}).get("target_id", "") == target_id,
			"动作验证结果没有与输入深拷贝"
		)
	for action in ["follow_player", "stop"]:
		var result: Dictionary = CONTRACT.validate_action(
			{"schema_version": 1, "action": action},
			context
		)
		_expect(bool(result.get("ok", false)), "合法动作被拒绝：%s" % action)
		_expect(result.get("action", {}).keys().size() == 2, "%s 返回了多余字段" % action)
	var wire_action = JSON.parse_string(
		'{"schema_version":1,"action":"move_to","target_id":"dining_table"}'
	)
	_expect(wire_action is Dictionary, "Godot 未能解析 Bridge 动作 JSON")
	var wire_result: Dictionary = CONTRACT.validate_action(wire_action, context)
	_expect(bool(wire_result.get("ok", false)), "Bridge JSON 往返后的 schema_version 1.0 被错误拒绝")


func _check_rejected_actions(context: Dictionary) -> void:
	var attacks := [
		null,
		[],
		{},
		{"schema_version": true, "action": "stop"},
		{"schema_version": NAN, "action": "stop"},
		{"schema_version": INF, "action": "stop"},
		{"schema_version": 1.1, "action": "stop"},
		{"schema_version": 1, "action": "STOP"},
		{"schema_version": 1, "action": "stop", "target_id": "sofa"},
		{"schema_version": 1, "action": "follow_player", "target_id": "player"},
		{"schema_version": 1, "action": "move_to", "target_id": "player"},
		{"schema_version": 1, "action": "move_to", "target_id": "outside"},
		{"schema_version": 1, "action": "move_to", "target_id": true},
		{"schema_version": 1, "action": "move_to", "target_id": "a".repeat(65)},
		{"schema_version": 1, "action": "a".repeat(65)},
		{
			"schema_version": 1,
			"action": "move_to",
			"target_id": "dining_table",
			"position": [0, 0, 0],
		},
		{
			"schema_version": 1,
			"action": "move_to",
			"target_id": "sofa",
			"velocity": 999,
		},
		{
			"schema_version": 1,
			"action": "move_to",
			"target_id": "sofa",
			"x": NAN,
		},
	]
	for index in attacks.size():
		var result: Dictionary = CONTRACT.validate_action(attacks[index], context)
		_expect(not bool(result.get("ok", true)), "攻击动作 #%d 被接受" % index)
		_expect((result.get("action", {}) as Dictionary).is_empty(), "失败结果泄露了动作")

	var invalid_context := context.duplicate(true)
	invalid_context["protocol"] = "attacker.scene_actions.v1"
	_expect(
		not bool(CONTRACT.validate_action(
			{"schema_version": 1, "action": "stop"},
			invalid_context
		).get("ok", true)),
		"动作在错误协议上下文中通过"
	)


func _check_action_arrays(context: Dictionary) -> void:
	var empty_result: Dictionary = CONTRACT.validate_actions([], context)
	_expect(bool(empty_result.get("ok", false)), "空动作数组应合法")
	_expect((empty_result.get("actions", []) as Array).is_empty(), "空动作数组返回了动作")
	var single_result: Dictionary = CONTRACT.validate_actions(
		[{
			"schema_version": 1,
			"action": "move_to",
			"target_id": "dining_table",
		}],
		context
	)
	_expect(bool(single_result.get("ok", false)), "单动作数组被拒绝")
	var detached_actions: Array = single_result.get("actions", [])
	detached_actions[0]["target_id"] = "tampered"
	var single_again: Dictionary = CONTRACT.validate_actions(
		[{
			"schema_version": 1,
			"action": "move_to",
			"target_id": "dining_table",
		}],
		context
	)
	_expect(
		single_again.get("actions", [])[0].get("target_id", "") == "dining_table",
		"动作数组验证结果共享了可变状态"
	)
	var too_many := CONTRACT.validate_actions(
		[
			{"schema_version": 1, "action": "stop"},
			{"schema_version": 1, "action": "follow_player"},
		],
		context
	)
	_expect(not bool(too_many.get("ok", true)), "接受了超过一个动作")
	_expect(
		not bool(CONTRACT.validate_actions(
			{"schema_version": 1, "action": "stop"},
			context
		).get("ok", true)),
		"validate_actions 接受了非数组"
	)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
