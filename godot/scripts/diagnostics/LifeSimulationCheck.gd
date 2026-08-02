extends Node

const LIFE_PERSONALITY := preload("res://scripts/domain/LifePersonalityProfiles.gd")

var _checks := 0
var _failures: Array[String] = []
var _autonomous_events: Array[Dictionary] = []

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var now := int(Time.get_unix_time_from_system())
	Global.save_id = "diagnostic-life-simulation"
	Global.current_character = "ling"
	Global.stats_by_role = Global.call("_normalize_stats_by_role", {})
	Global.conversation_history = []
	Global.applied_local_effect_ids = []
	Global.full_stat_milestones = {}
	Global.life_runtime = Global.call("_normalize_life_runtime", {
		"last_update_unix": now - 7200,
		"last_user_activity_unix": now,
	})
	Global.state_loaded = true
	var default_ambient_result := Settings.set_ambient_dialogue_settings(
		Settings.AMBIENT_DIALOGUE_DEFAULTS
	)
	_expect(bool(default_ambient_result.get("ok", false)), "后台互聊默认配置无法保存")
	if not LifeSim.autonomous_action.is_connected(_on_autonomous_action):
		LifeSim.autonomous_action.connect(_on_autonomous_action)
	LifeSim.call("_update_menstrual_cycles", now)
	_expect_approx(float(Global.get_role_stats("ling").fertility), 2.0, "小玲经期内膜容受性同步错误")
	_expect_approx(float(Global.get_role_stats("nai").fertility), 52.0, "小奈黄体期内膜容受性同步错误")
	_expect_approx(float(Global.get_role_stats("ling").implantation), 0.1, "小玲服药后着床倾向同步错误")
	_expect_approx(float(Global.get_role_stats("nai").implantation), 2.6, "小奈服药后着床倾向同步错误")
	var ling_cycle: Dictionary = LifeSim.build_menstrual_state("ling")
	var nai_cycle: Dictionary = LifeSim.build_menstrual_state("nai")
	_expect(str(ling_cycle.phase) == "menstrual", "小玲周期相位错误")
	_expect(str(nai_cycle.phase) == "luteal", "小奈周期相位错误")
	_expect(int(ling_cycle.cycle_length_days) != int(nai_cycle.cycle_length_days), "两人的周期被错误同步")

	var ling: Dictionary = Global.get_role_stats("ling")
	ling["hunger"] = 10.0
	ling["thirst"] = 20.0
	ling["stamina"] = 50.0
	Global.stats_by_role["ling"] = ling
	LifeSim.call("_advance_needs", 7200.0, now)
	ling = Global.get_role_stats("ling")
	_expect_approx(float(ling.hunger), 16.0, "两小时饥饿推进错误")
	_expect_approx(float(ling.thirst), 28.4, "两小时口渴推进错误")
	_expect_approx(float(ling.stamina), 47.6, "两小时体力推进错误")

	ling["thirst"] = 80.0
	ling["urine"] = 10.0
	Global.stats_by_role["ling"] = ling
	var runtime := Global.life_runtime.duplicate(true)
	var roles_runtime: Dictionary = runtime.get("roles", {})
	var ling_runtime: Dictionary = roles_runtime.get("ling", {}).duplicate(true)
	ling_runtime["last_self_care_unix"] = 0
	roles_runtime["ling"] = ling_runtime
	runtime["roles"] = roles_runtime
	Global.life_runtime = runtime
	LifeSim.call("_check_self_care", now)
	ling = Global.get_role_stats("ling")
	_expect_approx(float(ling.thirst), 34.0, "自主喝水没有降低口渴")
	_expect_approx(float(ling.urine), 18.0, "自主喝水没有同步容器状态")
	_expect(_autonomous_events.size() == 1, "自主喝水事件数量错误")
	if _autonomous_events.size() == 1:
		_expect(str(_autonomous_events[0].get("action", "")) == "drink", "自主行为不是喝水")

	var body_state: Dictionary = LifeSim.build_role_state("ling")
	_expect(str(body_state.get("protocol", "")) == "spring_heaven.body_state.v2", "身体状态协议错误")
	_expect(str(body_state.get("role_id", "")) == "ling", "身体状态角色绑定错误")
	_expect(body_state.get("sensations", {}) is Dictionary, "身体感觉未生成")
	_expect(body_state.get("menstrual_cycle", {}) is Dictionary, "身体状态缺少生理周期")
	_expect_approx(float((body_state.stats as Dictionary).implantation), 0.1, "身体状态缺少服药后着床倾向")
	_expect(bool((body_state.menstrual_cycle as Dictionary).contraception_active), "身体状态缺少避孕状态")
	_expect(not bool((body_state.menstrual_cycle as Dictionary).contraceptive_side_effects), "身体状态错误报告避孕药副作用")
	_expect(not (body_state.stats as Dictionary).has("urine_sexual"), "身体状态仍暴露旧亲密尿液字段")

	var scheduled_runtime := Global.life_runtime.duplicate(true)
	var scheduled_roles: Dictionary = scheduled_runtime.get("roles", {})
	for role in ["ling", "nai"]:
		var role_runtime: Dictionary = scheduled_roles.get(role, {}).duplicate(true)
		role_runtime["next_proactive_unix"] = 0
		scheduled_roles[role] = role_runtime
	scheduled_runtime["roles"] = scheduled_roles
	Global.life_runtime = scheduled_runtime
	LifeSim.call("_schedule_missing_proactive_times", now)
	for role in ["ling", "nai"]:
		var next_time := int((Global.life_runtime.roles[role] as Dictionary).next_proactive_unix)
		_expect(next_time >= now + 3600 and next_time <= now + 10800, "%s 主动消息时间不在 1-3 小时" % role)

	var ambient_runtime := Global.life_runtime.duplicate(true)
	var ambient_schedule: Dictionary = ambient_runtime.get("ambient_dialogue", {}).duplicate(true)
	ambient_schedule["next_session_unix"] = 0
	ambient_runtime["ambient_dialogue"] = ambient_schedule
	Global.life_runtime = ambient_runtime
	LifeSim.call("_schedule_missing_ambient_dialogue", now)
	var next_ambient := int(Global.life_runtime.ambient_dialogue.next_session_unix)
	_expect(
		next_ambient >= now + 1800 and next_ambient <= now + 5400,
		"双角色互聊时间不在 30-90 分钟"
	)
	_expect(
		str(Global.life_runtime.ambient_dialogue.last_starter_role).is_empty(),
		"新存档错误生成了上次互聊发起人"
	)
	_expect(
		int(Global.life_runtime.ambient_dialogue.completed_sessions) == 0,
		"新存档错误生成了已完成互聊次数"
	)
	var notification_only_result := Settings.set_ambient_dialogue_settings({
		"notifications_enabled": false,
	})
	_expect(bool(notification_only_result.get("ok", false)), "互聊通知开关无法保存")
	_expect(
		int(Global.life_runtime.ambient_dialogue.next_session_unix) == next_ambient,
		"只切换通知开关却重置了互聊时间"
	)

	var invalid_ambient_result := Settings.set_ambient_dialogue_settings({
		"cooldown_min_minutes": 100,
		"cooldown_max_minutes": 20,
	})
	_expect(not bool(invalid_ambient_result.get("ok", true)), "非法互聊冷却范围被错误接受")
	var custom_ambient_result := Settings.set_ambient_dialogue_settings({
		"enabled": true,
		"idle_minutes": 7,
		"cooldown_min_minutes": 12,
		"cooldown_max_minutes": 18,
		"turns_min": 3,
		"turns_max": 5,
		"notifications_enabled": false,
		"memory_enabled": false,
	})
	_expect(bool(custom_ambient_result.get("ok", false)), "自定义后台互聊配置无法保存")
	var custom_runtime := Global.life_runtime.duplicate(true)
	var custom_schedule: Dictionary = custom_runtime.get("ambient_dialogue", {}).duplicate(true)
	custom_schedule["next_session_unix"] = 0
	custom_runtime["ambient_dialogue"] = custom_schedule
	Global.life_runtime = custom_runtime
	LifeSim.call("_schedule_missing_ambient_dialogue", now)
	var custom_next_ambient := int(Global.life_runtime.ambient_dialogue.next_session_unix)
	_expect(
		custom_next_ambient >= now + 12 * 60 and custom_next_ambient <= now + 18 * 60,
		"自定义互聊冷却范围没有应用到调度"
	)
	var persisted_settings := ConfigFile.new()
	_expect(persisted_settings.load("user://settings.cfg") == OK, "后台互聊配置文件无法重新读取")
	_expect(
		int(persisted_settings.get_value("life_simulation", "idle_minutes", 0)) == 7,
		"后台互聊空闲时间没有持久化"
	)
	_expect(
		bool(persisted_settings.get_value("life_simulation", "memory_enabled", true)) == false,
		"Heartloom 互聊开关没有持久化"
	)
	var disabled_ambient_result := Settings.set_ambient_dialogue_settings({"enabled": false})
	_expect(bool(disabled_ambient_result.get("ok", false)), "后台互聊开关无法关闭")
	_expect(
		int(Global.life_runtime.ambient_dialogue.next_session_unix) == 0,
		"关闭后台互聊后仍保留了下一次调度"
	)
	Settings.set_ambient_dialogue_settings(Settings.AMBIENT_DIALOGUE_DEFAULTS)

	var profile_rng := RandomNumberGenerator.new()
	profile_rng.seed = 20260618
	var calm_stats := {"stress": 20.0, "mood": 70.0, "stamina": 70.0}
	var stressed_stats := {"stress": 80.0, "mood": 45.0, "stamina": 60.0}
	var ling_coping := LIFE_PERSONALITY.choose_intent(
		"ling", stressed_stats, calm_stats, {}, 11, "2026-07-22", {}, now, profile_rng
	)
	var nai_coping := LIFE_PERSONALITY.choose_intent(
		"nai", stressed_stats, calm_stats, {}, 11, "2026-07-22", {}, now, profile_rng
	)
	_expect(str(ling_coping.get("action", "")) == "quiet_curl", "小玲压力恢复行为没有人格差异")
	_expect(str(nai_coping.get("action", "")) == "dance_release", "小奈压力恢复行为没有人格差异")
	var care_intent := LIFE_PERSONALITY.choose_intent(
		"ling", calm_stats, {"stress": 78.0, "mood": 24.0}, {},
		11, "2026-07-22", {}, now, profile_rng
	)
	_expect(str(care_intent.get("action", "")) == "comfort_partner", "小玲没有优先照顾低落的小奈")
	_expect(str(care_intent.get("target_role", "")) == "nai", "小玲照顾意图目标角色错误")
	_expect(
		"不要误称为主人" in LIFE_PERSONALITY.dialogue_guidance("nai", "ling"),
		"角色互聊人格上下文缺少收件人边界"
	)
	_expect(
		"排练、编舞和舞蹈训练是小奈自己的经历" in LIFE_PERSONALITY.dialogue_guidance("nai", "ling"),
		"小奈人格上下文缺少专业经历边界"
	)
	_expect(
		"小玲是生命科学专业学生" in LIFE_PERSONALITY.dialogue_guidance("ling", "nai"),
		"小玲人格上下文缺少专业经历边界"
	)
	_expect(
		"真实保留猫耳、猫尾及猫娘特有身体构造" in LIFE_PERSONALITY.dialogue_guidance("ling", "nai"),
		"小玲人格上下文错误弱化兽娘身体构造"
	)
	_expect(
		"该药在本世界观中没有副作用" in LIFE_PERSONALITY.dialogue_guidance("nai", "ling"),
		"小奈人格上下文缺少兽娘避孕药设定"
	)

	var ling_for_intent := Global.get_role_stats("ling").duplicate(true)
	ling_for_intent["stress"] = 82.0
	ling_for_intent["mood"] = 48.0
	Global.stats_by_role["ling"] = ling_for_intent
	var nai_for_intent := Global.get_role_stats("nai").duplicate(true)
	nai_for_intent["stress"] = 18.0
	nai_for_intent["mood"] = 70.0
	Global.stats_by_role["nai"] = nai_for_intent
	var intent_runtime := Global.life_runtime.duplicate(true)
	var intent_roles: Dictionary = intent_runtime.get("roles", {})
	for role in ["ling", "nai"]:
		var role_runtime: Dictionary = intent_roles.get(role, {}).duplicate(true)
		role_runtime["last_personality_action_unix"] = 0
		role_runtime["active_intent"] = ""
		role_runtime["current_intent"] = {}
		intent_roles[role] = role_runtime
	intent_runtime["roles"] = intent_roles
	Global.life_runtime = Global.call("_normalize_life_runtime", intent_runtime)
	LifeSim.call("_check_personality_intents", now)
	var planned_ling: Dictionary = Global.life_runtime.roles.ling.current_intent
	_expect(str(planned_ling.get("status", "")) == "planned", "小玲生活意图没有先持久化为 planned")
	_expect(str(planned_ling.get("action", "")) == "quiet_curl", "小玲持久意图动作错误")
	await get_tree().process_frame
	await get_tree().process_frame
	var completed_ling: Dictionary = Global.life_runtime.roles.ling.current_intent
	var completed_nai: Dictionary = Global.life_runtime.roles.nai.current_intent
	_expect(str(completed_ling.get("status", "")) == "completed", "小玲生活意图没有完成")
	_expect(str(completed_nai.get("action", "")) == "comfort_partner", "小奈没有响应小玲的高压力状态")
	_expect(str(completed_nai.get("status", "")) == "completed", "小奈陪伴意图没有完成")
	_expect(float(Global.get_role_stats("ling").stress) < 82.0, "人格生活行为没有实际降低小玲压力")
	var personality_event_count := 0
	for event in _autonomous_events:
		if str(event.get("kind", "")) == "personality_life_intent":
			personality_event_count += 1
	_expect(personality_event_count == 2, "人格生活意图事件数量错误")

	var recovery_runtime := Global.life_runtime.duplicate(true)
	var recovery_roles: Dictionary = recovery_runtime.get("roles", {})
	var recovery_ling: Dictionary = recovery_roles.get("ling", {}).duplicate(true)
	recovery_ling["current_intent"] = {
		"id": "intent-ling-sunbathe-recovery",
		"role_id": "ling",
		"action": "sunbathe",
		"status": "executing",
		"reason": "恢复测试",
		"target_role": "",
		"routine_slot": "",
		"description": "恢复一次晒太阳意图",
		"created_at_unix": now - 10,
		"updated_at_unix": now - 5,
		"expires_at_unix": now + 600,
	}
	recovery_ling["active_intent"] = "sunbathe"
	recovery_roles["ling"] = recovery_ling
	recovery_runtime["roles"] = recovery_roles
	Global.life_runtime = Global.call("_normalize_life_runtime", recovery_runtime)
	var mood_before_recovery := float(Global.get_role_stats("ling").mood)
	LifeSim.call("_recover_pending_personality_intents", now)
	await get_tree().process_frame
	await get_tree().process_frame
	_expect(
		str(Global.life_runtime.roles.ling.current_intent.status) == "completed",
		"重启后 executing 生活意图没有恢复完成"
	)
	var mood_after_recovery := float(Global.get_role_stats("ling").mood)
	_expect(mood_after_recovery >= mood_before_recovery, "恢复生活意图没有应用效果")
	LifeSim.call("_recover_pending_personality_intents", now)
	await get_tree().process_frame
	_expect(
		is_equal_approx(float(Global.get_role_stats("ling").mood), mood_after_recovery),
		"已完成生活意图在恢复时被重复执行"
	)

	var first_image := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	first_image.fill(Color("7ea46f"))
	var first_photo: Dictionary = Photos.save_image(first_image, "ling", "life_check")
	var second_photo: Dictionary = Photos.save_image(first_image, "ling", "life_check")
	_expect(bool(first_photo.get("ok", false)) and bool(second_photo.get("ok", false)), "本地相册连续写入失败")
	_expect(str(first_photo.get("path", "")) != str(second_photo.get("path", "")), "相册追加覆盖了旧照片")
	_expect(FileAccess.file_exists(str(first_photo.get("path", ""))), "第一张本地照片不存在")
	var photo_name := str(first_photo.get("absolute_path", "")).get_file()
	var timestamp_pattern := RegEx.new()
	timestamp_pattern.compile("^\\d{4}-\\d{2}-\\d{2}_\\d{2}-\\d{2}-\\d{2}_life_check_\\d+\\.png$")
	_expect(timestamp_pattern.search(photo_name) != null, "照片文件名没有完整时间戳")

	Vision.configure("http://127.0.0.1:1234/v1", "gemma-e4b-test")
	_expect(Vision.is_configured(), "LM Studio OpenAI 兼容接口无法配置")
	if OS.get_environment("SPRING_HEAVEN_TEST_TOAST") == "1":
		_expect(Notifier.show_notification("春日庭院 · 测试", "后台主动消息通知链路已通过。"), "Windows 通知进程未启动")

	if _failures.is_empty():
		print("LIFE_SIMULATION_CHECK passed=", _checks)
		get_tree().quit(0)
		return
	for failure in _failures:
		printerr("LIFE_SIMULATION_CHECK failure=", failure)
	get_tree().quit(1)

func _on_autonomous_action(event: Dictionary) -> void:
	_autonomous_events.append(event.duplicate(true))

func _expect_approx(actual: float, expected: float, message: String) -> void:
	_expect(is_equal_approx(actual, expected), "%s：期望 %.2f，实际 %.2f" % [message, expected, actual])

func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
