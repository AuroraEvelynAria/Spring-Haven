extends Node

signal connected
signal disconnected
signal reply_received(request_id: String, text: String, attachments: Array)
signal scene_actions_received(request_id: String, actions: Array)
signal reply_streaming(request_id: String, chunk: String)
signal reply_finished(request_id: String)
signal error_received(message: String)
signal request_failed(request_id: String, message: String, retryable: bool)
signal health_changed(active: bool, message: String)
signal memory_status_changed(status: Dictionary)

const DEFAULT_CORE_BASE_URL := "http://127.0.0.1:18340"
const HEALTH_TIMEOUT_SECONDS := 5.0
const CHAT_TIMEOUT_SECONDS := 95.0
const HEALTH_INTERVAL_SECONDS := 8.0
const MEMORY_INTERVAL_SECONDS := 6.0
const MAX_HEALTH_RETRY_SECONDS := 30.0
const DEFAULT_SAVE_ID := "default"
const CHARACTERS := ["ling", "nai"]
const MANAGED_CORE_HEALTH_DELAY_SECONDS := 1.5
const CORE_KEY_FILE := "user://companion_core_key.txt"
const USER_CORE_RUNTIME_DIR := "user://companion-core"

var _core_key := ""
var _base_url := DEFAULT_CORE_BASE_URL
var _save_id := DEFAULT_SAVE_ID
var _active := false
var _should_monitor := false
var _health_request_in_flight := false
var _monitor_generation := 0
var _health_elapsed := 0.0
var _health_retry_seconds := 1.0
var _memory_elapsed := 0.0
var _memory_request_in_flight := false
var _pending_requests: Dictionary = {}
var _provider_status_cache: Dictionary = {}
var _managed_core_pid := -1
var _managed_core_last_start_msec := -1000000
var _managed_core_start_count := 0
var _managed_core_last_error := ""
var _local_core_layout: Dictionary = {}
var _local_runtime_created := false
var _local_runtime_error := ""

func _ready() -> void:
	_load_base_url()
	_prepare_local_core_runtime()
	_load_core_key()
	_sync_save_id_from_global()
	if has_credentials():
		connect_to_core()

func _process(delta: float) -> void:
	if not _should_monitor or not has_credentials():
		return
	_health_elapsed -= delta
	if _health_elapsed <= 0.0 and not _health_request_in_flight:
		_check_health.call_deferred()
	if _active:
		_memory_elapsed -= delta
		if _memory_elapsed <= 0.0 and not _memory_request_in_flight:
			_check_memory_status.call_deferred()

func set_core_key(key: String) -> void:
	var normalized := key.strip_edges()
	if normalized == _core_key:
		_health_elapsed = 0.0
		return
	_core_key = normalized
	_invalidate_monitor_requests()
	# 换 key 后旧请求的鉴权上下文失效：未发出的直接清除，在途的标记取消。
	for pending_id in _pending_requests.keys():
		var pending_info: Dictionary = _pending_requests[pending_id]
		if bool(pending_info.get("in_flight", false)):
			pending_info["cancelled"] = true
		else:
			_pending_requests.erase(pending_id)
	_health_elapsed = 0.0
	if _core_key.is_empty():
		_should_monitor = false
		_set_active(false, "未配置 Companion Core 密钥")
	elif _should_monitor:
		_set_active(false, "Companion Core 密钥已更新，正在重新连接")

func set_token(token: String) -> void:
	# Compatibility alias. This value is a Companion Core key, never a dashboard JWT.
	set_core_key(token)

func set_base_url(base_url: String) -> void:
	var normalized := base_url.strip_edges().trim_suffix("/")
	if normalized.is_empty():
		normalized = DEFAULT_CORE_BASE_URL
	if not normalized.begins_with("http://") and not normalized.begins_with("https://"):
		push_warning("Companion Core URL must use http:// or https://")
		return
	if normalized == _base_url:
		return
	_base_url = normalized
	_invalidate_monitor_requests()
	_health_elapsed = 0.0
	if _should_monitor:
		_set_active(false, "Companion Core address updated; reconnecting")

func get_base_url() -> String:
	return _base_url

func get_backend_name() -> String:
	return "Spring Haven Companion Core"

func get_managed_core_status() -> Dictionary:
	var running := _managed_core_pid > 0 and OS.is_process_running(_managed_core_pid)
	return {
		"owned": _managed_core_pid > 0,
		"running": running,
		"pid": _managed_core_pid if running else -1,
		"start_count": _managed_core_start_count,
		"last_error": _managed_core_last_error,
		"runtime_root": str(_local_core_layout.get("runtime_root", "")),
		"runtime_created": _local_runtime_created,
		"runtime_error": _local_runtime_error,
	}

func has_credentials() -> bool:
	return not _core_key.is_empty()

func has_token() -> bool:
	return has_credentials()

func set_save_id(save_id: String) -> void:
	var normalized := save_id.strip_edges()
	if normalized.is_empty():
		_save_id = DEFAULT_SAVE_ID
	elif _is_valid_save_id(normalized):
		_save_id = normalized
	else:
		push_warning("忽略不符合 Companion Core 协议的存档 ID：%s" % normalized)
		_save_id = DEFAULT_SAVE_ID
	_memory_elapsed = 0.0
	# 换档后清除其他存档的待处理请求，防止旧 save_id 的请求被重试到新旅程。
	for pending_id in _pending_requests.keys():
		var pending_info: Dictionary = _pending_requests[pending_id]
		var pending_save_id := str(
			(pending_info.get("payload", {}) as Dictionary).get("save_id", "")
		)
		if pending_save_id == _save_id:
			continue
		if bool(pending_info.get("in_flight", false)):
			pending_info["cancelled"] = true
		else:
			_pending_requests.erase(pending_id)

func get_save_id() -> String:
	return _save_id

func connect_to_core(key: String = "") -> void:
	if not key.is_empty():
		set_core_key(key)
	_invalidate_monitor_requests()
	if not has_credentials():
		_should_monitor = false
		_set_active(false, "未配置 Companion Core 密钥")
		return
	_should_monitor = true
	_health_elapsed = 0.0

func disconnect_from_core() -> void:
	_should_monitor = false
	_invalidate_monitor_requests()
	_set_active(false, "已断开")

func is_active() -> bool:
	return _active

func send_chat(
	character: String,
	text: String,
	context: Variant = "",
	conversation_id: String = "",
	event_type: String = "chat",
	state: Dictionary = {}
) -> String:
	var request_id := "%s-%d-%d" % [_save_id, Time.get_ticks_msec(), randi()]
	if character not in CHARACTERS:
		call_deferred("_emit_new_request_error", request_id, "未知角色：%s" % character, false)
		return request_id
	if text.strip_edges().is_empty():
		call_deferred("_emit_new_request_error", request_id, "消息不能为空", false)
		return request_id
	if not has_credentials():
		call_deferred("_emit_new_request_error", request_id, "未配置 Companion Core 密钥", false)
		return request_id

	var request_save_id := conversation_id.strip_edges()
	if request_save_id.is_empty():
		request_save_id = _save_id
	if not _is_valid_save_id(request_save_id):
		call_deferred("_emit_new_request_error", request_id, "存档 ID 不符合 Companion Core 协议", false)
		return request_id
	if event_type not in ["chat", "action"]:
		call_deferred("_emit_new_request_error", request_id, "未知事件类型：%s" % event_type, false)
		return request_id
	var history: Array = context if context is Array else []
	var legacy_context := str(context) if context is String else ""
	var request_timeout := int(Settings.get_runtime_tuning_value(
		"request_timeout_seconds", int(CHAT_TIMEOUT_SECONDS - 5.0)
	))
	var payload := {
		"request_id": request_id,
		"role_id": character,
		"save_id": request_save_id,
		"text": text.strip_edges(),
		"history": history,
		"context": legacy_context,
		"event_type": event_type,
		"state": state,
		"timeout": request_timeout
	}
	_pending_requests[request_id] = {
		"payload": payload,
		"in_flight": false,
		"last_error": "",
		"retryable": true,
		"retry_attempts": 0,
		"request_timeout": request_timeout,
	}
	_dispatch_request.call_deferred(request_id)
	return request_id

func orchestrate_chat(
	text: String,
	selected_role_id: String,
	recipient_role_ids: Array[String],
	history: Array[Dictionary] = [],
	conversation_id: String = "",
	event_type: String = "action",
	state: Dictionary = {},
	state_by_role: Dictionary = {},
	stable_request_id: String = ""
) -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	if selected_role_id not in CHARACTERS:
		return {"ok": false, "message": "未知主导角色", "retryable": false}
	var roles: Array[String] = []
	for role in recipient_role_ids:
		if role in CHARACTERS and role not in roles:
			roles.append(role)
	if roles.is_empty():
		return {"ok": false, "message": "没有有效回复角色", "retryable": false}
	var request_save_id := conversation_id.strip_edges()
	if request_save_id.is_empty():
		request_save_id = _save_id
	if not _is_valid_save_id(request_save_id):
		return {"ok": false, "message": "存档 ID 不符合 Companion Core 协议", "retryable": false}
	var request_id := stable_request_id.strip_edges()
	if request_id.is_empty():
		request_id = "life-lab-%d-%d" % [Time.get_ticks_msec(), randi()]
	elif not _is_valid_request_id(request_id):
		return {"ok": false, "message": "请求 ID 不符合 Companion Core 协议", "retryable": false}
	return await _request_json(
		HTTPClient.METHOD_POST,
		_url("/orchestrate"),
		{
			"request_id": request_id,
			"source_message_id": request_id,
			"save_id": request_save_id,
			"text": text.strip_edges(),
			"selected_role_id": selected_role_id,
			"recipient_role_ids": roles,
			"reply_mode": "both" if roles.size() > 1 else "selected",
			"history": history,
			"event_type": event_type,
			"state": state,
			"state_by_role": state_by_role,
		},
		CHAT_TIMEOUT_SECONDS * maxf(1.0, float(roles.size()))
	)

func retry_request(request_id: String) -> bool:
	if not _pending_requests.has(request_id):
		return false
	var info: Dictionary = _pending_requests[request_id]
	if bool(info.get("in_flight", false)) or not bool(info.get("retryable", false)):
		return false
	# 防止旧存档的失败请求被重试进新旅程。
	var payload_save_id := str((info.get("payload", {}) as Dictionary).get("save_id", ""))
	if not payload_save_id.is_empty() and payload_save_id != _save_id:
		_pending_requests.erase(request_id)
		return false
	_dispatch_request.call_deferred(request_id)
	return true

func discard_request(request_id: String) -> void:
	_pending_requests.erase(request_id)

func has_pending_request(request_id: String) -> bool:
	return _pending_requests.has(request_id)

func reset_session(save_id: String = "") -> Dictionary:
	var target_save_id := save_id.strip_edges()
	if target_save_id.is_empty():
		target_save_id = _save_id
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 密钥", "retryable": false}
	if not _is_valid_save_id(target_save_id):
		return {"ok": false, "message": "存档 ID 不符合 Companion Core 协议", "retryable": false}
	return await _request_json(
		HTTPClient.METHOD_POST,
		_url("/session/reset"),
		{"save_id": target_save_id},
		HEALTH_TIMEOUT_SECONDS
	)

func get_provider_status() -> Dictionary:
	if not has_credentials():
		return {
			"ok": false,
			"message": "未配置 Companion Core 本地密钥",
			"retryable": false,
			"status_code": 0,
		}
	var result := await _request_json(
		HTTPClient.METHOD_GET,
		_url("/providers/status"),
		{},
		HEALTH_TIMEOUT_SECONDS
	)
	if bool(result.get("ok", false)) and result.get("data", {}) is Dictionary:
		_provider_status_cache = (result.get("data", {}) as Dictionary).duplicate(true)
	return result

func get_cached_provider_status() -> Dictionary:
	return _provider_status_cache.duplicate(true)

func diagnose_provider(capability: String) -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	return await _request_json(
		HTTPClient.METHOD_POST,
		_url("/providers/diagnose"),
		{"capability": capability.strip_edges().to_lower()},
		CHAT_TIMEOUT_SECONDS
	)

func is_provider_configured(capability: String) -> bool:
	var profiles = _provider_status_cache.get("profiles", {})
	if not profiles is Dictionary:
		return false
	var profile = (profiles as Dictionary).get(capability, {})
	return (
		profile is Dictionary
		and bool((profile as Dictionary).get("enabled", false))
		and bool((profile as Dictionary).get("request_ready", false))
	)

func configure_provider(
	base_url: String,
	model: String,
	api_key: String = "",
	clear_api_key: bool = false
) -> Dictionary:
	if not has_credentials():
		return {
			"ok": false,
			"message": "未配置 Companion Core 本地密钥",
			"retryable": false,
			"status_code": 0,
		}
	var payload := {
		"base_url": base_url.strip_edges(),
		"model": model.strip_edges(),
		"clear_api_key": clear_api_key,
		"persist": true,
	}
	# An empty value means “keep the existing key”; the Core never echoes it back.
	if not api_key.strip_edges().is_empty():
		payload["api_key"] = api_key.strip_edges()
	var result := await _request_json(
		HTTPClient.METHOD_POST,
		_url("/provider/config"),
		payload,
		HEALTH_TIMEOUT_SECONDS
	)
	if bool(result.get("ok", false)) and result.get("data", {}) is Dictionary:
		_provider_status_cache = (result.get("data", {}) as Dictionary).duplicate(true)
	return result

func configure_provider_profile(
	capability: String,
	base_url: String,
	model: String,
	protocol: String,
	enabled: bool,
	inherit_chat_key: bool,
	allow_insecure_http: bool,
	api_key: String = "",
	clear_api_key: bool = false
) -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	var payload := {
		"capability": capability,
		"base_url": base_url.strip_edges(),
		"model": model.strip_edges(),
		"protocol": protocol,
		"enabled": enabled,
		"inherit_chat_key": inherit_chat_key,
		"allow_insecure_http": allow_insecure_http,
		"clear_api_key": clear_api_key,
		"persist": true,
	}
	if not api_key.strip_edges().is_empty():
		payload["api_key"] = api_key.strip_edges()
	var result := await _request_json(
		HTTPClient.METHOD_POST,
		_url("/providers/config"),
		payload,
		HEALTH_TIMEOUT_SECONDS
	)
	if bool(result.get("ok", false)):
		await get_provider_status()
	return result

func configure_provider_fallbacks(capability: String, candidates: Array) -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	var result := await _request_json(
		HTTPClient.METHOD_POST,
		_url("/providers/fallbacks"),
		{"capability": capability, "candidates": candidates},
		HEALTH_TIMEOUT_SECONDS
	)
	if bool(result.get("ok", false)):
		await get_provider_status()
	return result

func transcribe_audio(wav_bytes: PackedByteArray, language := "zh") -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	if wav_bytes.size() < 44 or wav_bytes.size() > 8_000_000:
		return {"ok": false, "message": "语音录音大小无效", "retryable": false}
	var normalized_language := language.strip_edges().left(16)
	return await _request_binary_json(
		HTTPClient.METHOD_POST,
		_url("/audio/transcribe") + "?language=" + normalized_language.uri_encode(),
		wav_bytes,
		"audio/wav",
		CHAT_TIMEOUT_SECONDS
	)

func synthesize_speech(
	text: String,
	voice := "",
	response_format := "wav",
	speed := 1.0
) -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	var normalized_text := text.strip_edges().left(4000)
	if normalized_text.is_empty():
		return {"ok": false, "message": "TTS 文本为空", "retryable": false}
	var result := await _request_json(
		HTTPClient.METHOD_POST,
		_url("/audio/speech"),
		{
			"input": normalized_text,
			"voice": voice.strip_edges().left(512),
			"response_format": response_format.strip_edges().to_lower(),
			"speed": clampf(float(speed), 0.25, 4.0),
		},
		CHAT_TIMEOUT_SECONDS
	)
	if not bool(result.get("ok", false)):
		return result
	var data = result.get("data", {})
	if not data is Dictionary:
		return {"ok": false, "message": "Companion Core 返回了无效 TTS 结果", "retryable": true}
	var audio_base64 := str((data as Dictionary).get("audio_base64", ""))
	if audio_base64.is_empty():
		return {"ok": false, "message": "TTS 返回空音频", "retryable": true}
	var audio := Marshalls.base64_to_raw(audio_base64)
	if audio.is_empty():
		return {"ok": false, "message": "TTS 音频解码失败", "retryable": true}
	return {
		"ok": true,
		"audio": audio,
		"mime_type": str((data as Dictionary).get("mime_type", "audio/wav")),
		"provider": str((data as Dictionary).get("provider", "companion_core")),
	}

func configure_rag(settings: Dictionary) -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	var result := await _request_json(
		HTTPClient.METHOD_POST,
		_url("/rag/config"),
		settings,
		HEALTH_TIMEOUT_SECONDS
	)
	if bool(result.get("ok", false)):
		await get_provider_status()
	return result

func configure_network_proxy(mode: String, proxy_url: String = "") -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	var result := await _request_json(
		HTTPClient.METHOD_POST,
		_url("/network/proxy"),
		{"mode": mode.strip_edges(), "url": proxy_url.strip_edges()},
		HEALTH_TIMEOUT_SECONDS
	)
	if bool(result.get("ok", false)):
		await get_provider_status()
	return result

func get_rag_status() -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	return await _request_json(
		HTTPClient.METHOD_GET,
		_url("/rag/status"),
		{},
		HEALTH_TIMEOUT_SECONDS
	)

func get_maintenance_status() -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	return await _request_json(
		HTTPClient.METHOD_GET,
		_url("/maintenance/status"),
		{},
		HEALTH_TIMEOUT_SECONDS
	)

func list_storage_backups() -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	return await _request_json(
		HTTPClient.METHOD_GET,
		_url("/maintenance/backups"),
		{},
		HEALTH_TIMEOUT_SECONDS
	)

func verify_storage_backup(backup_name: String) -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	return await _request_json(
		HTTPClient.METHOD_POST,
		_url("/maintenance/backups/") + backup_name.uri_encode() + "/verify",
		{},
		CHAT_TIMEOUT_SECONDS
	)

func run_storage_maintenance(force_backup: bool = true) -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	return await _request_json(
		HTTPClient.METHOD_POST,
		_url("/maintenance/run"),
		{"force_backup": force_backup},
		CHAT_TIMEOUT_SECONDS
	)

func sync_life_state(
	snapshot: Dictionary,
	last_user_activity_at: int,
	recent_events: Array = []
) -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	var payload := {
		"save_id": _save_id,
		"selected_role_id": Global.current_character,
		"last_user_activity_at": last_user_activity_at,
		"snapshot": snapshot,
	}
	if not recent_events.is_empty():
		payload["recent_events"] = recent_events.slice(0, 20)
	return await _request_json(
		HTTPClient.METHOD_POST,
		_url("/life/sync"),
		payload,
		HEALTH_TIMEOUT_SECONDS
	)

func fetch_life_events(
	limit: int = 100,
	role_id: String = "",
	action: String = ""
) -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	var query := "?save_id=" + _save_id.uri_encode() + "&limit=" + str(clampi(limit, 1, 500))
	if not role_id.is_empty():
		query += "&role_id=" + role_id.uri_encode()
	if not action.is_empty():
		query += "&action=" + action.uri_encode()
	return await _request_json(
		HTTPClient.METHOD_GET,
		_url("/life/events") + query,
		{},
		HEALTH_TIMEOUT_SECONDS
	)

func poll_life_outbox(limit: int = 16) -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	return await _request_json(
		HTTPClient.METHOD_GET,
		_url("/life/outbox") + "?save_id=" + _save_id.uri_encode() + "&limit=" + str(clampi(limit, 1, 64)),
		{},
		HEALTH_TIMEOUT_SECONDS
	)

func acknowledge_life_outbox(delivery_ids: Array[String]) -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	if delivery_ids.is_empty():
		return {"ok": true, "data": {"acknowledged": 0}}
	return await _request_json(
		HTTPClient.METHOD_POST,
		_url("/life/outbox/ack"),
		{"save_id": _save_id, "delivery_ids": delivery_ids},
		HEALTH_TIMEOUT_SECONDS
	)

func get_life_status() -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	return await _request_json(
		HTTPClient.METHOD_GET,
		_url("/life/status") + "?save_id=" + _save_id.uri_encode(),
		{},
		HEALTH_TIMEOUT_SECONDS
	)

func get_memory_graph(scope: String = "", query: String = "", limit: int = 120) -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	var url := _url("/memory/graph") + "?save_id=" + _save_id.uri_encode()
	if not scope.strip_edges().is_empty():
		url += "&scope=" + scope.strip_edges().uri_encode()
	if not query.strip_edges().is_empty():
		url += "&query=" + query.strip_edges().uri_encode()
	url += "&limit=" + str(clampi(limit, 1, 200))
	return await _request_json(
		HTTPClient.METHOD_GET,
		url,
		{},
		HEALTH_TIMEOUT_SECONDS
	)

func list_rag_documents(limit: int = 100) -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	return await _request_json(
		HTTPClient.METHOD_GET,
		_url("/rag/documents") + "?limit=" + str(clampi(limit, 1, 500)),
		{},
		HEALTH_TIMEOUT_SECONDS
	)

func get_rag_document(document_id: String) -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	return await _request_json(
		HTTPClient.METHOD_GET,
		_url("/rag/documents/") + document_id.uri_encode(),
		{},
		HEALTH_TIMEOUT_SECONDS
	)

func put_rag_document(document: Dictionary) -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	return await _request_json(
		HTTPClient.METHOD_POST,
		_url("/rag/documents"),
		document,
		CHAT_TIMEOUT_SECONDS
	)

func batch_rag_documents(action: String, document_ids: Array, scope: String = "") -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	var payload := {"action": action.strip_edges(), "document_ids": document_ids}
	if not scope.is_empty():
		payload["scope"] = scope
	return await _request_json(
		HTTPClient.METHOD_POST,
		_url("/rag/documents/batch"),
		payload,
		CHAT_TIMEOUT_SECONDS
	)

func import_rag_file(
	filename: String,
	bytes: PackedByteArray,
	title: String = "",
	scope: String = "*",
	source_uri: String = ""
) -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	if bytes.is_empty():
		return {"ok": false, "message": "知识文件为空", "retryable": false}
	return await _request_json(
		HTTPClient.METHOD_POST,
		_url("/rag/import"),
		{
			"filename": filename,
			"content_base64": Marshalls.raw_to_base64(bytes),
			"title": title,
			"scope": scope,
			"source_uri": source_uri,
		},
		CHAT_TIMEOUT_SECONDS
	)

func import_rag_url(
	url: String,
	title: String = "",
	scope: String = "*"
) -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	return await _request_json(
		HTTPClient.METHOD_POST,
		_url("/rag/import-url"),
		{"url": url, "title": title, "scope": scope},
		CHAT_TIMEOUT_SECONDS
	)

func search_rag(query: String, role_id: String = "", limit: int = 6) -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	return await _request_json(
		HTTPClient.METHOD_POST,
		_url("/rag/search"),
		{"query": query, "role_id": role_id, "limit": limit},
		CHAT_TIMEOUT_SECONDS
	)

func delete_rag_document(document_id: String) -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	return await _request_json(
		HTTPClient.METHOD_DELETE,
		_url("/rag/documents/") + document_id.uri_encode(),
		{},
		HEALTH_TIMEOUT_SECONDS
	)

func reindex_rag() -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	return await _request_json(
		HTTPClient.METHOD_POST,
		_url("/rag/reindex"),
		{},
		CHAT_TIMEOUT_SECONDS
	)

func analyze_image_bytes(
	bytes: PackedByteArray,
	mime_type: String,
	symbolic_context: Dictionary = {},
	question: String = ""
) -> Dictionary:
	if not has_credentials():
		return {"ok": false, "message": "未配置 Companion Core 本地密钥", "retryable": false}
	if bytes.is_empty():
		return {"ok": false, "message": "图像为空", "retryable": false}
	return await _request_json(
		HTTPClient.METHOD_POST,
		_url("/vision/analyze"),
		{
			"image_base64": Marshalls.raw_to_base64(bytes),
			"mime_type": mime_type,
			"symbolic_context": symbolic_context,
			"question": question,
		},
		CHAT_TIMEOUT_SECONDS
	)

func _dispatch_request(request_id: String) -> void:
	if not _pending_requests.has(request_id):
		return
	var info: Dictionary = _pending_requests[request_id]
	if bool(info.get("in_flight", false)):
		return
	info.in_flight = true
	info.last_error = ""
	var monitor_generation := _monitor_generation
	var request_timeout := float(info.get("request_timeout", CHAT_TIMEOUT_SECONDS - 5.0))
	var result := await _request_json(
		HTTPClient.METHOD_POST,
		_url("/chat"),
		info.payload,
		request_timeout + 5.0
	)
	if not _pending_requests.has(request_id):
		return
	info = _pending_requests[request_id]
	if bool(info.get("cancelled", false)):
		_pending_requests.erase(request_id)
		return
	info.in_flight = false
	if not bool(result.get("ok", false)):
		var message := str(result.get("message", "Companion Core 请求失败"))
		var retryable := bool(result.get("retryable", true))
		info.last_error = message
		info.retryable = retryable
		var retry_attempts := int(info.get("retry_attempts", 0))
		var retry_limit := int(Settings.get_runtime_tuning_value("auto_retry_count", 0))
		if retryable and retry_attempts < retry_limit:
			info.retry_attempts = retry_attempts + 1
			_pending_requests[request_id] = info
			await get_tree().create_timer(0.75 * float(retry_attempts + 1)).timeout
			_dispatch_request.call_deferred(request_id)
			return
		if (
			int(result.get("status_code", 0)) in [401, 403]
			and monitor_generation == _monitor_generation
			and _should_monitor
		):
			_set_active(false, "Companion Core 鉴权失败")
		request_failed.emit(request_id, message, retryable)
		error_received.emit(message)
		if retryable:
			# 保留给手动重试，但打上时间戳供监控循环定期清理，避免常驻泄漏。
			info.failed_at = Time.get_ticks_msec()
			_pending_requests[request_id] = info
		else:
			_pending_requests.erase(request_id)
		return

	var response_data = result.get("data", {})
	if response_data is Dictionary:
		var memory_variant = (response_data as Dictionary).get("memory", {})
		if memory_variant is Dictionary:
			var recalled_count := maxi(0, int((memory_variant as Dictionary).get("recalled_count", 0)))
			var organizer_state := str((memory_variant as Dictionary).get("organizer_state", "disabled"))
			var display_state := (
				organizer_state
				if organizer_state in ["queued", "processing", "skipped", "error"]
				else ("success" if recalled_count > 0 else "ready")
			)
			var display_message := "心织记忆已记录本轮经历"
			match organizer_state:
				"queued":
					display_message = "本轮经历已保存，等待角色专属整理"
				"processing":
					display_message = "正在使用角色专属提示词整理记忆"
				"skipped":
					display_message = "本轮没有需要额外整理的长期信息"
				_:
					if recalled_count > 0:
						display_message = "本轮唤起 %d 条心织记忆" % recalled_count
			memory_status_changed.emit({
				"state": display_state,
				"message": display_message,
				"last_recall_count": recalled_count,
				"role_id": str((memory_variant as Dictionary).get("organizer_role_id", "")),
				"backend": "heartloom",
			})
	var reply := str(response_data.get("reply", "")) if response_data is Dictionary else ""
	var attachments: Array = []
	if response_data is Dictionary and response_data.get("attachments", []) is Array:
		attachments = (response_data.get("attachments", []) as Array).duplicate(true)
	var scene_actions: Array = []
	if response_data is Dictionary and response_data.get("scene_actions", []) is Array:
		for action_variant in response_data.get("scene_actions", []):
			if action_variant is Dictionary:
				scene_actions.append((action_variant as Dictionary).duplicate(true))
	if reply.strip_edges().is_empty():
		info.last_error = "Companion Core 返回了空回复"
		info.retryable = true
		info.failed_at = Time.get_ticks_msec()
		_pending_requests[request_id] = info
		request_failed.emit(request_id, info.last_error, true)
		error_received.emit(info.last_error)
		return
	_pending_requests.erase(request_id)
	if monitor_generation == _monitor_generation and _should_monitor:
		_set_active(true, "已连接")
	if not scene_actions.is_empty():
		scene_actions_received.emit(request_id, scene_actions)
	reply_received.emit(request_id, reply.strip_edges(), attachments)
	reply_finished.emit(request_id)

func _check_health() -> void:
	# 定期清理终态失败的待处理请求（保留 5 分钟给手动重试），防止常驻泄漏。
	var sweep_now := Time.get_ticks_msec()
	for stale_id in _pending_requests.keys():
		var stale_info: Dictionary = _pending_requests[stale_id]
		if bool(stale_info.get("in_flight", false)) or not stale_info.has("failed_at"):
			continue
		if sweep_now - int(stale_info["failed_at"]) > 300000:
			_pending_requests.erase(stale_id)
	if _health_request_in_flight or not _should_monitor or not has_credentials():
		return
	_health_request_in_flight = true
	var monitor_generation := _monitor_generation
	var result := await _request_json(
		HTTPClient.METHOD_GET,
		_url("/health"),
		{},
		HEALTH_TIMEOUT_SECONDS
	)
	if monitor_generation != _monitor_generation or not _should_monitor:
		return
	_health_request_in_flight = false
	if bool(result.get("ok", false)):
		var health_data = result.get("data", {})
		if health_data is Dictionary:
			var provider_data = (health_data as Dictionary).get("provider", {})
			if provider_data is Dictionary:
				_provider_status_cache = (provider_data as Dictionary).duplicate(true)
		_health_retry_seconds = 1.0
		_health_elapsed = HEALTH_INTERVAL_SECONDS
		_set_active(true, "已连接")
		return
	var message := str(result.get("message", "Companion Core 不可用"))
	_set_active(false, message)
	if int(result.get("status_code", 0)) == 0 and _maybe_start_local_core():
		_health_elapsed = MANAGED_CORE_HEALTH_DELAY_SECONDS
		return
	_health_elapsed = _health_retry_seconds
	_health_retry_seconds = minf(MAX_HEALTH_RETRY_SECONDS, _health_retry_seconds * 2.0)

func _maybe_start_local_core() -> bool:
	if not bool(Settings.get_runtime_tuning_value("core_autostart_enabled", true)):
		return false
	if not _is_loopback_core_url():
		return false
	if _managed_core_pid > 0 and OS.is_process_running(_managed_core_pid):
		return false
	if _managed_core_pid > 0:
		_managed_core_pid = -1
	var cooldown_seconds := int(Settings.get_runtime_tuning_value(
		"core_restart_cooldown_seconds", 10
	))
	var now_msec := Time.get_ticks_msec()
	if now_msec - _managed_core_last_start_msec < cooldown_seconds * 1000:
		return false

	var launch := _local_core_launch_spec()
	if launch.is_empty():
		_managed_core_last_error = "未找到 Companion Core 可执行文件或项目虚拟环境"
		return false
	_managed_core_last_start_msec = now_msec
	var executable := str(launch.get("executable", ""))
	var arguments := PackedStringArray(launch.get("arguments", []))
	var pid := OS.create_process(executable, arguments, false)
	if pid <= 0:
		_managed_core_last_error = "启动失败：%s" % executable
		return false
	_managed_core_pid = pid
	_managed_core_start_count += 1
	_managed_core_last_error = ""
	_set_active(false, "正在启动 Companion Core…")
	return true

func _is_loopback_core_url() -> bool:
	var normalized := _base_url.to_lower()
	return (
		normalized.begins_with("http://127.0.0.1:")
		or normalized == "http://127.0.0.1"
		or normalized.begins_with("http://localhost:")
		or normalized == "http://localhost"
		or normalized.begins_with("http://[::1]:")
		or normalized == "http://[::1]"
	)

func _local_core_launch_spec() -> Dictionary:
	if _local_core_layout.is_empty():
		_prepare_local_core_runtime()
	if _local_core_layout.is_empty():
		return {}
	var core_root := str(_local_core_layout.get("core_root", ""))
	var runtime_root := str(_local_core_layout.get("runtime_root", ""))
	var config_path := runtime_root.path_join("core_config.json")
	var roles_path := runtime_root.path_join("roles.json")
	if not FileAccess.file_exists(config_path) or not FileAccess.file_exists(roles_path):
		return {}
	var common_arguments := PackedStringArray([
		"--config", config_path,
		"--roles", roles_path,
		"--log-file", runtime_root.path_join("logs/companion-core.log"),
	])
	var runner: Dictionary = _find_core_runner(core_root)
	if runner.is_empty():
		return {}
	if str(runner.get("kind", "")) == "executable":
		return {"executable": str(runner.get("path", "")), "arguments": common_arguments}
	var python_arguments := PackedStringArray(["-m", "spring_haven_core"])
	python_arguments.append_array(common_arguments)
	return {"executable": str(runner.get("path", "")), "arguments": python_arguments}

func _prepare_local_core_runtime() -> void:
	_local_core_layout.clear()
	_local_runtime_created = false
	_local_runtime_error = ""
	var project_core_root := ProjectSettings.globalize_path("res://../companion-core").simplify_path()
	var executable_core_root := OS.get_executable_path().get_base_dir().path_join("companion-core").simplify_path()
	var candidates: Array[String] = [project_core_root]
	if executable_core_root not in candidates:
		candidates.append(executable_core_root)
	for core_root in candidates:
		if _find_core_runner(core_root).is_empty():
			continue
		var is_project_runtime := core_root == project_core_root
		var runtime_root := (
			core_root.path_join("user_data")
			if is_project_runtime
			else ProjectSettings.globalize_path(USER_CORE_RUNTIME_DIR).simplify_path()
		)
		var template_root := core_root.path_join("config")
		if not _ensure_core_runtime(template_root, runtime_root):
			return
		_local_core_layout = {
			"core_root": core_root,
			"runtime_root": runtime_root,
			"template_root": template_root,
		}
		return
	_local_runtime_error = "未找到 Companion Core 运行组件"

func _find_core_runner(core_root: String) -> Dictionary:
	var packaged_executable := core_root.path_join("bin/spring-haven-core.exe")
	if FileAccess.file_exists(packaged_executable):
		return {"kind": "executable", "path": packaged_executable}
	var venv_python := core_root.path_join(".venv/Scripts/python.exe")
	if FileAccess.file_exists(venv_python):
		return {"kind": "python", "path": venv_python}
	return {}

func _ensure_core_runtime(template_root: String, runtime_root: String) -> bool:
	var config_path := runtime_root.path_join("core_config.json")
	var roles_path := runtime_root.path_join("roles.json")
	var runtime_exists := FileAccess.file_exists(config_path) and FileAccess.file_exists(roles_path)
	if DirAccess.make_dir_recursive_absolute(runtime_root) != OK:
		_local_runtime_error = "无法创建 Companion Core 用户目录"
		return false
	for relative_dir in ["personas", "memory_prompts", "logs"]:
		if DirAccess.make_dir_recursive_absolute(runtime_root.path_join(relative_dir)) != OK:
			_local_runtime_error = "无法创建 Companion Core 子目录：%s" % relative_dir
			return false
	var required_templates := {
		"roles.example.json": "roles.json",
		"personas/ling.md": "personas/ling.md",
		"personas/nai.md": "personas/nai.md",
		"memory_prompts/ling.md": "memory_prompts/ling.md",
		"memory_prompts/nai.md": "memory_prompts/nai.md",
	}
	for source_relative in required_templates:
		var destination_relative := str(required_templates[source_relative])
		if not _copy_file_if_missing(
			template_root.path_join(str(source_relative)),
			runtime_root.path_join(destination_relative)
		):
			return false
	# 可选模板：发行包自带知识库时复制到运行时目录，开发树缺失时跳过。
	var optional_templates := {
		"knowledge.sqlite3": "knowledge.sqlite3",
	}
	for source_relative in optional_templates:
		var source_path := template_root.path_join(str(source_relative))
		if not FileAccess.file_exists(source_path):
			continue
		var destination_relative := str(optional_templates[source_relative])
		if not _copy_file_if_missing(source_path, runtime_root.path_join(destination_relative)):
			return false
	if not FileAccess.file_exists(config_path):
		var source_config_path := template_root.path_join("core_config.example.json")
		if not FileAccess.file_exists(source_config_path):
			_local_runtime_error = "缺少 Core 默认配置模板"
			return false
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(source_config_path))
		if not parsed is Dictionary:
			_local_runtime_error = "Core 默认配置模板无效"
			return false
		var core_key := _read_saved_core_key()
		if core_key.length() < 32:
			core_key = Crypto.new().generate_random_bytes(32).hex_encode()
		(parsed as Dictionary)["api_key"] = core_key
		if not _write_text_file(config_path, JSON.stringify(parsed, "  ") + "\n"):
			_local_runtime_error = "无法写入 Core 配置"
			return false
		if not _write_text_file(ProjectSettings.globalize_path(CORE_KEY_FILE), core_key + "\n"):
			_local_runtime_error = "无法保存 Core 本地密钥"
			return false
		_local_runtime_created = true
	elif not FileAccess.file_exists(ProjectSettings.globalize_path(CORE_KEY_FILE)):
		var parsed_existing = JSON.parse_string(FileAccess.get_file_as_string(config_path))
		var existing_key := str(parsed_existing.get("api_key", "")).strip_edges() if parsed_existing is Dictionary else ""
		if existing_key.length() >= 32:
			if not _write_text_file(ProjectSettings.globalize_path(CORE_KEY_FILE), existing_key + "\n"):
				_local_runtime_error = "无法保存 Core 本地密钥"
				return false
	_local_runtime_created = _local_runtime_created or not runtime_exists
	return true

func _copy_file_if_missing(source_path: String, destination_path: String) -> bool:
	if FileAccess.file_exists(destination_path):
		return true
	if not FileAccess.file_exists(source_path):
		_local_runtime_error = "缺少首次启动模板：%s" % source_path.get_file()
		return false
	var source := FileAccess.open(source_path, FileAccess.READ)
	if source == null:
		_local_runtime_error = "无法读取首次启动模板：%s" % source_path.get_file()
		return false
	var bytes := source.get_buffer(source.get_length())
	var destination := FileAccess.open(destination_path, FileAccess.WRITE)
	if destination == null:
		_local_runtime_error = "无法写入首次启动文件：%s" % destination_path.get_file()
		return false
	destination.store_buffer(bytes)
	return true

func _read_saved_core_key() -> String:
	var key_path := ProjectSettings.globalize_path(CORE_KEY_FILE)
	if not FileAccess.file_exists(key_path):
		return ""
	return FileAccess.get_file_as_string(key_path).strip_edges()

func _write_text_file(path: String, content: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(content)
	return true

func _check_memory_status() -> void:
	if _memory_request_in_flight or not _should_monitor or not has_credentials() or not _active:
		return
	_memory_request_in_flight = true
	var generation := _monitor_generation
	var result := await _request_json(
		HTTPClient.METHOD_GET,
		_url("/memory/status") + "?save_id=" + _save_id.uri_encode(),
		{},
		HEALTH_TIMEOUT_SECONDS
	)
	_memory_request_in_flight = false
	_memory_elapsed = MEMORY_INTERVAL_SECONDS
	if generation != _monitor_generation or not _should_monitor:
		return
	if not bool(result.get("ok", false)):
		return
	var data = result.get("data", {})
	if data is Dictionary:
		memory_status_changed.emit((data as Dictionary).duplicate(true))

func _request_json(method: int, url: String, payload: Dictionary, timeout_seconds: float) -> Dictionary:
	var request := HTTPRequest.new()
	request.timeout = timeout_seconds
	add_child(request)
	var headers := PackedStringArray([
		"X-API-Key: " + _core_key,
		"Content-Type: application/json"
	])
	var body := "" if method == HTTPClient.METHOD_GET else JSON.stringify(payload)
	var start_error := request.request(url, headers, method, body)
	if start_error != OK:
		request.queue_free()
		return {"ok": false, "message": error_string(start_error), "retryable": true, "status_code": 0}
	var response: Array = await request.request_completed
	request.queue_free()
	if response.size() < 4:
		return {"ok": false, "message": "Companion Core 返回了无效响应", "retryable": true, "status_code": 0}
	var result := int(response[0])
	var response_code := int(response[1])
	var response_text := (response[3] as PackedByteArray).get_string_from_utf8()
	if result != HTTPRequest.RESULT_SUCCESS:
		return {
			"ok": false,
			"message": _http_request_failure_message(result, url),
			"retryable": true,
			"status_code": response_code
		}
	var parsed = JSON.parse_string(response_text)
	if response_code < 200 or response_code >= 300:
		var detail := str(parsed.get("message", "")) if parsed is Dictionary else ""
		if detail.is_empty():
			detail = "HTTP %d" % response_code
		var retryable := response_code in [408, 425, 429, 500, 502, 503, 504]
		if parsed is Dictionary and parsed.get("retryable") is bool:
			retryable = bool(parsed.get("retryable"))
		return {
			"ok": false,
			"message": detail,
			"retryable": retryable,
			"status_code": response_code
		}
	if not parsed is Dictionary or str(parsed.get("status", "")) != "ok":
		return {
			"ok": false,
			"message": str(parsed.get("message", response_text)) if parsed is Dictionary else response_text,
			"retryable": true,
			"status_code": response_code
		}
	var response_data = parsed.get("data")
	if response_data == null:
		response_data = parsed
	return {"ok": true, "data": response_data, "status_code": response_code}

func _request_binary_json(
	method: int,
	url: String,
	body: PackedByteArray,
	content_type: String,
	timeout_seconds: float
) -> Dictionary:
	var request := HTTPRequest.new()
	request.timeout = timeout_seconds
	add_child(request)
	var headers := PackedStringArray([
		"X-API-Key: " + _core_key,
		"Content-Type: " + content_type,
	])
	var start_error := request.request_raw(url, headers, method, body)
	if start_error != OK:
		request.queue_free()
		return {"ok": false, "message": error_string(start_error), "retryable": true, "status_code": 0}
	var response: Array = await request.request_completed
	request.queue_free()
	if response.size() < 4:
		return {"ok": false, "message": "Companion Core 返回了无效响应", "retryable": true, "status_code": 0}
	var result := int(response[0])
	var response_code := int(response[1])
	var response_text := (response[3] as PackedByteArray).get_string_from_utf8()
	if result != HTTPRequest.RESULT_SUCCESS:
		return {
			"ok": false,
			"message": _http_request_failure_message(result, url),
			"retryable": true,
			"status_code": response_code,
		}
	var parsed = JSON.parse_string(response_text)
	if response_code < 200 or response_code >= 300:
		var detail := str(parsed.get("message", "")) if parsed is Dictionary else ""
		if detail.is_empty():
			detail = "HTTP %d" % response_code
		return {
			"ok": false,
			"message": detail,
			"retryable": bool(parsed.get("retryable", response_code in [408, 425, 429, 500, 502, 503, 504])) if parsed is Dictionary else response_code in [408, 425, 429, 500, 502, 503, 504],
			"status_code": response_code,
		}
	if not parsed is Dictionary or str(parsed.get("status", "")) != "ok":
		return {
			"ok": false,
			"message": str(parsed.get("message", response_text)) if parsed is Dictionary else response_text,
			"retryable": true,
			"status_code": response_code,
		}
	return {"ok": true, "data": parsed.get("data", parsed), "status_code": response_code}

func _http_request_failure_message(result: int, url: String) -> String:
	match result:
		HTTPRequest.RESULT_CANT_CONNECT:
			return "无法连接 Companion Core；请确认本地服务已启动"
		HTTPRequest.RESULT_CANT_RESOLVE:
			return "无法解析 Companion Core 地址"
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "Companion Core 连接中断"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "Companion Core TLS 握手失败"
		HTTPRequest.RESULT_NO_RESPONSE:
			return "Companion Core 没有返回响应"
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
			return "Companion Core 响应超过大小限制"
		HTTPRequest.RESULT_BODY_DECOMPRESS_FAILED:
			return "Companion Core 响应解压失败"
		HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED:
			return "Companion Core 请求重定向次数过多"
		HTTPRequest.RESULT_TIMEOUT:
			if url.begins_with("http://127.0.0.1") or url.begins_with("http://localhost"):
				return "Companion Core 请求超时；Core 可能正在等待上游模型，请检查网络代理和模型服务"
			return "网络请求超时；请检查代理与服务地址"
		_:
			return "Companion Core 网络请求失败（%d）" % result

func _set_active(active: bool, message: String) -> void:
	var changed := active != _active
	_active = active
	health_changed.emit(active, message)
	if not changed:
		return
	if active:
		connected.emit()
	else:
		disconnected.emit()

func _emit_new_request_error(request_id: String, message: String, retryable: bool) -> void:
	request_failed.emit(request_id, message, retryable)
	error_received.emit(message)

func _invalidate_monitor_requests() -> void:
	_monitor_generation += 1
	_health_request_in_flight = false
	_memory_request_in_flight = false
	_memory_elapsed = 0.0

func _is_valid_save_id(value: String) -> bool:
	if value.is_empty() or value.length() > 64:
		return false
	for index in value.length():
		var code := value.unicode_at(index)
		var is_ascii_letter := (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
		var is_ascii_digit := code >= 48 and code <= 57
		if is_ascii_letter or is_ascii_digit:
			continue
		if index > 0 and code in [45, 95]:
			continue
		return false
	return true

func _is_valid_request_id(value: String) -> bool:
	if value.is_empty() or value.length() > 128:
		return false
	for index in value.length():
		var code := value.unicode_at(index)
		var is_ascii_letter := (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
		var is_ascii_digit := code >= 48 and code <= 57
		if is_ascii_letter or is_ascii_digit:
			continue
		if index > 0 and code in [45, 46, 58, 95]:
			continue
		return false
	return true

func _sync_save_id_from_global() -> void:
	var tree := get_tree()
	if not tree:
		return
	var global_node := tree.root.get_node_or_null("Global")
	if global_node and global_node.has_method("get_active_save_id"):
		set_save_id(str(global_node.call("get_active_save_id")))

func _url(path: String) -> String:
	return _base_url + (path if path.begins_with("/") else "/" + path)

func _load_base_url() -> void:
	var environment_url := OS.get_environment("SPRING_HAVEN_CORE_URL").strip_edges()
	if not environment_url.is_empty():
		set_base_url(environment_url)

func _load_core_key() -> void:
	var environment_key := OS.get_environment("SPRING_HAVEN_CORE_KEY").strip_edges()
	if environment_key.is_empty():
		# Backward-compatible alias used by early Spring Heaven builds.
		environment_key = OS.get_environment("SPRING_HEAVEN_CORE_KEY").strip_edges()
	if not environment_key.is_empty():
		set_core_key(environment_key)
		return
	var user_key_path := CORE_KEY_FILE
	if FileAccess.file_exists(user_key_path):
		set_core_key(FileAccess.get_file_as_string(user_key_path))
