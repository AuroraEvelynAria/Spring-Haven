extends Node

const GAME_WORLD_SCENE := preload("res://scenes/GameWorld/GameWorld.tscn")
const DIAGNOSTIC_SAVE_ID := "diagnostic-gameworld-chat"
const TIMEOUT_SECONDS := 100.0

var _last_error := ""

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	if not CompanionCore.has_credentials():
		printerr("GAMEWORLD_CHAT_CHECK core_key_missing")
		get_tree().quit(2)
		return

	var seed_history: Array[Dictionary] = [{
		"id": "diagnostic-seed",
		"sender": "ai",
		"role": "nai",
		"text": "连接校验上下文已建立。",
		"status": "sent",
		"event_type": "chat",
		"created_at": int(Time.get_unix_time_from_system())
	}]
	var empty_effect_ids: Array[String] = []
	Global.save_id = DIAGNOSTIC_SAVE_ID
	Global.current_character = "ling"
	Global.stats_by_role = Global.call("_normalize_stats_by_role", {})
	var ling_stats := Global.get_role_stats("ling").duplicate(true)
	ling_stats["thirst"] = 70.0
	ling_stats["urine"] = 10.0
	Global.stats_by_role["ling"] = ling_stats
	Global.conversation_history = seed_history
	Global.applied_local_effect_ids = empty_effect_ids
	Global.full_stat_milestones = {}
	Global.state_loaded = true
	CompanionCore.set_save_id(DIAGNOSTIC_SAVE_ID)
	CompanionCore.request_failed.connect(_on_request_failed)
	CompanionCore.connect_to_core()
	if not await _wait_until_connected():
		printerr("GAMEWORLD_CHAT_CHECK connect_failed error=", _last_error)
		get_tree().quit(3)
		return

	var reset_before: Dictionary = await CompanionCore.reset_session(DIAGNOSTIC_SAVE_ID)
	if not bool(reset_before.get("ok", false)):
		printerr("GAMEWORLD_CHAT_CHECK reset_failed error=", reset_before.get("message", "unknown"))
		get_tree().quit(4)
		return

	var world := GAME_WORLD_SCENE.instantiate()
	get_tree().root.add_child(world)
	await get_tree().process_frame
	await get_tree().process_frame
	var chat_input := world.get("_chat_input") as LineEdit
	if not is_instance_valid(chat_input):
		printerr("GAMEWORLD_CHAT_CHECK input_missing")
		await _finish(world, 5)
		return

	var prompt := "小玲，我把刚倒好的温水递到你手里了（括号里的内容也应由两个人共同看见）。请说说刚才发生了什么，以及你现在是否仍有些口渴。"
	chat_input.text = prompt
	world.call("_send_message")
	if not chat_input.text.is_empty():
		printerr("GAMEWORLD_CHAT_CHECK send_entry_not_committed")
		await _finish(world, 6)
		return

	var user_entry := _find_user_message(prompt)
	var user_message_id := str(user_entry.get("id", ""))
	if user_message_id.is_empty():
		printerr("GAMEWORLD_CHAT_CHECK user_entry_missing")
		await _finish(world, 7)
		return
	if (
		str(user_entry.get("target_role", "")) != "ling"
		or user_entry.get("audience_roles", []) != ["ling", "nai"]
		or str(user_entry.get("text", "")) != prompt
		or str(user_entry.get("action", "")) != "drink"
		or str(user_entry.get("event_type", "")) != "action"
	):
		printerr("GAMEWORLD_CHAT_CHECK shared_visibility_invalid entry=", user_entry)
		await _finish(world, 9)
		return
	var local_effect_variant = user_entry.get("local_effect", {})
	var local_effect: Dictionary = (
		local_effect_variant if local_effect_variant is Dictionary else {}
	)
	if (
		str(local_effect.get("source", "")) != "natural_semantic"
		or str(local_effect.get("matcher_version", "")) != "conservative-zh-v4"
	):
		printerr("GAMEWORLD_CHAT_CHECK semantic_effect_invalid effect=", local_effect)
		await _finish(world, 13)
		return
	var request_state: Dictionary = world.call("_entry_request_state", user_entry, "ling")
	var visibility_variant = request_state.get("conversation_visibility", {})
	var visibility: Dictionary = visibility_variant if visibility_variant is Dictionary else {}
	if (
		str(visibility.get("protocol", "")) != "spring_heaven.conversation_visibility.v1"
		or visibility.get("audience_roles", []) != ["ling", "nai"]
		or str(visibility.get("responder_role", "")) != "ling"
		or not bool(visibility.get("parenthetical_content_visible", false))
	):
		printerr("GAMEWORLD_CHAT_CHECK visibility_protocol_invalid state=", visibility)
		await _finish(world, 10)
		return
	var body_state_variant = request_state.get("body_state", {})
	var body_state: Dictionary = body_state_variant if body_state_variant is Dictionary else {}
	var sensations_variant = body_state.get("sensations", {})
	var sensations: Dictionary = sensations_variant if sensations_variant is Dictionary else {}
	var updated_stats := Global.get_role_stats("ling")
	if (
		not is_equal_approx(float(updated_stats.get("thirst", -1.0)), 57.4)
		or not is_equal_approx(float(updated_stats.get("urine", -1.0)), 14.5)
		or str(sensations.get("thirst", "")) != "有些口渴"
	):
		printerr(
			"GAMEWORLD_CHAT_CHECK drink_state_invalid stats=",
			updated_stats,
			" sensations=",
			sensations
		)
		await _finish(world, 11)
		return

	var reply := await _wait_for_reply(user_message_id)
	if reply.is_empty():
		printerr("GAMEWORLD_CHAT_CHECK reply_failed error=", _last_error)
		await _finish(world, 8)
		return
	if ("水" not in reply and "喝" not in reply) or "渴" not in reply:
		printerr("GAMEWORLD_CHAT_CHECK state_reply_irrelevant reply=", reply)
		await _finish(world, 12)
		return

	print(
		"GAMEWORLD_CHAT_CHECK role=ling source=natural_semantic action=drink thirst=57.4 urine=14.5 ",
		"body_sensation=有些口渴 reply_relevant=true reply=",
		reply.replace("\n", " ")
	)
	await _finish(world, 0)

func _wait_until_connected() -> bool:
	var started_at := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_at < int(TIMEOUT_SECONDS * 1000.0):
		if CompanionCore.is_active():
			return true
		await get_tree().create_timer(0.05).timeout
	return false

func _wait_for_reply(user_message_id: String) -> String:
	var started_at := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_at < int(TIMEOUT_SECONDS * 1000.0):
		for entry in Global.conversation_history:
			if str(entry.get("sender", "")) != "ai":
				continue
			if str(entry.get("in_reply_to", "")) != user_message_id:
				continue
			return str(entry.get("text", "")).strip_edges()
		if not _last_error.is_empty():
			return ""
		await get_tree().create_timer(0.05).timeout
	_last_error = "等待主对话框回复超时"
	return ""

func _find_user_message(prompt: String) -> Dictionary:
	for index in range(Global.conversation_history.size() - 1, -1, -1):
		var entry: Dictionary = Global.conversation_history[index]
		if str(entry.get("sender", "")) == "user" and str(entry.get("text", "")) == prompt:
			return entry
	return {}

func _finish(world: Node, exit_code: int) -> void:
	if is_instance_valid(world):
		world.set("_typewriter_skip_requested", true)
		var animation_deadline := Time.get_ticks_msec() + 1000
		while bool(world.get("_typewriter_active")) and Time.get_ticks_msec() < animation_deadline:
			await get_tree().process_frame
		for tween in get_tree().get_processed_tweens():
			tween.kill()
		await get_tree().process_frame
		world.free()
		for _frame in 3:
			await get_tree().process_frame
	var cleanup: Dictionary = await CompanionCore.reset_session(DIAGNOSTIC_SAVE_ID)
	if not bool(cleanup.get("ok", false)):
		printerr("GAMEWORLD_CHAT_CHECK cleanup_failed error=", cleanup.get("message", "unknown"))
	CompanionCore.disconnect_from_core()
	await get_tree().create_timer(0.15).timeout
	await get_tree().process_frame
	get_tree().quit(exit_code)

func _on_request_failed(_request_id: String, message: String, _retryable: bool) -> void:
	_last_error = message
