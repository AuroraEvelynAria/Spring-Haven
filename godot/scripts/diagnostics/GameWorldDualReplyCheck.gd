extends Node

const GAME_WORLD_SCENE := preload("res://scenes/GameWorld/GameWorld.tscn")
const DIAGNOSTIC_SAVE_ID := "diagnostic-gameworld-dual"
const TIMEOUT_SECONDS := 120.0

var _last_error := ""

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	if not CompanionCore.has_credentials():
		printerr("GAMEWORLD_DUAL_CHECK core_key_missing")
		get_tree().quit(2)
		return
	Global.save_id = DIAGNOSTIC_SAVE_ID
	Global.current_character = "ling"
	Global.stats_by_role = Global.call("_normalize_stats_by_role", {})
	Global.conversation_history = [{
		"id": "diagnostic-seed",
		"sender": "ai",
		"role": "ling",
		"text": "双人链路校验上下文已建立。",
		"status": "sent",
		"event_type": "chat",
		"created_at": int(Time.get_unix_time_from_system()),
	}]
	Global.applied_local_effect_ids = []
	Global.full_stat_milestones = {}
	Global.life_runtime = Global.call("_normalize_life_runtime", {})
	Global.state_loaded = true
	CompanionCore.set_save_id(DIAGNOSTIC_SAVE_ID)
	CompanionCore.request_failed.connect(_on_request_failed)
	CompanionCore.connect_to_core()
	if not await _wait_until_connected():
		printerr("GAMEWORLD_DUAL_CHECK connect_failed error=", _last_error)
		get_tree().quit(3)
		return
	var reset_before: Dictionary = await CompanionCore.reset_session(DIAGNOSTIC_SAVE_ID)
	if not bool(reset_before.get("ok", false)):
		printerr("GAMEWORLD_DUAL_CHECK reset_failed")
		get_tree().quit(4)
		return

	var world := GAME_WORLD_SCENE.instantiate()
	get_tree().root.add_child(world)
	await get_tree().process_frame
	await get_tree().process_frame
	world.call("_switch_role", "ling", false, false)
	var chat_input := world.get("_chat_input") as LineEdit
	var prompt := "你们都回答这次链路校验。小玲先只说暗号『樱灯』；小奈随后先复述她刚看到的小玲暗号，再说『月铃』。"
	chat_input.text = prompt
	world.call("_send_message")
	var user_message_id := _find_user_message_id(prompt)
	if user_message_id.is_empty():
		await _finish(world, 5, "user_entry_missing")
		return
	# 网络等待期间保留原色和交互入口；处理函数本身会阻止重复提交。
	var send_button := world.get("_send_button") as Button
	var ling_button := world.get("_ling_button") as Button
	var nai_button := world.get("_nai_button") as Button
	if send_button.disabled or ling_button.disabled or nai_button.disabled or not chat_input.editable:
		await _finish(world, 6, "waiting_controls_disabled")
		return

	var replies := await _wait_for_two_replies(user_message_id)
	if replies.size() != 2:
		await _finish(world, 7, "reply_failed:" + _last_error)
		return
	var first: Dictionary = replies[0]
	var second: Dictionary = replies[1]
	if str(first.get("role", "")) != "ling" or str(second.get("role", "")) != "nai":
		await _finish(world, 8, "reply_order_invalid")
		return
	if "樱灯" not in str(first.get("text", "")):
		await _finish(world, 9, "first_code_missing")
		return
	var second_text := str(second.get("text", ""))
	if "樱灯" not in second_text or "月铃" not in second_text:
		await _finish(world, 10, "shared_turn_context_missing")
		return
	if str(world.get("_current_role")) != "ling" or Global.current_character != "ling":
		await _finish(world, 11, "selected_role_changed")
		return
	print("GAMEWORLD_DUAL_CHECK passed order=ling,nai shared_turn_context=true selection_stable=true")
	await _finish(world, 0, "")

func _wait_until_connected() -> bool:
	var started_at := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_at < int(TIMEOUT_SECONDS * 1000.0):
		if CompanionCore.is_active():
			return true
		await get_tree().create_timer(0.05).timeout
	return false

func _wait_for_two_replies(user_message_id: String) -> Array[Dictionary]:
	var started_at := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_at < int(TIMEOUT_SECONDS * 1000.0):
		var replies: Array[Dictionary] = []
		for entry in Global.conversation_history:
			if str(entry.get("sender", "")) == "ai" and str(entry.get("in_reply_to", "")) == user_message_id:
				replies.append(entry)
		if replies.size() >= 2:
			return replies
		if not _last_error.is_empty():
			return []
		await get_tree().create_timer(0.05).timeout
	_last_error = "等待双人回复超时"
	return []

func _find_user_message_id(prompt: String) -> String:
	for index in range(Global.conversation_history.size() - 1, -1, -1):
		var entry: Dictionary = Global.conversation_history[index]
		if str(entry.get("sender", "")) == "user" and str(entry.get("text", "")) == prompt:
			return str(entry.get("id", ""))
	return ""

func _finish(world: Node, exit_code: int, error: String) -> void:
	if not error.is_empty():
		printerr("GAMEWORLD_DUAL_CHECK failure=", error)
	if is_instance_valid(world):
		world.set("_typewriter_skip_requested", true)
		var deadline := Time.get_ticks_msec() + 1200
		while bool(world.get("_typewriter_active")) and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
		for tween in get_tree().get_processed_tweens():
			tween.kill()
		await get_tree().process_frame
		world.free()
		for _frame in 3:
			await get_tree().process_frame
	await CompanionCore.reset_session(DIAGNOSTIC_SAVE_ID)
	CompanionCore.disconnect_from_core()
	await get_tree().create_timer(0.15).timeout
	get_tree().quit(exit_code)

func _on_request_failed(_request_id: String, message: String, _retryable: bool) -> void:
	_last_error = message
