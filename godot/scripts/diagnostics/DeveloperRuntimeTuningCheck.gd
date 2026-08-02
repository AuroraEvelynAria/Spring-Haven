extends Node

const TUNING := preload("res://scripts/domain/DeveloperRuntimeTuning.gd")
const CYCLE := preload("res://scripts/domain/MenstrualCycle.gd")
const GLOBAL_SCRIPT := preload("res://scripts/autoload/Global.gd")

var _checks := 0
var _failures: Array[String] = []

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var defaults := TUNING.defaults()
	_expect(defaults.size() == TUNING.SPECS.size(), "默认值没有覆盖全部运行参数")
	_expect(str(defaults.default_reply_mode) == "selected", "默认回复方式错误")
	_expect(int(defaults.ling_cycle_length_days) == 29, "小玲周期默认值错误")
	_expect(int(defaults.nai_cycle_length_days) == 27, "小奈周期默认值错误")

	var normalized := TUNING.normalize({
		"proactive_min_minutes": 500,
		"proactive_max_minutes": 20,
		"exploration_min_seconds": 300,
		"exploration_max_seconds": 10,
		"ling_cycle_length_days": 21,
		"ling_period_length_days": 8,
		"ling_initial_cycle_day": 40,
		"self_care_message_chance": 8.0,
		"unknown": 999,
	})
	_expect(int(normalized.proactive_max_minutes) == 500, "主动消息区间关系没有修正")
	_expect(int(normalized.exploration_max_seconds) == 300, "探索区间关系没有修正")
	_expect(int(normalized.ling_period_length_days) == 6, "周期与经期长度关系没有修正")
	_expect(int(normalized.ling_initial_cycle_day) == 21, "初始周期日没有限制在周期内")
	_expect_float(float(normalized.self_care_message_chance), 1.0, "概率没有限制到 100%")
	_expect(not normalized.has("unknown"), "未知运行参数未被移除")

	CYCLE.configure_runtime_tuning(normalized)
	var ling_profile := CYCLE.profile_for_role("ling")
	_expect(int(ling_profile.cycle_length_days) == 21, "生理配置没有接入周期模型")
	_expect(int(ling_profile.period_length_days) == 6, "生理配置关系没有接入周期模型")
	CYCLE.configure_runtime_tuning(defaults)

	_expect_float(
		float((GLOBAL_SCRIPT.ROLE_DEFAULT_STATS.ling as Dictionary).intimacy),
		100.0,
		"小玲项目默认好感不是 100"
	)
	_expect_float(
		float((GLOBAL_SCRIPT.ROLE_DEFAULT_STATS.nai as Dictionary).intimacy),
		100.0,
		"小奈项目默认好感不是 100"
	)

	var developer: Dictionary = Settings.call("_normalize_developer_settings_value", {
		"interaction_schema_version": 2,
		"interaction_delta_overrides": {},
		"runtime_tuning": {"thinking_intensity": 1.7},
		"role_default_stats": {"ling": {"mood": 88.0}},
	}, "save-test")
	_expect_float(float(developer.runtime_tuning.thinking_intensity), 1.7, "运行参数未保留")
	_expect_float(float(developer.role_default_stats.ling.mood), 88.0, "角色默认属性未保留")

	var runtime_before := Settings.get_runtime_tuning()
	var runtime_save_result: Dictionary = Settings.set_runtime_tuning({
		"thinking_intensity": 1.7,
		"default_reply_mode": "both",
	})
	_expect(bool(runtime_save_result.get("ok", false)), "运行参数保存接口失败")
	var saved_config := ConfigFile.new()
	_expect(saved_config.load("user://settings.cfg") == OK, "运行参数设置文件无法读取")
	var saved_runtime = saved_config.get_value("developer", "runtime_tuning", {})
	_expect(saved_runtime is Dictionary, "运行参数没有以字典写入设置文件")
	if saved_runtime is Dictionary:
		_expect_float(float(saved_runtime.get("thinking_intensity", 0.0)), 1.7, "运行参数写入值错误")
		_expect(str(saved_runtime.get("default_reply_mode", "")) == "both", "回复方式写入值错误")
	Settings.set_runtime_tuning(runtime_before)

	var defaults_before: Dictionary = Settings.settings.get("developer", {}).duplicate(true)
	var role_save_result: Dictionary = Settings.set_role_default_stats("ling", {"mood": 88.0})
	_expect(bool(role_save_result.get("ok", false)), "新旅程默认属性保存接口失败")
	var saved_role_defaults = Settings.settings.developer.get("role_default_stats", {})
	var saved_ling_defaults = (
		saved_role_defaults.get("ling", {}) if saved_role_defaults is Dictionary else {}
	)
	_expect(
		saved_role_defaults is Dictionary
		and saved_ling_defaults is Dictionary
		and is_equal_approx(float(saved_ling_defaults.get("mood", 0.0)), 88.0),
		"新旅程默认属性没有写入设置"
	)
	Settings.settings["developer"] = defaults_before
	Settings.save()

	if _failures.is_empty():
		print("DEVELOPER_RUNTIME_TUNING_CHECK passed=", _checks)
		get_tree().quit(0)
		return
	for failure in _failures:
		printerr("DEVELOPER_RUNTIME_TUNING_CHECK failure=", failure)
	get_tree().quit(1)

func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)

func _expect_float(actual: float, expected: float, message: String) -> void:
	_expect(is_equal_approx(actual, expected), "%s expected=%.2f actual=%.2f" % [
		message, expected, actual
	])
