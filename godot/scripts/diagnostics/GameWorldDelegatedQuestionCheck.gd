extends Node

const GAME_WORLD_SCENE := preload("res://scenes/GameWorld/GameWorld.tscn")
const DIAGNOSTIC_SAVE_ID := "diagnostic-delegated-question"
const TIMEOUT_SECONDS := 120.0

const PROMPTS := [
	"你去问问小奈想吃什么？",
	"让她去问小奈，早餐想吃什么。",
	"让小玲问问小奈，午饭想吃什么。",
	"小玲去跟小奈商量一下夜宵吃什么。",
	"你帮我问问小奈明天想吃什么。",
]

const SELF_QUERY_FAILURES := [
	"小奈去问小奈",
	"小奈问小奈",
	"我去问我自己",
	"我问我自己",
	"问我自己",
]

var _last_error := ""

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	if not CompanionCore.has_credentials():
		printerr("GAMEWORLD_DELEGATED_QUESTION_CHECK core_key_missing")
		get_tree().quit(2)
		return
	_prepare_isolated_state()
	CompanionCore.set_save_id(DIAGNOSTIC_SAVE_ID)
	CompanionCore.request_failed.connect(_on_request_failed)
	CompanionCore.connect_to_core()
	if not await _wait_until_connected():
		await _finish(null, 3, "connect_failed:" + _last_error)
		return
	var reset_before: Dictionary = await CompanionCore.reset_session(DIAGNOSTIC_SAVE_ID)
	if not bool(reset_before.get("ok", false)):
		await _finish(null, 4, "reset_failed")
		return

	var world := GAME_WORLD_SCENE.instantiate()
	world.set("_suppress_exit_persistence", true)
	get_tree().root.add_child(world)
	await get_tree().process_frame
	await get_tree().process_frame
	var chat_input := world.get("_chat_input") as LineEdit
	for round_index in PROMPTS.size():
		var expected_selected_role := "nai" if round_index == 0 else "ling"
		world.call("_switch_role", expected_selected_role, false, false)
		var prompt := str(PROMPTS[round_index])
		var conversational_role := str(world.call("_latest_ai_speaker_role"))
		var resolved_before: Dictionary = world.call(
			"_resolve_recipients", prompt, expected_selected_role, conversational_role
		)
		chat_input.text = prompt
		world.call("_send_message")
		var user_entry := _find_latest_user_entry(prompt)
		if user_entry.is_empty():
			await _finish(world, 10 + round_index, "round_%d_user_entry_missing" % (round_index + 1))
			return
		var route_variant = user_entry.get("conversation_route", {})
		var route: Dictionary = route_variant if route_variant is Dictionary else {}
		if (
			str(route.get("origin_role", "")) != "ling"
			or str(route.get("target_role", "")) != "nai"
		):
			await _finish(
				world,
				20 + round_index,
				"round_%d_route_invalid:%s speaker=%s resolved=%s" % [
					round_index + 1, route, conversational_role, resolved_before
				]
			)
			return
		var message_id := str(user_entry.get("id", ""))
		var replies := await _wait_for_replies(message_id, 2)
		if replies.size() != 2:
			await _finish(world, 30 + round_index, "round_%d_reply_failed:%s" % [round_index + 1, _last_error])
			return
		var first: Dictionary = replies[0]
		var second: Dictionary = replies[1]
		if str(first.get("role", "")) != "ling" or str(second.get("role", "")) != "nai":
			await _finish(world, 40 + round_index, "round_%d_order_invalid" % (round_index + 1))
			return
		if str(first.get("target_role", "")) != "nai" or str(second.get("target_role", "")) != "ling":
			await _finish(world, 50 + round_index, "round_%d_direction_invalid" % (round_index + 1))
			return
		var combined := "%s\n%s" % [str(first.get("text", "")), str(second.get("text", ""))]
		for forbidden in SELF_QUERY_FAILURES:
			if str(forbidden) in combined:
				await _finish(world, 60 + round_index, "round_%d_self_query:%s" % [round_index + 1, forbidden])
				return
		var first_text := str(first.get("text", ""))
		if "小奈" not in first_text and "雪奈" not in first_text:
			await _finish(world, 70 + round_index, "round_%d_origin_did_not_address_target:%s" % [
				round_index + 1, first_text.replace("\n", " ")
			])
			return
		if not await _wait_for_idle(world):
			await _finish(world, 80 + round_index, "round_%d_ui_did_not_settle" % (round_index + 1))
			return
		if (
			str(world.get("_current_role")) != expected_selected_role
			or Global.current_character != expected_selected_role
		):
			await _finish(world, 90 + round_index, "round_%d_selection_changed" % (round_index + 1))
			return
		print(
			"DELEGATED_QUESTION_ROUND ", round_index + 1,
			" ling=", str(first.get("text", "")).replace("\n", " "),
			" nai=", str(second.get("text", "")).replace("\n", " ")
		)
	print("GAMEWORLD_DELEGATED_QUESTION_CHECK passed rounds=", PROMPTS.size())
	await _finish(world, 0, "")

func _prepare_isolated_state() -> void:
	Global.save_id = DIAGNOSTIC_SAVE_ID
	Global.current_character = "ling"
	Global.stats_by_role = Global.call("_normalize_stats_by_role", {})
	Global.conversation_history = [{
		"id": "delegation-seed",
		"sender": "ai",
		"role": "ling",
		"text": "主人，今天想吃什么？",
		"status": "sent",
		"event_type": "chat",
		"created_at": int(Time.get_unix_time_from_system()),
	}]
	Global.applied_local_effect_ids = []
	Global.full_stat_milestones = {}
	Global.life_runtime = Global.call("_normalize_life_runtime", {})
	Global.state_loaded = true

func _find_latest_user_entry(prompt: String) -> Dictionary:
	for index in range(Global.conversation_history.size() - 1, -1, -1):
		var entry: Dictionary = Global.conversation_history[index]
		if str(entry.get("sender", "")) == "user" and str(entry.get("text", "")) == prompt:
			return entry
	return {}

func _wait_until_connected() -> bool:
	var started_at := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_at < int(TIMEOUT_SECONDS * 1000.0):
		if CompanionCore.is_active():
			return true
		await get_tree().create_timer(0.05).timeout
	return false

func _wait_for_replies(message_id: String, expected_count: int) -> Array[Dictionary]:
	var started_at := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_at < int(TIMEOUT_SECONDS * 1000.0):
		var replies: Array[Dictionary] = []
		for entry in Global.conversation_history:
			if str(entry.get("sender", "")) == "ai" and str(entry.get("in_reply_to", "")) == message_id:
				replies.append(entry)
		if replies.size() >= expected_count:
			return replies
		if not _last_error.is_empty():
			return []
		await get_tree().create_timer(0.05).timeout
	_last_error = "等待委托询问回复超时"
	return []

func _wait_for_idle(world: Node) -> bool:
	var started_at := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_at < int(TIMEOUT_SECONDS * 1000.0):
		if not bool(world.get("_network_waiting")) and not bool(world.get("_typewriter_active")):
			return true
		await get_tree().process_frame
	return false

func _finish(world: Node, exit_code: int, error: String) -> void:
	if not error.is_empty():
		printerr("GAMEWORLD_DELEGATED_QUESTION_CHECK failure=", error)
	if is_instance_valid(world):
		world.set("_typewriter_skip_requested", true)
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
