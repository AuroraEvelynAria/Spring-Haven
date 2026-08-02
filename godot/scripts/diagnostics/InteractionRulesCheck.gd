extends SceneTree

const RULES := preload("res://scripts/domain/InteractionRules.gd")
const GLOBAL_SCRIPT := preload("res://scripts/autoload/Global.gd")

var _failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_expect_action("抱抱", "hug")
	_expect_action("我现在抱抱你", "hug")
	_expect_action("亲亲", "kiss")
	_expect_action("我给你倒了水", "drink")
	_expect_action("睡一会吧", "sleep")
	_expect_action("摸摸头", "comfort")
	_expect_action("我爱你", "praise")
	_expect_action("别怕我在", "comfort")
	_expect_action("一起吃饭", "eat")
	_expect_action("去休息吧", "sleep")
	_expect_action("陪你去散步", "exercise")
	_expect_action("去上厕所吧", "toilet")
	_expect_action("帮你处理伤口", "care")
	_expect_action("一起玩游戏吧", "play")
	_expect_action("我们自愿做爱", "sex")
	_expect_action("别难过，抱抱你", "hug")
	_expect_action("抱抱你，亲你一下", "kiss")
	# Real archive misses and natural paraphrases must use the semantic grammar.
	_expect_action("来，我喂你点东西吃", "eat")
	_expect_action("小玲到我怀里吧，我把你抱回床上去", "hug")
	_expect_action("主人把你俩都抱在怀里", "hug")
	_expect_action("我把刚倒好的温水递到你手里了", "drink")
	_expect_action("小玲吃吧，慢慢吃", "eat")
	_expect_action("嗯，那小奈来亲我吧", "kiss")
	_expect_action("我很爱你", "praise")
	_expect_action("我们出去走走吧", "exercise")
	_expect_action("我给你包扎一下伤口", "care")
	_expect_action("我们一起看会儿电影", "play")
	_expect_action("给你准备了吃的", "eat")
	_expect_source("来，我喂你点东西吃", "natural_semantic")
	_expect_source("我给你倒了水", "natural_keyword")

	for text in [
		"不要抱抱",
		"可以抱抱吗？",
		"她说“抱抱”",
		"https://example.invalid/抱抱",
		"`抱抱`",
		"这只是抱怨",
		"hugging",
		"想抱抱你，但还是算了",
		"可以陪你去散步吗？",
		"她说去上厕所吧",
		"我想和你做爱",
		"我们讨论做爱这个词",
		"今晚想和小玲一起吃晚饭",
		"小奈要把热可可端来一起喝吗",
		"小玲痛经的时候，我们会抱着你",
		"那我们吃完之后一起去睡觉",
		"主人困得睡着了",
		"主人以后陪你玩游戏",
	]:
		_expect_empty(text)

	var ling_hug: Dictionary = RULES.make_effect_spec("hug", "ling", "test", "test:hug", "effect-a")
	_expect_delta(ling_hug, "intimacy", 2.4)
	_expect_delta(ling_hug, "mood", 2.4)
	_expect_delta(ling_hug, "stress", -3.6)
	var nai_hug: Dictionary = RULES.make_effect_spec("hug", "nai", "test", "test:hug", "effect-b")
	_expect_delta(nai_hug, "intimacy", 1.8)
	_expect_delta(nai_hug, "stress", -2.7)
	var ling_sleep: Dictionary = RULES.make_effect_spec("sleep", "ling", "test", "test:sleep", "effect-c")
	_expect_delta(ling_sleep, "awake", 16.8)
	_expect_delta(ling_sleep, "stamina", 19.2)

	var customized_hug: Dictionary = RULES.make_effect_spec(
		"hug",
		"ling",
		"test",
		"test:custom-hug",
		"effect-custom",
		{
			"intimacy": 9.94,
			"stress": -8.26,
			"mood": "invalid",
			"unknown_stat": 50.0
		}
	)
	_expect_delta(customized_hug, "intimacy", 9.9)
	_expect_delta(customized_hug, "stress", -8.3)
	_expect_delta(customized_hug, "mood", 2.4)
	var out_of_range_hug: Dictionary = RULES.make_effect_spec(
		"hug", "ling", "test", "test:range", "effect-range", {"intimacy": 1000.0}
	)
	_expect_delta(out_of_range_hug, "intimacy", 2.4)
	var non_finite_hug: Dictionary = RULES.make_effect_spec(
		"hug",
		"ling",
		"test",
		"test:non-finite",
		"effect-non-finite",
		{"intimacy": NAN, "mood": INF, "stress": true}
	)
	_expect_delta(non_finite_hug, "intimacy", 2.4)
	_expect_delta(non_finite_hug, "mood", 2.4)
	_expect_delta(non_finite_hug, "stress", -3.6)
	if "unknown_stat" in RULES.action_stat_keys("hug"):
		_failures.append("动作属性白名单包含未知属性")
	if RULES.default_delta("nai", "sleep", "awake") == null:
		_failures.append("无法读取默认角色动作 delta")

	var id_a := RULES.deterministic_event_id("save-a", "message-a", "ling", "hug")
	var id_b := RULES.deterministic_event_id("save-a", "message-a", "ling", "hug")
	var id_c := RULES.deterministic_event_id("save-a", "message-a", "nai", "hug")
	if id_a != id_b or id_a == id_c or id_a.length() > 128:
		_failures.append("deterministic_event_id 不稳定、未隔离角色或超长")
	if not RULES.match_natural_action("主人与你亲密相伴").is_empty():
		_failures.append("含糊的亲密表述不应触发 sex")

	var gentle_hug_match := RULES.match_natural_action("轻轻抱抱你")
	_expect_float(gentle_hug_match, "intensity_multiplier", 0.75, "轻度动作倍率")
	var gentle_hug := RULES.make_effect_spec(
		"hug", "ling", "test", "test:gentle", "effect-gentle", {},
		float(gentle_hug_match.get("intensity_multiplier", 1.0))
	)
	_expect_delta(gentle_hug, "intimacy", 1.8)
	var strong_hug_match := RULES.match_natural_action("紧紧抱抱你")
	_expect_float(strong_hug_match, "intensity_multiplier", 1.35, "强动作倍率")
	var strong_hug := RULES.make_effect_spec(
		"hug", "ling", "test", "test:strong", "effect-strong", {},
		float(strong_hug_match.get("intensity_multiplier", 1.0))
	)
	_expect_delta(strong_hug, "intimacy", 3.2)
	var ling_care := RULES.make_effect_spec("care", "ling", "test", "test:care", "effect-care")
	_expect_delta(ling_care, "health", 6.6)
	var nai_exercise := RULES.make_effect_spec("exercise", "nai", "test", "test:exercise", "effect-exercise")
	_expect_delta(nai_exercise, "health", 2.9)
	_expect_delta(nai_exercise, "stamina", -9.2)

	var global_model := GLOBAL_SCRIPT.new()
	root.add_child(global_model)
	var ling_defaults: Dictionary = global_model.call("_default_stats_for_role", "ling")
	var nai_defaults: Dictionary = global_model.call("_default_stats_for_role", "nai")
	_expect_float(ling_defaults, "intimacy", 100.0, "小玲默认好感")
	_expect_float(ling_defaults, "stamina", 46.0, "小玲默认体力")
	_expect_float(nai_defaults, "intimacy", 100.0, "小奈默认好感")
	_expect_float(nai_defaults, "stamina", 68.0, "小奈默认体力")
	var migrated: Dictionary = global_model.call("_migrate_v1_to_v2", {
		"version": 1,
		"stats_by_role": {
			"ling": {"health": 44.0},
			"nai": {"stamina": 55.0}
		},
		"conversation_history": []
	})
	var migrated_ling: Dictionary = migrated.get("stats_by_role", {}).get("ling", {})
	var migrated_nai: Dictionary = migrated.get("stats_by_role", {}).get("nai", {})
	_expect_float(migrated_ling, "health", 44.0, "迁移保留小玲现有健康")
	_expect_float(migrated_ling, "stamina", 46.0, "迁移补齐小玲体力")
	_expect_float(migrated_nai, "stamina", 55.0, "迁移保留小奈现有体力")
	_expect_float(migrated_nai, "intimacy", 100.0, "迁移补齐小奈好感")
	if int(migrated.get("version", 0)) != 2 or int(migrated.get("balance_version", 0)) != 5:
		_failures.append("v1→v2 没有写入版本信息")
	var migrated_v6: Dictionary = global_model.call("_migrate_v5_to_v6", {
		"version": 5,
		"balance_version": 4,
		"stats_by_role": {
			"ling": {"intimacy": 36.0, "mood": 62.0},
			"nai": {"intimacy": 26.0, "mood": 70.0},
		},
	})
	_expect_float(migrated_v6.stats_by_role.ling, "intimacy", 100.0, "v6 迁移小玲好感")
	_expect_float(migrated_v6.stats_by_role.nai, "intimacy", 100.0, "v6 迁移小奈好感")
	_expect_float(migrated_v6.stats_by_role.ling, "mood", 62.0, "v6 迁移保留其他属性")
	if int(migrated_v6.get("version", 0)) != 6 or int(migrated_v6.get("balance_version", 0)) != 5:
		_failures.append("v5→v6 没有写入版本信息")
	global_model.free()

	if _failures.is_empty():
		print("INTERACTION_RULES_CHECK passed")
		quit(0)
		return
	for failure in _failures:
		printerr("INTERACTION_RULES_CHECK failure=", failure)
	quit(1)

func _expect_action(text: String, expected: String) -> void:
	var result: Dictionary = RULES.match_natural_action(text)
	var actual := str(result.get("action", ""))
	if actual != expected:
		_failures.append("%s 期望 %s，实际 %s" % [text, expected, actual])

func _expect_empty(text: String) -> void:
	var result: Dictionary = RULES.match_natural_action(text)
	if not result.is_empty():
		_failures.append("%s 不应触发，实际 %s" % [text, result.get("action", "")])

func _expect_source(text: String, expected: String) -> void:
	var result: Dictionary = RULES.match_natural_action(text)
	var actual := str(result.get("source", ""))
	if actual != expected:
		_failures.append("%s 期望来源 %s，实际 %s" % [text, expected, actual])

func _expect_delta(spec: Dictionary, stat: String, expected: float) -> void:
	var found := false
	for update_variant in spec.get("updates", []):
		if update_variant is Array and update_variant.size() >= 2 and str(update_variant[0]) == stat:
			found = true
			var actual := float(update_variant[1])
			if not is_equal_approx(actual, expected):
				_failures.append("%s 期望变化 %.1f，实际 %.1f" % [stat, expected, actual])
			break
	if not found:
		_failures.append("效果缺少属性 %s" % stat)

func _expect_float(values: Dictionary, key: String, expected: float, label: String) -> void:
	var actual := float(values.get(key, -999.0))
	if not is_equal_approx(actual, expected):
		_failures.append("%s 期望 %.1f，实际 %.1f" % [label, expected, actual])
