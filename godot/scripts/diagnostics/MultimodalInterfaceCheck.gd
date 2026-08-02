extends Node

var _checks := 0
var _failures: Array[String] = []

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var start: Dictionary = Multimodal.start_session("desktop_companion", ["ling"])
	_expect(bool(start.get("ok", false)), "桌宠多模态会话无法启动")
	var state := Multimodal.get_session_state()
	_expect(bool(state.active), "多模态会话未标记活动")
	_expect(str(state.mode) == "desktop_companion", "多模态会话模式错误")
	_expect(not bool(state.screen_context_permission), "屏幕权限不应默认开启")
	_expect(bool(state.capabilities.manual_frame_submission), "未开放手动视觉帧接口")
	_expect(not bool(state.capabilities.automatic_screen_capture_implemented), "不应默认实现自动截屏")

	var image := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	image.fill(Color("5f7d8a"))
	var denied: Dictionary = await Multimodal.submit_visual_frame(image, "ling", "screen")
	_expect(not bool(denied.get("ok", true)), "未授权屏幕帧被接受")
	_expect("尚未获得" in str(denied.get("message", "")), "屏幕权限拒绝原因错误")
	Multimodal.set_screen_context_permission(true)
	_expect(bool(Multimodal.get_session_state().screen_context_permission), "屏幕权限无法显式开启")

	Multimodal.configure_tts(
		"http://127.0.0.1:1234/v1",
		"future-tts-model",
		{"ling": "ling_voice", "nai": "nai_voice"}
	)
	_expect(Multimodal.is_tts_configured(), "TTS OpenAI 兼容接口无法配置")
	var invalid_tts: Dictionary = await Multimodal.synthesize_speech("", "ling")
	_expect(not bool(invalid_tts.get("ok", true)), "空 TTS 文本被接受")

	Multimodal.end_session()
	state = Multimodal.get_session_state()
	_expect(not bool(state.active), "多模态会话无法结束")
	_expect(not bool(state.screen_context_permission), "结束会话后屏幕权限未撤销")
	if _failures.is_empty():
		print("MULTIMODAL_INTERFACE_CHECK passed=", _checks)
		get_tree().quit(0)
		return
	for failure in _failures:
		printerr("MULTIMODAL_INTERFACE_CHECK failure=", failure)
	get_tree().quit(1)

func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
