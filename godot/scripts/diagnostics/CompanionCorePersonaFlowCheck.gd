extends SceneTree

const CLIENT_SCRIPT := preload("res://scripts/autoload/CompanionCoreClient.gd")
const TIMEOUT_SECONDS := 100.0
const DIAGNOSTIC_SAVE_ID := "diagnostic-persona-flow"

var _client: Node
var _replies: Dictionary = {}
var _last_error := ""
var _session_initialized := false

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_client = CLIENT_SCRIPT.new()
	root.add_child(_client)
	await process_frame
	if not _client.has_credentials():
		printerr("COMPANION_CORE_PERSONA_CHECK core_key_missing")
		_finish_without_cleanup(2)
		return

	_client.reply_received.connect(_on_reply_received)
	_client.request_failed.connect(_on_request_failed)
	_client.connect_to_core()
	if not await _wait_until_connected():
		printerr("COMPANION_CORE_PERSONA_CHECK connect_failed error=", _last_error)
		_finish_without_cleanup(3)
		return

	_session_initialized = true
	var reset_before: Dictionary = await _client.reset_session(DIAGNOSTIC_SAVE_ID)
	if not bool(reset_before.get("ok", false)):
		printerr("COMPANION_CORE_PERSONA_CHECK reset_failed error=", reset_before.get("message", "unknown"))
		await _finish_with_cleanup(4)
		return

	var ling_prompt := "这是一轮连接校验。请只用一句中文回答：你是谁？"
	var ling_request: String = _client.send_chat(
		"ling",
		ling_prompt,
		[],
		DIAGNOSTIC_SAVE_ID
	)
	var ling_reply := await _wait_for_reply(ling_request)
	if ling_reply.is_empty():
		printerr("COMPANION_CORE_PERSONA_CHECK ling_failed error=", _last_error)
		await _finish_with_cleanup(5)
		return

	var nai_prompt := "继续刚才的连接校验。请只用一句中文回答：你是谁，以及刚才回答我的人是谁？"
	var nai_request: String = _client.send_chat(
		"nai",
		nai_prompt,
		[
			{"sender": "user", "role": "user", "speaker": "主人", "text": ling_prompt},
			{"sender": "ai", "role": "ling", "speaker": "小玲", "text": ling_reply}
		],
		DIAGNOSTIC_SAVE_ID
	)
	var nai_reply := await _wait_for_reply(nai_request)
	if nai_reply.is_empty():
		printerr("COMPANION_CORE_PERSONA_CHECK nai_failed error=", _last_error)
		await _finish_with_cleanup(6)
		return

	var ling_ok := "小玲" in ling_reply or "铃音" in ling_reply or "鈴音" in ling_reply
	var nai_ok := "小奈" in nai_reply or "雪奈" in nai_reply
	var shared_context_ok := "小玲" in nai_reply or "铃音" in nai_reply or "鈴音" in nai_reply
	print("COMPANION_CORE_PERSONA_CHECK ling_reply=", ling_reply.replace("\n", " "))
	print("COMPANION_CORE_PERSONA_CHECK nai_reply=", nai_reply.replace("\n", " "))
	print(
		"COMPANION_CORE_PERSONA_CHECK ling=", ling_ok,
		" nai=", nai_ok,
		" shared_context=", shared_context_ok
	)
	await _finish_with_cleanup(0 if ling_ok and nai_ok and shared_context_ok else 7)

func _finish_with_cleanup(exit_code: int) -> void:
	if _session_initialized and _client and _client.has_credentials():
		var cleanup_result: Dictionary = await _client.reset_session(DIAGNOSTIC_SAVE_ID)
		if not bool(cleanup_result.get("ok", false)):
			printerr(
				"COMPANION_CORE_PERSONA_CHECK cleanup_failed error=",
				cleanup_result.get("message", "unknown")
			)
	if _client:
		_client.disconnect_from_core()
	quit(exit_code)

func _finish_without_cleanup(exit_code: int) -> void:
	if _client:
		_client.disconnect_from_core()
	quit(exit_code)

func _wait_until_connected() -> bool:
	var started_at := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_at < int(TIMEOUT_SECONDS * 1000.0):
		if _client.is_active():
			return true
		await create_timer(0.05).timeout
	return false

func _wait_for_reply(request_id: String) -> String:
	_last_error = ""
	var started_at := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_at < int(TIMEOUT_SECONDS * 1000.0):
		if _replies.has(request_id):
			return str(_replies[request_id])
		if not _last_error.is_empty():
			return ""
		await create_timer(0.05).timeout
	_last_error = "等待回复超时"
	return ""

func _on_reply_received(request_id: String, text: String, _attachments: Array) -> void:
	_replies[request_id] = text.strip_edges()

func _on_request_failed(_request_id: String, message: String, _retryable: bool) -> void:
	_last_error = message
