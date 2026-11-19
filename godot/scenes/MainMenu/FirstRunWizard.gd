class_name FirstRunWizard
extends Control

## 首次启动配置向导:三步把"没有模型"的新用户带到能对话。
## 步骤1 欢迎 → 步骤2 配置(预设四选 + 免保存直测连接) → 步骤3 完成。
## 骨架照 SettingsPanel._build_shell 的"实心 scrim + 居中卡片 + 入场 tween"
## 模式复刻;测试/保存走 CompanionCore 既有端点,Key 只进 DPAPI 持久化。

signal wizard_completed

const PRESETS := {
	"OpenAI": {"base_url": "https://api.openai.com/v1", "model": "gpt-4o-mini"},
	"DeepSeek": {"base_url": "https://api.deepseek.com/v1", "model": "deepseek-chat"},
	"LM Studio": {"base_url": "http://127.0.0.1:1234/v1", "model": "local-model"},
	"自定义": {},
}

const CARD_SIZE := Vector2(620, 460)

var _scrim: ColorRect
var _card: PanelContainer
var _step_container: VBoxContainer
var _step := 1
var _selected_preset := "DeepSeek"
var _base_url_input: LineEdit
var _model_input: LineEdit
var _api_key_input: LineEdit
var _key_visibility_button: Button
var _test_button: Button
var _test_status: Label
var _testing := false
var _last_test_passed := false


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_shell()
	_build_step_content()


func open_wizard() -> void:
	_step = 1
	_selected_preset = "DeepSeek"
	_apply_preset("DeepSeek")
	# 首次打开时 _test_status 尚未创建(步骤2才建);判空防崩,否则
	# visible=true 永远执行不到,向导整体不出现(实拍复验发现的真 bug)。
	if is_instance_valid(_test_status):
		_test_status.text = ""
	_rebuild_step()
	visible = true
	_apply_panel_style()
	modulate.a = 0.0
	_card.pivot_offset = _card.size / 2.0
	_card.scale = Vector2(0.97, 0.97)
	var tween := create_tween().set_parallel(true)
	tween.tween_property(self, "modulate:a", 1.0, 0.24).set_ease(Tween.EASE_OUT)
	tween.tween_property(_card, "scale", Vector2.ONE, 0.32).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)


func close_wizard() -> void:
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 0.18)
	await tween.finished
	visible = false


func _build_shell() -> void:
	_scrim = ColorRect.new()
	_scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scrim.color = Color(str(ThemeMgr.get_current_theme_data().bg))
	_scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_scrim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_card = PanelContainer.new()
	_card.custom_minimum_size = CARD_SIZE
	_card.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(_card)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_right", 28)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_bottom", 22)
	_card.add_child(margin)

	_step_container = VBoxContainer.new()
	_step_container.add_theme_constant_override("separation", 10)
	margin.add_child(_step_container)


func _build_step_content() -> void:
	_rebuild_step()


func _rebuild_step() -> void:
	for child in _step_container.get_children():
		child.queue_free()
	match _step:
		1: _build_step_welcome()
		2: _build_step_configure()
		3: _build_step_done()
	_apply_panel_style()


func _step_header() -> Label:
	var header := Label.new()
	match _step:
		1: header.text = "欢迎来到春日庭院"
		2: header.text = "配置对话模型"
		_: header.text = "一切就绪"
	header.add_theme_font_size_override("font_size", 22)
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_theme_color_override(
		"font_color", Color(ThemeMgr.get_current_theme_data().primary)
	)
	_step_container.add_child(header)
	var steps := Label.new()
	steps.text = "步骤 %d / 3" % _step
	steps.add_theme_font_size_override("font_size", 12)
	steps.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	steps.add_theme_color_override(
		"font_color", Color(ThemeMgr.get_current_theme_data().secondary, 0.8)
	)
	_step_container.add_child(steps)
	return header


func _build_step_welcome() -> void:
	_step_header()
	var intro := Label.new()
	intro.text = "和小玲、小奈、汐汐对话需要一个 OpenAI-compatible 聊天模型。\n只需配置一次,密钥由当前 Windows 用户的 DPAPI 加密保存,\n不会写进游戏目录,也不会在界面上回显。"
	intro.add_theme_font_size_override("font_size", 13)
	intro.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_step_container.add_child(intro)
	_step_container.add_child(_spacer())
	var presets_row := HBoxContainer.new()
	presets_row.alignment = BoxContainer.ALIGNMENT_CENTER
	presets_row.add_theme_constant_override("separation", 8)
	_step_container.add_child(presets_row)
	for preset_name in PRESETS:
		var button := Button.new()
		button.text = str(preset_name)
		button.toggle_mode = true
		button.custom_minimum_size = Vector2(118, 40)
		button.button_pressed = str(preset_name) == _selected_preset
		button.pressed.connect(_on_preset_pressed.bind(str(preset_name), button))
		presets_row.add_child(button)
	_apply_preset_button_styles(presets_row)
	_step_container.add_child(_spacer())
	_step_container.add_child(_nav_row(["下一步 →"], [_on_next_pressed]))


func _build_step_configure() -> void:
	_step_header()
	var form := GridContainer.new()
	form.columns = 2
	form.add_theme_constant_override("h_separation", 12)
	form.add_theme_constant_override("v_separation", 10)
	_step_container.add_child(form)

	var base_url_label := Label.new()
	base_url_label.text = "Base URL"
	form.add_child(base_url_label)
	_base_url_input = LineEdit.new()
	_base_url_input.placeholder_text = "https://api.deepseek.com/v1"
	_base_url_input.custom_minimum_size = Vector2(320, 34)
	form.add_child(_base_url_input)

	var model_label := Label.new()
	model_label.text = "模型名"
	form.add_child(model_label)
	_model_input = LineEdit.new()
	_model_input.placeholder_text = "deepseek-chat"
	_model_input.custom_minimum_size = Vector2(320, 34)
	form.add_child(_model_input)

	var key_label := Label.new()
	key_label.text = "API Key"
	form.add_child(key_label)
	var key_row := HBoxContainer.new()
	key_row.add_theme_constant_override("separation", 6)
	form.add_child(key_row)
	_api_key_input = LineEdit.new()
	_api_key_input.secret = true
	_api_key_input.placeholder_text = "粘贴你的密钥(本地 LM Studio 可留空)"
	_api_key_input.custom_minimum_size = Vector2(252, 34)
	_api_key_input.text_changed.connect(func(_t: String) -> void: _clear_test_status())
	key_row.add_child(_api_key_input)
	_key_visibility_button = Button.new()
	_key_visibility_button.text = "👁"
	_key_visibility_button.tooltip_text = "显示/隐藏密钥"
	_key_visibility_button.custom_minimum_size = Vector2(34, 34)
	_key_visibility_button.pressed.connect(_on_key_visibility_pressed)
	key_row.add_child(_key_visibility_button)

	var preset: Dictionary = PRESETS.get(_selected_preset, {})
	_base_url_input.text = str(preset.get("base_url", ""))
	_model_input.text = str(preset.get("model", ""))

	var test_row := HBoxContainer.new()
	test_row.add_theme_constant_override("separation", 10)
	_step_container.add_child(test_row)
	_test_button = Button.new()
	_test_button.text = "🔌 测试连接"
	_test_button.custom_minimum_size = Vector2(128, 36)
	_test_button.pressed.connect(_on_test_pressed)
	test_row.add_child(_test_button)
	_test_status = Label.new()
	_test_status.add_theme_font_size_override("font_size", 12)
	_test_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_test_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	test_row.add_child(_test_status)

	_step_container.add_child(_spacer())
	_step_container.add_child(_nav_row(["← 上一步", "完成 →"], [_on_back_pressed, _on_finish_pressed]))
	_apply_input_styles()


func _build_step_done() -> void:
	_step_header()
	var check := Label.new()
	check.text = "✓"
	check.add_theme_font_size_override("font_size", 64)
	check.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	check.add_theme_color_override("font_color", ThemeMgr.semantic("success"))
	_step_container.add_child(check)
	var done := Label.new()
	done.text = "连接成功!现在就能和小玲、小奈、汐汐对话了。\n祝你在春日庭院住得愉快。"
	done.add_theme_font_size_override("font_size", 14)
	done.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_step_container.add_child(done)
	_step_container.add_child(_spacer())
	_step_container.add_child(_nav_row(["开始体验 →"], [_on_start_experience_pressed]))


# ── 交互 ─────────────────────────────────────────────

func _on_preset_pressed(preset_name: String, button: Button) -> void:
	_selected_preset = preset_name
	_apply_preset(preset_name)
	for sibling in button.get_parent().get_children():
		if sibling is Button:
			(sibling as Button).button_pressed = sibling == button
	_clear_test_status()


func _apply_preset(preset_name: String) -> void:
	var preset: Dictionary = PRESETS.get(preset_name, {})
	if not is_instance_valid(_base_url_input):
		return
	_base_url_input.text = str(preset.get("base_url", ""))
	_model_input.text = str(preset.get("model", ""))


func _on_key_visibility_pressed() -> void:
	_api_key_input.secret = not _api_key_input.secret
	_key_visibility_button.text = "👁" if _api_key_input.secret else "🙈"


func _clear_test_status() -> void:
	if is_instance_valid(_test_status):
		_test_status.text = ""
		_test_status.add_theme_color_override(
			"font_color", Color(ThemeMgr.get_current_theme_data().secondary)
		)


func _on_test_pressed() -> void:
	await _run_draft_test()


func _run_draft_test() -> bool:
	"""免保存直测:用表单当前值打一次真实诊断,返回是否通过。"""
	if _testing:
		return _last_test_passed
	var base_url := _base_url_input.text.strip_edges()
	var model := _model_input.text.strip_edges()
	var api_key := _api_key_input.text.strip_edges()
	if base_url.is_empty() or model.is_empty():
		_set_test_status("请先填写 Base URL 和模型名", false)
		_last_test_passed = false
		return false
	_testing = true
	_test_button.disabled = true
	_test_button.text = "测试中…"
	_set_test_status("正在连接…", true)
	var result: Dictionary = await CompanionCore.diagnose_provider_draft(
		"chat", base_url, model, api_key
	)
	_testing = false
	_test_button.disabled = false
	_test_button.text = "🔌 测试连接"
	if bool(result.get("ok", false)):
		var data: Dictionary = result.get("data", {})
		var elapsed := int(data.get("latency_ms", 0))
		var tested_model := str(data.get("model", model))
		_set_test_status("✓ 连接正常 · %d ms · %s" % [elapsed, tested_model], true)
		_last_test_passed = true
	else:
		_set_test_status("✗ " + str(result.get("message", "连接失败")), false)
		_last_test_passed = false
	return _last_test_passed


func _set_test_status(message: String, positive: bool) -> void:
	if not is_instance_valid(_test_status):
		return
	_test_status.text = message
	if positive:
		_test_status.add_theme_color_override("font_color", ThemeMgr.semantic("success"))
	else:
		_test_status.add_theme_color_override("font_color", ThemeMgr.semantic("danger"))


func _on_next_pressed() -> void:
	_step = 2
	_rebuild_step()


func _on_back_pressed() -> void:
	_step = 1
	_rebuild_step()


func _on_finish_pressed() -> void:
	# 完成前强制跑一次免保存直测并通过——避免把坏配置固化进 DPAPI。
	var base_url := _base_url_input.text.strip_edges()
	var model := _model_input.text.strip_edges()
	var api_key := _api_key_input.text.strip_edges()
	if base_url.is_empty() or model.is_empty():
		_set_test_status("请先填写 Base URL 和模型名", false)
		return
	var passed := await _run_draft_test()
	if not passed:
		return
	var result: Dictionary = await CompanionCore.configure_provider(
		base_url, model, api_key
	)
	if bool(result.get("ok", false)):
		_step = 3
		_rebuild_step()
	else:
		_set_test_status("保存失败: " + str(result.get("message", "")), false)


func _on_start_experience_pressed() -> void:
	wizard_completed.emit()
	close_wizard()


# ── 样式辅助(视觉语言与 SettingsPanel/MainMenu 对齐) ─────────────

func _spacer() -> Control:
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return spacer


func _nav_row(labels: Array, callbacks: Array) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	for index in labels.size():
		var button := Button.new()
		button.text = str(labels[index])
		button.custom_minimum_size = Vector2(140, 40)
		button.pressed.connect(callbacks[index])
		row.add_child(button)
	_apply_nav_style(row)
	return row


func _apply_preset_button_styles(row: HBoxContainer) -> void:
	var data := ThemeMgr.get_current_theme_data()
	for child in row.get_children():
		if child is Button:
			var button := child as Button
			var active := button.button_pressed
			button.add_theme_color_override(
				"font_color",
				Color(str(data.primary)) if active else Color(str(data.text))
			)
			var style := StyleBoxFlat.new()
			style.set_corner_radius_all(28)
			style.content_margin_left = 12.0
			style.content_margin_right = 12.0
			style.bg_color = (
				Color(str(data.primary), 0.16) if active
				else Color(str(data.bg), 0.0)
			)
			if active:
				style.border_color = Color(str(data.primary), 0.9)
				style.set_border_width_all(1)
			button.add_theme_stylebox_override("normal", style)
			button.add_theme_stylebox_override("hover", style)
			button.add_theme_stylebox_override("pressed", style)


func _apply_nav_style(row: HBoxContainer) -> void:
	var data := ThemeMgr.get_current_theme_data()
	for child in row.get_children():
		if child is Button:
			var button := child as Button
			button.add_theme_font_size_override("font_size", 14)
			button.add_theme_color_override(
				"font_color",
				Color(str(data.bg)) if bool(data.is_dark) else Color.WHITE
			)
			var style := StyleBoxFlat.new()
			style.set_corner_radius_all(28)
			style.bg_color = Color(str(data.primary))
			style.content_margin_left = 18.0
			style.content_margin_right = 18.0
			button.add_theme_stylebox_override("normal", style)
			button.add_theme_stylebox_override("hover", style)
			button.add_theme_stylebox_override("pressed", style)


func _apply_input_styles() -> void:
	var data := ThemeMgr.get_current_theme_data()
	for input in [_base_url_input, _model_input, _api_key_input]:
		if is_instance_valid(input):
			(input as LineEdit).add_theme_font_size_override("font_size", 13)


func _apply_panel_style() -> void:
	var data := ThemeMgr.get_current_theme_data()
	var style := StyleBoxFlat.new()
	style.set_corner_radius_all(18)
	style.bg_color = Color(str(data.bg)).lightened(0.035 if bool(data.is_dark) else -0.02)
	style.border_color = Color(str(data.primary), 0.32)
	style.set_border_width_all(1)
	_card.add_theme_stylebox_override("panel", style)
