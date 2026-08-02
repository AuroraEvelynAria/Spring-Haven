extends Node

const DIAGNOSTIC_SAVE_ID := "diagnostic-ambient-dialogue"
const TIMEOUT_SECONDS := 180.0

var _finished := false
var _session_id := ""
var _transcript: Array = []
var _last_error := ""
var _memory_status: Dictionary = {}

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	if not CompanionCore.has_credentials():
		printerr("AMBIENT_DIALOGUE_CHECK core_key_missing")
		get_tree().quit(2)
		return
	_prepare_isolated_state()
	LifeSim.ambient_dialogue_finished.connect(_on_ambient_dialogue_finished)
	LifeSim.status_changed.connect(_on_life_status_changed)
	CompanionCore.memory_status_changed.connect(_on_memory_status_changed)
	var settings_result := Settings.set_ambient_dialogue_settings({
		"enabled": true,
		"memory_enabled": false,
		"notifications_enabled": false,
	})
	if not bool(settings_result.get("ok", false)):
		printerr("AMBIENT_DIALOGUE_CHECK settings_failed")
		get_tree().quit(8)
		return
	CompanionCore.set_save_id(DIAGNOSTIC_SAVE_ID)
	CompanionCore.connect_to_core()
	if not await _wait_until_connected():
		printerr("AMBIENT_DIALOGUE_CHECK connect_failed error=", _last_error)
		get_tree().quit(3)
		return
	var reset_before: Dictionary = await CompanionCore.reset_session(DIAGNOSTIC_SAVE_ID)
	if not bool(reset_before.get("ok", false)):
		printerr("AMBIENT_DIALOGUE_CHECK reset_failed error=", reset_before.get("message", "unknown"))
		await _finish(4)
		return
	if not LifeSim.force_ambient_dialogue(2, "ling"):
		printerr("AMBIENT_DIALOGUE_CHECK start_failed")
		await _finish(5)
		return
	if not await _wait_until_finished():
		printerr("AMBIENT_DIALOGUE_CHECK timeout error=", _last_error)
		await _finish(6)
		return
	var failures: Array[String] = []
	if _session_id.is_empty():
		failures.append("session_id_missing")
	if _transcript.size() != 2:
		failures.append("turn_count_invalid")
	else:
		var first: Dictionary = _transcript[0]
		var second: Dictionary = _transcript[1]
		if str(first.get("role", "")) != "ling" or str(first.get("target_role", "")) != "nai":
			failures.append("first_route_invalid")
		if str(second.get("role", "")) != "nai" or str(second.get("target_role", "")) != "ling":
			failures.append("second_route_invalid")
		if str(second.get("in_reply_to", "")) != str(first.get("id", "")):
			failures.append("reply_chain_invalid")
		for entry in [first, second]:
			if str(entry.get("kind", "")) != "ambient_dialogue":
				failures.append("kind_invalid")
			if str(entry.get("text", "")).strip_edges().is_empty():
				failures.append("empty_reply")
	if Global.current_character != "ling":
		failures.append("selected_role_changed")
	var ambient_runtime: Dictionary = Global.life_runtime.get("ambient_dialogue", {})
	if int(ambient_runtime.get("completed_sessions", 0)) != 1:
		failures.append("completed_session_not_persisted")
	if int(ambient_runtime.get("next_session_unix", 0)) <= int(Time.get_unix_time_from_system()):
		failures.append("cooldown_not_scheduled")
	if not await _wait_until_memory_skipped():
		failures.append("memory_skip_status_missing")
	elif "不写入 Heartloom" not in str(_memory_status.get("message", "")):
		failures.append("memory_skip_message_invalid")
	if not failures.is_empty():
		printerr("AMBIENT_DIALOGUE_CHECK failure=", ",".join(failures))
		await _finish(7)
		return
	print(
		"AMBIENT_DIALOGUE_CHECK passed turns=2 order=ling,nai ",
		"reply_chain=true selection_stable=true memory_skipped=true session=", _session_id
	)
	await _finish(0)

func _prepare_isolated_state() -> void:
	var now := int(Time.get_unix_time_from_system())
	Global.save_id = DIAGNOSTIC_SAVE_ID
	Global.current_character = "ling"
	Global.stats_by_role = Global.call("_normalize_stats_by_role", {})
	Global.conversation_history = []
	Global.applied_local_effect_ids = []
	Global.full_stat_milestones = {}
	Global.life_runtime = Global.call("_normalize_life_runtime", {
		"last_update_unix": now,
		"last_user_activity_unix": now - 3600,
	})
	Global.state_loaded = true
	CompanionCore.set_save_id(DIAGNOSTIC_SAVE_ID)

func _wait_until_connected() -> bool:
	var started_at := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_at < int(TIMEOUT_SECONDS * 1000.0):
		if CompanionCore.is_active():
			return true
		await get_tree().create_timer(0.05).timeout
	return false

func _wait_until_finished() -> bool:
	var started_at := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_at < int(TIMEOUT_SECONDS * 1000.0):
		if _finished:
			return true
		if not _last_error.is_empty():
			return false
		await get_tree().create_timer(0.05).timeout
	return false

func _wait_until_memory_skipped() -> bool:
	var started_at := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_at < 15000:
		if str(_memory_status.get("state", "")) == "skipped":
			return true
		await get_tree().create_timer(0.05).timeout
	return false

func _finish(exit_code: int) -> void:
	Settings.set_ambient_dialogue_settings(Settings.AMBIENT_DIALOGUE_DEFAULTS)
	var cleanup: Dictionary = await CompanionCore.reset_session(DIAGNOSTIC_SAVE_ID)
	if not bool(cleanup.get("ok", false)):
		printerr("AMBIENT_DIALOGUE_CHECK cleanup_failed error=", cleanup.get("message", "unknown"))
	CompanionCore.disconnect_from_core()
	await get_tree().create_timer(0.15).timeout
	get_tree().quit(exit_code)

func _on_ambient_dialogue_finished(session_id: String, transcript: Array) -> void:
	_session_id = session_id
	_transcript = transcript.duplicate(true)
	_finished = true

func _on_life_status_changed(status: String, message: String) -> void:
	if status == "failed":
		_last_error = message

func _on_memory_status_changed(status: Dictionary) -> void:
	_memory_status = status.duplicate(true)
