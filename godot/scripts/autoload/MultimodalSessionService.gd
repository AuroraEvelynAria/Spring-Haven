extends Node

signal session_state_changed(state: Dictionary)
signal vision_description_ready(request_id: String, role: String, description: String)
signal tts_audio_ready(request_id: String, role: String, audio: PackedByteArray, mime_type: String)
signal multimodal_request_failed(request_id: String, message: String)

const FRAME_ROOT := "user://SpringHaven/multimodal_frames"
const TEXT_SANITIZER := preload("res://scripts/domain/TextSanitizer.gd")
const TTS_TIMEOUT_SECONDS := 45.0
const VALID_MODES := ["video_call", "desktop_companion"]

var _mode := ""
var _roles: Array[String] = []
var _screen_context_permission := false
var _tts_base_url := ""
var _tts_model := ""
var _tts_voices := {"ling": "", "nai": ""}
var _tts_environment_overrides := {"ling": false, "nai": false}

func _ready() -> void:
	if is_instance_valid(Settings) and Settings.has_method("get_tts_voices"):
		var saved_voices: Dictionary = Settings.get_tts_voices()
		for role in ["ling", "nai"]:
			_tts_voices[role] = str(saved_voices.get(role, "")).strip_edges()
	_tts_base_url = OS.get_environment("SPRING_HEAVEN_TTS_URL").strip_edges().trim_suffix("/")
	_tts_model = OS.get_environment("SPRING_HEAVEN_TTS_MODEL").strip_edges()
	var environment_ling_voice := OS.get_environment("SPRING_HEAVEN_TTS_LING_VOICE").strip_edges()
	var environment_nai_voice := OS.get_environment("SPRING_HEAVEN_TTS_NAI_VOICE").strip_edges()
	if not environment_ling_voice.is_empty():
		_tts_voices["ling"] = environment_ling_voice
		_tts_environment_overrides["ling"] = true
	if not environment_nai_voice.is_empty():
		_tts_voices["nai"] = environment_nai_voice
		_tts_environment_overrides["nai"] = true

func start_session(mode: String, roles: Array[String]) -> Dictionary:
	if mode not in VALID_MODES:
		return {"ok": false, "message": "未知多模态会话模式"}
	var normalized_roles: Array[String] = []
	for role_variant in roles:
		var role := str(role_variant)
		if role in ["ling", "nai"] and role not in normalized_roles:
			normalized_roles.append(role)
	if normalized_roles.is_empty():
		return {"ok": false, "message": "多模态会话至少需要一个角色"}
	_mode = mode
	_roles = normalized_roles
	_screen_context_permission = false
	var state := get_session_state()
	session_state_changed.emit(state.duplicate(true))
	return {"ok": true, "state": state}

func end_session() -> void:
	_mode = ""
	_roles.clear()
	_screen_context_permission = false
	session_state_changed.emit(get_session_state())

func set_screen_context_permission(enabled: bool) -> void:
	# Permission is intentionally memory-only and resets on every session/app launch.
	_screen_context_permission = enabled and not _mode.is_empty()
	session_state_changed.emit(get_session_state())

func configure_tts(base_url: String, model: String, voices: Dictionary = {}) -> void:
	_tts_base_url = base_url.strip_edges().trim_suffix("/")
	_tts_model = model.strip_edges()
	set_tts_voices(voices)

func set_tts_voices(voices: Dictionary) -> void:
	for role in ["ling", "nai"]:
		if voices.has(role) and not bool(_tts_environment_overrides.get(role, false)):
			_tts_voices[role] = str(voices[role]).replace(String.chr(0), " ").strip_edges().left(512)

func get_session_state() -> Dictionary:
	return {
		"active": not _mode.is_empty(),
		"mode": _mode,
		"roles": _roles.duplicate(),
		"screen_context_permission": _screen_context_permission,
		"capabilities": get_capabilities(),
	}

func get_capabilities() -> Dictionary:
	return {
		"vision_configured": Vision.is_configured(),
		"tts_configured": is_tts_configured(),
		"camera_capture_implemented": false,
		"microphone_capture_implemented": false,
		"automatic_screen_capture_implemented": false,
		"manual_frame_submission": true,
	}

func is_tts_configured() -> bool:
	return CompanionCore.is_provider_configured("tts") or (
		not _tts_base_url.is_empty() and not _tts_model.is_empty()
	)

func submit_visual_frame(
	image: Image,
	role: String,
	source: String,
	symbolic_context: Dictionary = {}
) -> Dictionary:
	var request_id := Global.new_local_id("vision")
	if _mode.is_empty() or role not in _roles:
		return _failure(request_id, "当前角色不在活动多模态会话中")
	if source not in ["camera", "screen", "scene"]:
		return _failure(request_id, "未知视觉帧来源")
	if source == "screen" and not _screen_context_permission:
		return _failure(request_id, "屏幕内容尚未获得本次会话授权")
	if image == null or image.is_empty():
		return _failure(request_id, "视觉帧为空")
	if not Vision.is_configured():
		var discovery := await Vision.discover_model()
		if not bool(discovery.get("ok", false)):
			return _failure(request_id, str(discovery.get("message", "LM Studio 视觉模型尚未配置")))
	var absolute_root := ProjectSettings.globalize_path(FRAME_ROOT)
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute_root)
	if directory_error not in [OK, ERR_ALREADY_EXISTS]:
		return _failure(request_id, error_string(directory_error))
	var path := FRAME_ROOT.path_join("%s.png" % request_id.validate_filename())
	var save_error := image.save_png(path)
	if save_error != OK:
		return _failure(request_id, error_string(save_error))
	var trusted_context := symbolic_context.duplicate(true)
	trusted_context["frame_source"] = source
	trusted_context["role_id"] = role
	var result: Dictionary = await Vision.describe_image(path, trusted_context)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if not bool(result.get("ok", false)):
		return _failure(request_id, str(result.get("message", "视觉转述失败")))
	var description := str(result.get("text", "")).strip_edges()
	vision_description_ready.emit(request_id, role, description)
	return {"ok": true, "request_id": request_id, "description": description}

func synthesize_speech(text: String, role: String) -> Dictionary:
	var request_id := Global.new_local_id("tts")
	var normalized_text := TEXT_SANITIZER.strip_nul(text).strip_edges().left(4000)
	if role not in ["ling", "nai"]:
		return _failure(request_id, "未知 TTS 角色")
	if normalized_text.is_empty():
		return _failure(request_id, "TTS 文本为空")
	if CompanionCore.is_provider_configured("tts"):
		var core_result: Dictionary = await CompanionCore.synthesize_speech(
			normalized_text,
			str(_tts_voices.get(role, "")),
			"wav",
			1.0
		)
		if not bool(core_result.get("ok", false)):
			return _failure(request_id, str(core_result.get("message", "Companion Core TTS 请求失败")))
		var core_audio: PackedByteArray = core_result.get("audio", PackedByteArray())
		var core_mime := str(core_result.get("mime_type", "audio/wav"))
		tts_audio_ready.emit(request_id, role, core_audio, core_mime)
		return {
			"ok": true,
			"request_id": request_id,
			"audio": core_audio,
			"mime_type": core_mime,
			"provider": "companion_core",
		}
	if not is_tts_configured():
		return _failure(request_id, "TTS 服务尚未配置")
	var payload := {
		"model": _tts_model,
		"input": normalized_text,
		"voice": str(_tts_voices.get(role, "")),
		"response_format": "wav",
	}
	var response := await _post_audio(_tts_base_url + "/audio/speech", payload)
	if not bool(response.get("ok", false)):
		return _failure(request_id, str(response.get("message", "TTS 请求失败")))
	var audio: PackedByteArray = response.get("audio", PackedByteArray())
	tts_audio_ready.emit(request_id, role, audio, "audio/wav")
	return {
		"ok": true,
		"request_id": request_id,
		"audio": audio,
		"mime_type": "audio/wav",
	}

func _post_audio(url: String, payload: Dictionary) -> Dictionary:
	var request := HTTPRequest.new()
	request.timeout = TTS_TIMEOUT_SECONDS
	add_child(request)
	var error := request.request(
		url,
		PackedStringArray(["Content-Type: application/json"]),
		HTTPClient.METHOD_POST,
		JSON.stringify(payload)
	)
	if error != OK:
		request.queue_free()
		return {"ok": false, "message": error_string(error)}
	var response: Array = await request.request_completed
	request.queue_free()
	if response.size() < 4 or int(response[0]) != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "message": "TTS 网络请求失败"}
	var status := int(response[1])
	var body: PackedByteArray = response[3]
	if status < 200 or status >= 300:
		return {"ok": false, "message": body.get_string_from_utf8().left(500)}
	if body.is_empty():
		return {"ok": false, "message": "TTS 返回空音频"}
	return {"ok": true, "audio": body}

func _failure(request_id: String, message: String) -> Dictionary:
	multimodal_request_failed.emit(request_id, message)
	return {"ok": false, "request_id": request_id, "message": message}
