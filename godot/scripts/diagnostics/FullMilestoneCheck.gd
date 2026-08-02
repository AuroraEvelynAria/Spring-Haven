extends SceneTree

const GLOBAL_SCRIPT := preload("res://scripts/autoload/Global.gd")

var _failures: Array[String] = []
var _checks := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var model := GLOBAL_SCRIPT.new()
	root.add_child(model)
	model.save_id = "save-test"
	model.full_stat_milestones = {}

	var first_changes: Array[Dictionary] = [{
		"stat": "intimacy",
		"old_value": 99.0,
		"new_value": 100.0
	}]
	var first: Array = model.call(
		"_build_first_full_milestones",
		"ling",
		"message-1",
		"effect-1",
		first_changes
	)
	_expect(first.size() == 1, "99→100 应产生首次满值事件")
	if first.size() == 1:
		var milestone: Dictionary = first[0]
		_expect(str(milestone.get("role_id", "")) == "ling", "满值事件角色错误")
		_expect(str(milestone.get("stat_key", "")) == "intimacy", "满值事件属性错误")
		_expect(str(milestone.get("milestone_id", "")).begins_with("full-"), "满值事件 ID 无效")
		model.full_stat_milestones["ling:intimacy"] = milestone
	var duplicate_changes: Array[Dictionary] = [{
		"stat": "intimacy",
		"old_value": 80.0,
		"new_value": 100.0
	}]
	var duplicate: Array = model.call(
		"_build_first_full_milestones",
		"ling",
		"message-2",
		"effect-2",
		duplicate_changes
	)
	_expect(duplicate.is_empty(), "已登记属性不应再次产生首次满值事件")
	var unchanged_changes: Array[Dictionary] = [{
		"stat": "mood",
		"old_value": 100.0,
		"new_value": 100.0
	}]
	var unchanged: Array = model.call(
		"_build_first_full_milestones",
		"nai",
		"message-3",
		"effect-3",
		unchanged_changes
	)
	_expect(unchanged.is_empty(), "100→100 不应产生满值事件")

	var migrated: Dictionary = model.call("_migrate_v2_to_v3", {
		"version": 2,
		"save_id": "legacy-save",
		"stats_by_role": {
			"ling": {"health": 100.0},
			"nai": {"stamina": 55.0}
		},
		"conversation_history": [],
		"applied_local_effect_ids": []
	})
	_expect(int(migrated.get("version", 0)) == 3, "v2→v3 未写入版本号")
	var ledger = migrated.get("full_stat_milestones", {})
	_expect(ledger is Dictionary and ledger.has("ling:health"), "迁移未登记已有满值")
	if ledger is Dictionary and ledger.has("ling:health"):
		_expect(
			str((ledger["ling:health"] as Dictionary).get("kind", "")) == "preexisting_stat_max",
			"迁移已有满值不应生成待回应事件"
		)

	model.free()
	if _failures.is_empty():
		print("FULL_MILESTONE_CHECK passed=", _checks)
		quit(0)
		return
	for failure in _failures:
		printerr("FULL_MILESTONE_CHECK failure=", failure)
	quit(1)

func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
