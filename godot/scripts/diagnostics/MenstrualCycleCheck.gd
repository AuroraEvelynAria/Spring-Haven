extends Node

const CYCLE := preload("res://scripts/domain/MenstrualCycle.gd")

var _checks := 0
var _failures: Array[String] = []

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var now := 1_800_000_000
	var ling_profile := CYCLE.profile_for_role("ling")
	var nai_profile := CYCLE.profile_for_role("nai")
	_expect(int(ling_profile.cycle_length_days) == 29, "小玲周期长度错误")
	_expect(int(ling_profile.period_length_days) == 5, "小玲经期长度错误")
	_expect(int(nai_profile.cycle_length_days) == 27, "小奈周期长度错误")
	_expect(int(nai_profile.period_length_days) == 4, "小奈经期长度错误")
	_expect_approx(float(ling_profile.contraceptive_dose_units), 1.0, "小玲标准剂量错误")
	_expect_approx(float(nai_profile.contraceptive_dose_units), 0.5, "小奈标准剂量错误")
	_expect_approx(float(ling_profile.contraceptive_residual_factor), 0.05, "小玲残余系数错误")
	_expect_approx(float(nai_profile.contraceptive_residual_factor), 0.05, "小奈残余系数错误")
	_expect(
		int(ling_profile.cycle_length_days) != int(nai_profile.cycle_length_days),
		"两人的周期长度不应相同"
	)
	_expect(
		int(ling_profile.initial_cycle_day) != int(nai_profile.initial_cycle_day),
		"两人的初始周期相位不应同步"
	)

	var ling_runtime := CYCLE.normalize_runtime("ling", {}, now)
	var nai_runtime := CYCLE.normalize_runtime("nai", {}, now)
	var ling_current := CYCLE.current_snapshot("ling", ling_runtime, now)
	var nai_current := CYCLE.current_snapshot("nai", nai_runtime, now)
	_expect(int(ling_current.cycle_day) == 3, "小玲初始周期日错误")
	_expect(str(ling_current.phase) == "menstrual", "小玲初始相位应为经期")
	_expect(int(nai_current.cycle_day) == 17, "小奈初始周期日错误")
	_expect(str(nai_current.phase) == "luteal", "小奈初始相位应为黄体期")
	Global.stats_by_role = Global.call("_normalize_stats_by_role", {})
	Global.life_runtime = Global.call("_normalize_life_runtime", {})
	var ling_body_state := LifeSim.build_role_state("ling")
	var ling_body_cycle: Dictionary = ling_body_state.get("menstrual_cycle", {})
	_expect(int(ling_body_cycle.get("cycle_day", 0)) == 3, "身体状态未呈现小玲周期第 3 天")

	var menstrual := CYCLE.snapshot_from_absolute_day("ling", 0, now)
	_expect(str(menstrual.phase) == "menstrual", "周期第 1 天不是经期")
	_expect(str(menstrual.bleeding) == "moderate", "经期第 1 天经量状态错误")
	_expect(not bool(menstrual.fertile_window), "经期第 1 天不应属于易孕窗口")
	_expect_approx(float(menstrual.endometrial_receptivity_index), 2.0, "经期内膜容受性应低")
	_expect(bool(menstrual.contraception_active), "避孕状态未启用")
	_expect(not bool(menstrual.contraceptive_side_effects), "兽娘避孕药不应产生副作用")
	_expect_approx(float(menstrual.contraceptive_dose_units), 1.0, "小玲周期快照剂量错误")
	_expect_approx(float(menstrual.effective_implantation_likelihood_index), 0.1, "经期服药后着床倾向错误")

	var ovulation := CYCLE.snapshot_from_absolute_day("ling", 14, now)
	_expect(str(ovulation.phase) == "ovulation", "小玲排卵窗口日期错误")
	_expect(bool(ovulation.fertile_window), "排卵窗口未标记易孕")
	var receptive_peak := CYCLE.snapshot_from_absolute_day("ling", 21, now)
	_expect(str(receptive_peak.phase) == "luteal", "容受窗峰值不在黄体期")
	_expect_approx(float(receptive_peak.endometrial_receptivity_index), 100.0, "黄体中期容受性未达到峰值")
	_expect_approx(float(receptive_peak.effective_implantation_likelihood_index), 5.0, "峰值服药后着床倾向错误")
	_expect_approx(
		CYCLE.effective_implantation_likelihood_index(100.0, false, 0.05),
		100.0,
		"未服药时不应应用残余系数"
	)
	var premenstrual := CYCLE.snapshot_from_absolute_day("ling", 28, now)
	_expect(bool(premenstrual.premenstrual), "周期末未标记经前期")
	_expect(
		float(premenstrual.endometrial_receptivity_index) < float(receptive_peak.endometrial_receptivity_index),
		"临近经期时内膜容受性没有下降"
	)

	var ling_effect := CYCLE.daily_stat_effect("ling", menstrual)
	var nai_menstrual := CYCLE.snapshot_from_absolute_day("nai", 0, now)
	var nai_effect := CYCLE.daily_stat_effect("nai", nai_menstrual)
	_expect(
		absf(float(ling_effect.stamina)) > absf(float(nai_effect.stamina)),
		"两人的经期症状强度没有区分"
	)

	var migrated: Dictionary = Global.call("_migrate_v4_to_v5", {
		"version": 4,
		"balance_version": 2,
		"save_id": "cycle-migration",
		"stats_by_role": {
			"ling": {"health": 70.0, "urine_sexual": 88.0},
			"nai": {"health": 72.0, "urine_sexual": 66.0},
		},
		"life_runtime": {},
	})
	_expect(int(migrated.version) == 5, "v4→v5 未升级版本")
	_expect(int(migrated.balance_version) == 5, "v4→v5 未升级平衡版本")
	_expect((migrated.stats_by_role.ling as Dictionary).has("implantation"), "迁移未补齐服药后着床倾向")
	_expect(not (migrated.stats_by_role.ling as Dictionary).has("urine_sexual"), "迁移未删除旧亲密尿液字段")
	_expect(
		(migrated.life_runtime.roles.ling as Dictionary).has("menstrual_cycle"),
		"迁移未补齐小玲周期状态"
	)
	_expect(
		(migrated.life_runtime.roles.nai as Dictionary).has("menstrual_cycle"),
		"迁移未补齐小奈周期状态"
	)
	if _failures.is_empty():
		print("MENSTRUAL_CYCLE_CHECK passed=", _checks)
		get_tree().quit(0)
		return
	for failure in _failures:
		printerr("MENSTRUAL_CYCLE_CHECK failure=", failure)
	get_tree().quit(1)

func _expect_approx(actual: float, expected: float, message: String) -> void:
	_expect(is_equal_approx(actual, expected), "%s：期望 %.1f，实际 %.1f" % [message, expected, actual])

func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
