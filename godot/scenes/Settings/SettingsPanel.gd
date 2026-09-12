extends Control

signal closed

const GLASS_SHADER := preload("res://shaders/glass.gdshader")
const KIT := preload("res://scenes/Settings/sections/SettingsUIKit.gd")
const SECTION_ADVANCED := preload("res://scenes/Settings/sections/SettingsSectionAdvanced.gd")
const SECTION_KNOWLEDGE := preload("res://scenes/Settings/sections/SettingsSectionKnowledge.gd")
const SECTION_PROVIDER := preload("res://scenes/Settings/sections/SettingsSectionProvider.gd")
const SECTION_GENERAL := preload("res://scenes/Settings/sections/SettingsSectionGeneral.gd")
const SETTINGS_CATEGORIES := [
	{"id": "general", "icon": "🎨", "label": "体验"},
	{"id": "ai", "icon": "✨", "label": "AI 服务"},
	{"id": "knowledge", "icon": "📚", "label": "记忆与知识"},
	{"id": "life", "icon": "🌿", "label": "生活与世界"},
	{"id": "advanced", "icon": "🧰", "label": "高级"},
]
const SETTINGS_SUBCATEGORIES := {
	"general": [
		{"id": "appearance", "label": "主题与颜色"},
		{"id": "window_audio", "label": "窗口与声音"},
		{"id": "readability", "label": "字体与可读性"},
	],
	"ai": [
		{"id": "chat", "label": "对话模型"},
		{"id": "capabilities", "label": "能力模型"},
		{"id": "fallbacks", "label": "备用模型"},
		{"id": "network", "label": "网络与代理"},
	],
	"knowledge": [
		{"id": "retrieval", "label": "检索设置"},
		{"id": "documents", "label": "文档管理"},
		{"id": "editor", "label": "文档编辑"},
		{"id": "test", "label": "检索测试"},
	],
	"life": [
		{"id": "autonomy", "label": "自主生活"},
		{"id": "presentation", "label": "2D 舞台"},
	],
	"advanced": [
		{"id": "reliability", "label": "可靠性"},
		{"id": "state", "label": "当前状态"},
		{"id": "runtime", "label": "运行参数"},
		{"id": "interaction", "label": "互动数值"},
	],
}
const DEFAULT_SETTINGS_SUBCATEGORIES := {
	"general": "appearance",
	"ai": "chat",
	"knowledge": "retrieval",
	"life": "autonomy",
	"advanced": "reliability",
}
var _scrim: ColorRect
var _panel: PanelContainer
var _content: VBoxContainer
var _developer_discard_dialog: ConfirmationDialog
var _settings_category := "general"
var _settings_subcategory := "appearance"
var _settings_subcategory_by_category: Dictionary = DEFAULT_SETTINGS_SUBCATEGORIES.duplicate(true)
var _category_drafts: Dictionary = {}
var _category_buttons: Dictionary = {}
var _subcategory_buttons: Dictionary = {}
var _advanced: SECTION_ADVANCED
var _knowledge: SECTION_KNOWLEDGE
var _provider: SECTION_PROVIDER
var _general: SECTION_GENERAL

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_advanced = SECTION_ADVANCED.new()
	_advanced.prepare(self)
	_advanced.request_rebuild = _rebuild_content
	_knowledge = SECTION_KNOWLEDGE.new()
	_knowledge.prepare(self)
	_knowledge.is_panel_category = _is_panel_category
	_provider = SECTION_PROVIDER.new()
	_provider.prepare(self)
	_provider.is_panel_category = _is_panel_category
	_provider.capture_category_draft = _capture_visible_category_draft
	_provider.restore_category_draft = _restore_visible_category_draft
	_provider.request_rebuild = _rebuild_content
	_provider.on_status_loaded = _forward_provider_status
	_general = SECTION_GENERAL.new()
	_general.prepare(self)
	_build_shell()
	_build_developer_discard_dialog()
	get_viewport().size_changed.connect(_update_panel_size)
	hide()
	Global.theme_changed.connect(_on_theme_changed)

func show_panel(initial_category: String = "") -> void:
	if initial_category == "interaction":
		_settings_category = "advanced"
		_settings_subcategory_by_category["advanced"] = "interaction"
	elif initial_category in DEFAULT_SETTINGS_SUBCATEGORIES:
		_settings_category = initial_category
	_settings_subcategory = str(_settings_subcategory_by_category.get(
		_settings_category, DEFAULT_SETTINGS_SUBCATEGORIES.get(_settings_category, "")
	))
	_advanced.reset_for_show(Settings.get_interaction_scope_save_id())
	_provider.reset_for_show("")
	_knowledge.reset_for_show("")
	_category_drafts.clear()
	_rebuild_content()
	show()
	_provider.refresh_status.call_deferred()
	modulate.a = 0.0
	_panel.scale = Vector2(0.97, 0.97)
	_panel.pivot_offset = _panel.size / 2.0
	var tween := create_tween().set_parallel(true)
	tween.tween_property(self, "modulate:a", 1.0, 0.24).set_ease(Tween.EASE_OUT)
	tween.tween_property(_panel, "scale", Vector2.ONE, 0.32).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)

func close_panel() -> void:
	_provider.cancel_pending_requests()
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 0.18)
	await tween.finished
	hide()
	closed.emit()

func _build_shell() -> void:
	_scrim = ColorRect.new()
	_scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scrim.color = Color(0, 0, 0, 0.58)
	_scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	_scrim.gui_input.connect(_on_scrim_input)
	add_child(_scrim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(880, 540)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 22)
	margin.add_theme_constant_override("margin_bottom", 22)
	_panel.add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)

	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 12)
	scroll.add_child(_content)
	_apply_panel_style()
	_update_panel_size()

func _build_developer_discard_dialog() -> void:
	_developer_discard_dialog = ConfirmationDialog.new()
	_developer_discard_dialog.title = "放弃未保存的设置？"
	_developer_discard_dialog.dialog_text = "关闭设置会丢弃当前尚未保存的模型连接、运行参数、角色属性、后台生活或互动数值修改。"
	_developer_discard_dialog.ok_button_text = "放弃并关闭"
	_developer_discard_dialog.cancel_button_text = "继续编辑"
	_developer_discard_dialog.confirmed.connect(func():
		_advanced.reset_draft_state()
		_provider.reset_draft_state()
		_knowledge.reset_draft_state()
		_category_drafts.clear()
		close_panel()
	)
	add_child(_developer_discard_dialog)

func _is_panel_category(category_id: String) -> bool:
	return _settings_category == category_id

func _forward_provider_status(status: Dictionary) -> void:
	_knowledge.apply_status_data(status)

func _rebuild_content() -> void:
	# Core 与维护等异步请求可能在切页后返回：先释放旧树的控件引用再清空子节点，
	# 绝不让迟到的回调触达已被 queue_free 的控件。缓存的数据与草稿仍保留在节实例上。
	_general.release_controls()
	_provider.release_controls()
	_advanced.release_controls()
	_knowledge.release_controls()
	for child in _content.get_children():
		_content.remove_child(child)
		child.queue_free()
	var data := ThemeMgr.get_current_theme_data()
	_build_header(data)
	_build_category_navigation(data)
	_build_subcategory_navigation(data)
	match _settings_category:
		"ai":
			_provider.build(_content, data, _settings_subcategory)
		"knowledge":
			_knowledge.build(_content, data, _settings_subcategory)
		"life":
			_build_life_settings_pages(data)
		"advanced":
			_build_advanced_settings_pages(data)
		_:
			_general.build(_content, data, _settings_subcategory)
	KIT.apply_content_readability(_content, data)

func _build_header(data: Dictionary) -> void:
	var header := HBoxContainer.new()
	_content.add_child(header)
	var title := Label.new()
	title.text = "⚙️ 设置"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(data.text))
	header.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var close_button := Button.new()
	close_button.text = "✕"
	close_button.flat = true
	close_button.tooltip_text = "关闭"
	close_button.custom_minimum_size = Vector2(36, 36)
	close_button.add_theme_color_override("font_color", Color(data.text))
	close_button.add_theme_color_override("font_hover_color", Color(data.primary))
	close_button.pressed.connect(_request_close_panel)
	header.add_child(close_button)

func _build_category_navigation(data: Dictionary) -> void:
	_category_buttons.clear()
	var navigation := HFlowContainer.new()
	navigation.add_theme_constant_override("h_separation", 7)
	navigation.add_theme_constant_override("v_separation", 7)
	_content.add_child(navigation)
	for category_variant in SETTINGS_CATEGORIES:
		var category: Dictionary = category_variant
		var category_id := str(category.id)
		var button := Button.new()
		button.text = "%s  %s" % [str(category.icon), str(category.label)]
		button.toggle_mode = true
		button.button_pressed = category_id == _settings_category
		button.custom_minimum_size = Vector2(128, 38)
		button.add_theme_color_override("font_color", Color(data.text, 0.88))
		button.add_theme_color_override("font_hover_color", Color(data.text))
		button.add_theme_stylebox_override(
			"normal", KIT.style(Color(data.text, 0.045), Color(data.text, 0.11), 7, 7)
		)
		button.add_theme_stylebox_override(
			"hover", KIT.style(Color(data.primary, 0.10), Color(data.primary, 0.42), 7, 7)
		)
		if category_id == _settings_category:
			var selected_style := KIT.style(Color(data.primary, 0.19), Color(data.primary, 0.78), 7, 7)
			button.add_theme_stylebox_override("normal", selected_style)
			button.add_theme_stylebox_override("pressed", selected_style)
			button.add_theme_color_override("font_pressed_color", Color(data.text))
		var selected_id := category_id
		button.pressed.connect(
			func(): _switch_settings_category(selected_id),
			CONNECT_DEFERRED
		)
		navigation.add_child(button)
		_category_buttons[category_id] = button

func _build_subcategory_navigation(data: Dictionary) -> void:
	_subcategory_buttons.clear()
	var definitions = SETTINGS_SUBCATEGORIES.get(_settings_category, [])
	if not definitions is Array or (definitions as Array).is_empty():
		return
	var navigation := HFlowContainer.new()
	navigation.add_theme_constant_override("h_separation", 5)
	navigation.add_theme_constant_override("v_separation", 5)
	_content.add_child(navigation)
	for definition_variant in definitions:
		var definition: Dictionary = definition_variant
		var subcategory_id := str(definition.id)
		var button := Button.new()
		button.text = str(definition.label)
		button.toggle_mode = true
		button.button_pressed = subcategory_id == _settings_subcategory
		button.custom_minimum_size = Vector2(112, 32)
		button.add_theme_color_override("font_color", Color(data.text, 0.82))
		button.add_theme_color_override("font_hover_color", Color(data.text))
		button.add_theme_stylebox_override(
			"normal", KIT.style(Color(data.text, 0.025), Color(data.text, 0.09), 7, 6)
		)
		button.add_theme_stylebox_override(
			"hover", KIT.style(Color(data.accent, 0.09), Color(data.accent, 0.36), 7, 6)
		)
		if subcategory_id == _settings_subcategory:
			var selected_style := KIT.style(Color(data.accent, 0.16), Color(data.accent, 0.66), 7, 6)
			button.add_theme_stylebox_override("normal", selected_style)
			button.add_theme_stylebox_override("pressed", selected_style)
			button.add_theme_color_override("font_pressed_color", Color(data.text))
		var selected_id := subcategory_id
		button.pressed.connect(
			func(): _switch_settings_subcategory(selected_id),
			CONNECT_DEFERRED
		)
		navigation.add_child(button)
		_subcategory_buttons[subcategory_id] = button

func _switch_settings_category(category_id: String) -> void:
	if category_id == "interaction":
		category_id = "advanced"
		_settings_subcategory_by_category["advanced"] = "interaction"
	if category_id == _settings_category:
		return
	_capture_visible_category_draft()
	_settings_category = category_id
	_settings_subcategory = str(_settings_subcategory_by_category.get(
		category_id, DEFAULT_SETTINGS_SUBCATEGORIES.get(category_id, "")
	))
	_rebuild_content()
	_restore_visible_category_draft()
	if category_id == "ai":
		_provider.refresh_status_if_needed.call_deferred()

func _switch_settings_subcategory(subcategory_id: String) -> void:
	if subcategory_id == _settings_subcategory:
		return
	var definitions = SETTINGS_SUBCATEGORIES.get(_settings_category, [])
	var valid := false
	if definitions is Array:
		for definition_variant in definitions:
			if definition_variant is Dictionary and str((definition_variant as Dictionary).get("id", "")) == subcategory_id:
				valid = true
				break
	if not valid:
		return
	_capture_visible_category_draft()
	_settings_subcategory = subcategory_id
	_settings_subcategory_by_category[_settings_category] = subcategory_id
	_rebuild_content()
	_restore_visible_category_draft()

func _build_life_settings_pages(data: Dictionary) -> void:
	_advanced.build_life_ambient_page(_content, data, _settings_subcategory)
	_general.build_life_presentation_page(_content, data, _settings_subcategory)

func _build_advanced_settings_pages(data: Dictionary) -> void:
	_advanced.build_advanced_page(_content, data, _settings_subcategory)

func _capture_visible_category_draft() -> void:
	match _settings_category:
		"ai":
			if _provider.has_unsaved_changes():
				_category_drafts["ai"] = _provider.capture_draft()
			else:
				_category_drafts.erase("ai")
		"knowledge":
			_category_drafts["knowledge"] = _knowledge.capture_draft()
		"life":
			_category_drafts["life"] = _advanced.capture_draft()
		"advanced":
			_category_drafts["advanced"] = _advanced.capture_draft()

func _restore_visible_category_draft() -> void:
	var draft = _category_drafts.get(_settings_category, {})
	if not draft is Dictionary or (draft as Dictionary).is_empty():
		return
	match _settings_category:
		"ai":
			_provider.restore_draft(draft as Dictionary)
		"knowledge":
			_knowledge.restore_draft(draft as Dictionary)
		"life":
			_advanced.restore_draft(draft as Dictionary)
		"advanced":
			_advanced.restore_draft(draft as Dictionary)

func _apply_panel_style() -> void:
	var data := ThemeMgr.get_current_theme_data()
	_panel.add_theme_stylebox_override("panel", KIT.style(Color(data.bg, 0.97), Color(data.text, 0.12), 24, 0))
	var material := ShaderMaterial.new()
	material.shader = GLASS_SHADER
	material.set_shader_parameter("tint_color", Color(data.bg))
	material.set_shader_parameter("tint_strength", 0.88)
	material.set_shader_parameter("blur_lod", 3.0)
	_panel.material = material

func _update_panel_size() -> void:
	if _panel:
		var viewport_size := get_viewport_rect().size
		_panel.custom_minimum_size = Vector2(minf(960.0, viewport_size.x - 24.0), minf(720.0, viewport_size.y - 24.0))

func _on_theme_changed(_data: Dictionary) -> void:
	_apply_panel_style()
	if visible:
		call_deferred("_rebuild_content_preserving_developer_draft")

func _rebuild_content_preserving_developer_draft() -> void:
	if not visible:
		return
	_capture_visible_category_draft()
	if _advanced.handle_scope_change(Settings.get_interaction_scope_save_id()):
		_category_drafts.erase("advanced")
	_rebuild_content()
	_restore_visible_category_draft()

func _request_close_panel() -> void:
	if _provider.is_write_in_flight():
		_provider.warn_write_in_flight()
		return
	if _advanced.has_unsaved_changes() or _knowledge.has_unsaved_changes() or _provider.has_unsaved_changes():
		_developer_discard_dialog.popup_centered(Vector2i(460, 180))
		return
	close_panel()

func _on_scrim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_request_close_panel()

func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		_request_close_panel()
