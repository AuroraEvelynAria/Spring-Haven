extends SceneTree

var _failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	await process_frame
	var scene := load("res://scenes/Settings/SettingsPanel.tscn") as PackedScene
	_expect(scene != null, "设置面板场景无法加载")
	if scene == null:
		_finish()
		return
	var panel := scene.instantiate()
	root.add_child(panel)
	panel.show_panel()
	panel.call("_switch_settings_category", "ai")
	await _wait_for_provider_data(panel)
	_expect_loaded_provider_values(panel)

	# Reproduce the old failure: leave the page while a Core request is in flight.
	panel.call("_refresh_provider_status")
	panel.call("_switch_settings_category", "general")
	await _wait_for_provider_idle(panel)
	panel.call("_switch_settings_category", "ai")
	await process_frame
	_expect_loaded_provider_values(panel)
	panel.queue_free()
	await process_frame
	_finish()

func _wait_for_provider_data(panel: Node) -> void:
	var deadline := Time.get_ticks_msec() + 10000
	while (
		(panel.get("_provider_status_data") as Dictionary).is_empty()
		and Time.get_ticks_msec() < deadline
	):
		await process_frame
	_expect(not (panel.get("_provider_status_data") as Dictionary).is_empty(), "读取 Provider 设置超时")
	await _wait_for_provider_idle(panel)

func _wait_for_provider_idle(panel: Node) -> void:
	var deadline := Time.get_ticks_msec() + 10000
	while bool(panel.get("_provider_busy")) and Time.get_ticks_msec() < deadline:
		await process_frame
	_expect(not bool(panel.get("_provider_busy")), "Provider 请求没有结束")

func _expect_loaded_provider_values(panel: Node) -> void:
	var status: Dictionary = panel.get("_provider_status_data")
	_expect(not status.is_empty(), "设置面板没有取得持久化 Provider 状态")
	var base_input := panel.get("_provider_base_url_input") as LineEdit
	var model_input := panel.get("_provider_model_input") as LineEdit
	_expect(base_input != null and model_input != null, "AI 设置控件没有重建")
	if base_input != null:
		_expect(base_input.text == str(status.get("base_url", "")), "聊天 Base URL 没有回填持久化值")
	if model_input != null:
		_expect(model_input.text == str(status.get("model", "")), "聊天模型没有回填持久化值")
	var profiles = status.get("profiles", {})
	var controls: Dictionary = panel.get("_provider_profile_controls")
	for capability in ["vision", "embedding", "rerank"]:
		var profile = (profiles as Dictionary).get(capability, {}) if profiles is Dictionary else {}
		var capability_controls = controls.get(capability, {})
		_expect(profile is Dictionary and not (profile as Dictionary).is_empty(), "%s 持久化配置缺失" % capability)
		_expect(capability_controls is Dictionary and not (capability_controls as Dictionary).is_empty(), "%s 控件缺失" % capability)
		if profile is Dictionary and capability_controls is Dictionary and not (capability_controls as Dictionary).is_empty():
			var capability_base := (capability_controls as Dictionary).get("base_url") as LineEdit
			var capability_model := (capability_controls as Dictionary).get("model") as LineEdit
			_expect(capability_base != null and capability_base.text == str((profile as Dictionary).get("base_url", "")), "%s Base URL 回填错误" % capability)
			_expect(capability_model != null and capability_model.text == str((profile as Dictionary).get("model", "")), "%s 模型回填错误" % capability)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _finish() -> void:
	if _failures.is_empty():
		print("PROVIDER_SETTINGS_PERSISTENCE_CHECK=PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("PROVIDER_SETTINGS_PERSISTENCE_CHECK failure=", failure)
	quit(1)
