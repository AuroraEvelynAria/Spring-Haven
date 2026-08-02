extends SceneTree

const RULES := preload("res://scripts/domain/InteractionRules.gd")
const GLOBAL_SCRIPT := preload("res://scripts/autoload/Global.gd")

var _failures: Array[String] = []
var _checks := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var model := GLOBAL_SCRIPT.new()
	model.save_id = "climax-cycle-check"
	model.current_character = "ling"
	model.stats_by_role = model.call("_normalize_stats_by_role", {})
	model.conversation_history = []
	model.applied_local_effect_ids = []
	model.full_stat_milestones = {}
	model.life_runtime = model.call("_normalize_life_runtime", {})
	model.state_loaded = true

	var ling_defaults: Dictionary = model.get_role_stats("ling")
	var nai_defaults: Dictionary = model.get_role_stats("nai")
	_expect_float(ling_defaults, "arousal", 8.0, "小玲初始兴奋")
	_expect_float(nai_defaults, "arousal", 14.0, "小奈初始兴奋")
	var ling_spec := RULES.make_effect_spec("sex", "ling", "test", "test:ling", "effect-" + "1".repeat(48))
	var nai_spec := RULES.make_effect_spec("sex", "nai", "test", "test:nai", "effect-" + "2".repeat(48))
	_expect(
		_float_delta(nai_spec, "arousal") > _float_delta(ling_spec, "arousal"),
		"小奈兴奋增长应快于小玲"
	)
	_expect(
		_float_delta(nai_spec, "climax") > _float_delta(ling_spec, "climax"),
		"小奈高潮增长应快于小玲"
	)

	var nai_stats: Dictionary = model.get_role_stats("nai")
	nai_stats["arousal"] = 90.0
	nai_stats["climax"] = 35.0
	model.stats_by_role["nai"] = nai_stats
	var warmup := _commit_action(model, "nai", "sex", "3")
	_expect(bool(warmup.get("ok", false)), "兴奋未满时互动提交失败")
	_expect_float(model.get_role_stats("nai"), "arousal", 100.0, "兴奋达到满值")
	_expect_float(model.get_role_stats("nai"), "climax", 35.0, "兴奋未满时高潮不增长")

	var active := _commit_action(model, "nai", "sex", "4")
	_expect(bool(active.get("ok", false)), "兴奋满值后的互动提交失败")
	_expect_float(model.get_role_stats("nai"), "arousal", 100.0, "兴奋满值保持锁定")
	_expect(float(model.get_role_stats("nai").get("climax", 0.0)) > 35.0, "兴奋满值后高潮应增长")

	nai_stats = model.get_role_stats("nai")
	nai_stats["arousal"] = 100.0
	nai_stats["climax"] = 95.0
	model.stats_by_role["nai"] = nai_stats
	var cycle := _commit_action(model, "nai", "sex", "5")
	_expect(bool(cycle.get("ok", false)), "高潮循环提交失败")
	var reset_value := float(model.get_role_stats("nai").get("climax", -1.0))
	_expect(reset_value >= 0.0 and reset_value <= 20.0, "高潮完成后未重置到 0-20")
	var events = cycle.get("cycle_events", [])
	_expect(events is Array and events.size() == 1, "高潮完成后缺少唯一循环事件")
	if events is Array and events.size() == 1:
		var event: Dictionary = events[0]
		_expect(str(event.get("kind", "")) == "climax_cycle_completed", "循环事件类型错误")
		_expect(is_equal_approx(float(event.get("reset_value", -1.0)), reset_value), "循环事件重置值与状态不一致")

	var continuation := _commit_action(model, "nai", "sex", "6")
	_expect(bool(continuation.get("ok", false)), "循环后的继续互动提交失败")
	_expect_float(model.get_role_stats("nai"), "arousal", 100.0, "循环后兴奋仍应保持满值")
	_expect(float(model.get_role_stats("nai").get("climax", 0.0)) > reset_value, "循环后高潮没有继续增长")

	model.free()
	if _failures.is_empty():
		print("CLIMAX_CYCLE_CHECK passed=", _checks)
		quit(0)
		return
	for failure in _failures:
		printerr("CLIMAX_CYCLE_CHECK failure=", failure)
	quit(1)

func _commit_action(model: Node, role: String, action: String, suffix: String) -> Dictionary:
	var event_id := "effect-" + suffix.repeat(48)
	var spec := RULES.make_effect_spec(action, role, "test", "test:%s" % suffix, event_id)
	return model.commit_user_message({
		"id": "message-%s" % suffix,
		"text": "诊断互动 %s" % suffix,
		"status": "pending",
		"event_type": "action",
	}, role, spec)

func _float_delta(spec: Dictionary, stat: String) -> float:
	for update_variant in spec.get("updates", []):
		if update_variant is Array and update_variant.size() >= 2 and str(update_variant[0]) == stat:
			return float(update_variant[1])
	return 0.0

func _expect_float(values: Dictionary, key: String, expected: float, label: String) -> void:
	_expect(is_equal_approx(float(values.get(key, -999.0)), expected), "%s 不符合预期" % label)

func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
