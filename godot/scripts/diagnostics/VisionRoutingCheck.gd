extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	await process_frame
	var vision := root.get_node_or_null("Vision")
	if vision == null:
		_fail("Vision autoload 不存在")
		return
	var original_url := str(vision.get("base_url"))
	var original_model := str(vision.get("model"))
	var original_preference := str(vision.get("backend_preference"))
	vision.call("configure", "http://127.0.0.1:1234/v1", "diagnostic-local-vision")
	var local_status: Dictionary = vision.call("get_backend_status", "local")
	_expect(str(local_status.get("mode", "")) == "local", "local 模式没有选择 LM Studio")
	_expect(str(local_status.get("provider", "")) == "lm_studio", "local Provider 标记错误")
	_expect(str(local_status.get("model", "")) == "diagnostic-local-vision", "local 模型状态错误")
	vision.call("set_backend_preference", "invalid-mode")
	_expect(str(vision.get("backend_preference")) == "auto", "非法模式没有回退到 auto")
	vision.call("set_backend_preference", "api")
	_expect(str(vision.get("backend_preference")) == "api", "api 偏好没有保存到运行时")
	vision.call("configure", original_url, original_model)
	vision.call("set_backend_preference", original_preference)
	print("VISION_ROUTING_CHECK=PASS")
	quit(0)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _fail(message: String) -> void:
	printerr("VISION_ROUTING_CHECK failure=", message)
	quit(1)
