extends Node

const DIAGNOSTIC_SAVE_ID := "diagnostic-body-state-flow"
const TIMEOUT_SECONDS := 120.0

var _replies: Dictionary = {}
var _last_error := ""

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	if not CompanionCore.has_credentials():
		printerr("COMPANION_CORE_BODY_STATE_CHECK core_key_missing")
		get_tree().quit(2)
		return

	_prepare_isolated_state()
	CompanionCore.reply_received.connect(_on_reply_received)
	CompanionCore.request_failed.connect(_on_request_failed)
	CompanionCore.set_save_id(DIAGNOSTIC_SAVE_ID)
	CompanionCore.connect_to_core()
	if not await _wait_until_connected():
		printerr("COMPANION_CORE_BODY_STATE_CHECK connect_failed error=", _last_error)
		get_tree().quit(3)
		return

	var reset_before: Dictionary = await CompanionCore.reset_session(DIAGNOSTIC_SAVE_ID)
	if not bool(reset_before.get("ok", false)):
		printerr(
			"COMPANION_CORE_BODY_STATE_CHECK reset_failed error=",
			reset_before.get("message", "unknown")
		)
		await _finish(4)
		return

	var ling_result := await _ask_current_phase("ling")
	if not bool(ling_result.get("ok", false)):
		printerr("COMPANION_CORE_BODY_STATE_CHECK ling_failed error=", ling_result.get("message", "unknown"))
		await _finish(5)
		return

	var nai_result := await _ask_current_phase("nai")
	if not bool(nai_result.get("ok", false)):
		printerr("COMPANION_CORE_BODY_STATE_CHECK nai_failed error=", nai_result.get("message", "unknown"))
		await _finish(6)
		return

	var ling_sensation_result := await _ask_sensations("ling", {
		"hunger": 90.0,
		"thirst": 90.0,
		"stamina": 20.0,
		"awake": 20.0,
		"urine": 90.0,
		"stress": 90.0,
	})
	if not bool(ling_sensation_result.get("ok", false)):
		printerr(
			"COMPANION_CORE_BODY_STATE_CHECK ling_sensations_failed error=",
			ling_sensation_result.get("message", "unknown")
		)
		await _finish(8)
		return

	var nai_sensation_result := await _ask_sensations("nai", {
		"hunger": 10.0,
		"thirst": 10.0,
		"stamina": 90.0,
		"awake": 90.0,
		"urine": 10.0,
		"stress": 10.0,
	})
	if not bool(nai_sensation_result.get("ok", false)):
		printerr(
			"COMPANION_CORE_BODY_STATE_CHECK nai_sensations_failed error=",
			nai_sensation_result.get("message", "unknown")
		)
		await _finish(9)
		return

	var ling_reply := str(ling_result.get("reply", ""))
	var nai_reply := str(nai_result.get("reply", ""))
	var ling_ok := "经期" in ling_reply and "3" in ling_reply and "黄体" not in ling_reply
	var nai_ok := "黄体" in nai_reply and "17" in nai_reply and "经期" not in nai_reply
	var ling_sensation_reply := str(ling_sensation_result.get("reply", ""))
	var nai_sensation_reply := str(nai_sensation_result.get("reply", ""))
	var ling_sensations_ok := _contains_all(ling_sensation_reply, [
		"很饿", "很渴", "非常疲惫", "很困", "如厕需求急迫", "压力很大",
	])
	var nai_sensations_ok := _contains_all(nai_sensation_reply, [
		"饱足", "不渴", "精力充足", "清醒", "舒适", "放松",
	])
	print("COMPANION_CORE_BODY_STATE_CHECK ling_reply=", ling_reply.replace("\n", " "))
	print("COMPANION_CORE_BODY_STATE_CHECK nai_reply=", nai_reply.replace("\n", " "))
	print(
		"COMPANION_CORE_BODY_STATE_CHECK ling_sensations=",
		ling_sensation_reply.replace("\n", " ")
	)
	print(
		"COMPANION_CORE_BODY_STATE_CHECK nai_sensations=",
		nai_sensation_reply.replace("\n", " ")
	)
	print(
		"COMPANION_CORE_BODY_STATE_CHECK ling_menstrual_day_3=", ling_ok,
		" nai_luteal_day_17=", nai_ok,
		" ling_extreme_sensations=", ling_sensations_ok,
		" nai_calm_sensations=", nai_sensations_ok,
		" role_isolation=", ling_ok and nai_ok and ling_sensations_ok and nai_sensations_ok
	)
	await _finish(0 if ling_ok and nai_ok and ling_sensations_ok and nai_sensations_ok else 7)

func _prepare_isolated_state() -> void:
	Global.save_id = DIAGNOSTIC_SAVE_ID
	Global.current_character = "ling"
	Global.stats_by_role = Global.call("_normalize_stats_by_role", {})
	Global.conversation_history = []
	Global.applied_local_effect_ids = []
	Global.full_stat_milestones = {}
	Global.life_runtime = Global.call("_normalize_life_runtime", {})
	Global.state_loaded = true
	LifeSim.call("_update_menstrual_cycles", int(Time.get_unix_time_from_system()))

func _ask_current_phase(role: String) -> Dictionary:
	_last_error = ""
	var body_state := LifeSim.build_role_state(role)
	var cycle: Dictionary = body_state.get("menstrual_cycle", {})
	var phase := str(cycle.get("phase", ""))
	var cycle_day := int(cycle.get("cycle_day", 0))
	var expected_phase := "menstrual" if role == "ling" else "luteal"
	var expected_day := 3 if role == "ling" else 17
	if phase != expected_phase or cycle_day != expected_day:
		return {
			"ok": false,
			"message": "local_cycle_mismatch:%s:%s:%d" % [role, phase, cycle_day],
		}
	var request_id := CompanionCore.send_chat(
		role,
		"请根据你此刻自己的身体状态，只回答当前生理周期阶段的中文名称和整个周期第几天，不要解释。",
		[],
		DIAGNOSTIC_SAVE_ID,
		"chat",
		{"body_state": body_state}
	)
	var reply := await _wait_for_reply(request_id)
	if reply.is_empty():
		return {"ok": false, "message": _last_error}
	return {"ok": true, "reply": reply}

func _ask_sensations(role: String, values: Dictionary) -> Dictionary:
	_last_error = ""
	var stats := Global.get_role_stats(role).duplicate(true)
	for key in values:
		stats[key] = float(values[key])
	Global.stats_by_role[role] = stats
	var body_state := LifeSim.build_role_state(role)
	var request_id := CompanionCore.send_chat(
		role,
		"请严格依据应用提供的身体状态，按饥饿、口渴、体力、清醒、如厕、压力的顺序，原样写出六项身体感受；只写这六项，不要解释。",
		[],
		DIAGNOSTIC_SAVE_ID,
		"chat",
		{"body_state": body_state}
	)
	var reply := await _wait_for_reply(request_id)
	if reply.is_empty():
		return {"ok": false, "message": _last_error}
	return {"ok": true, "reply": reply}

func _contains_all(text: String, expected: Array) -> bool:
	for item in expected:
		if str(item) not in text:
			return false
	return true

func _wait_until_connected() -> bool:
	var started_at := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_at < int(TIMEOUT_SECONDS * 1000.0):
		if CompanionCore.is_active():
			return true
		await get_tree().create_timer(0.05).timeout
	return false

func _wait_for_reply(request_id: String) -> String:
	var started_at := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_at < int(TIMEOUT_SECONDS * 1000.0):
		if _replies.has(request_id):
			return str(_replies[request_id]).strip_edges()
		if not _last_error.is_empty():
			return ""
		await get_tree().create_timer(0.05).timeout
	_last_error = "等待身体状态回复超时"
	return ""

func _finish(exit_code: int) -> void:
	var cleanup: Dictionary = await CompanionCore.reset_session(DIAGNOSTIC_SAVE_ID)
	if not bool(cleanup.get("ok", false)):
		printerr(
			"COMPANION_CORE_BODY_STATE_CHECK cleanup_failed error=",
			cleanup.get("message", "unknown")
		)
	CompanionCore.disconnect_from_core()
	await get_tree().create_timer(0.15).timeout
	get_tree().quit(exit_code)

func _on_reply_received(request_id: String, text: String, _attachments: Array) -> void:
	_replies[request_id] = text.strip_edges()

func _on_request_failed(_request_id: String, message: String, _retryable: bool) -> void:
	_last_error = message
