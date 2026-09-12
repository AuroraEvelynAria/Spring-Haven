extends "res://scenes/Settings/sections/SettingsSectionBase.gd"
## 设置面板 · 体验分节：主题、自定义颜色、显示与声音、字号字体、可读性、2D 舞台。

const KIT := preload("res://scenes/Settings/sections/SettingsUIKit.gd")

var _bg_picker: ColorPickerButton
var _primary_picker: ColorPickerButton
var _accent_picker: ColorPickerButton
var _readability_panel: PanelContainer
var _readability_row: HBoxContainer
var _resolution_select: OptionButton
var _fullscreen_toggle: CheckBox


func build(parent: VBoxContainer, data: Dictionary, subcategory: String) -> void:
	_build_general_settings_pages(parent, data, subcategory)


func build_life_presentation_page(parent: VBoxContainer, data: Dictionary, subcategory: String) -> void:
	var start := parent.get_child_count()
	_build_2d_presentation_section(parent, data)
	_set_content_children_visible(parent, start, subcategory == "presentation")


func release_controls() -> void:
	_bg_picker = null
	_primary_picker = null
	_accent_picker = null
	_readability_panel = null
	_readability_row = null
	_resolution_select = null
	_fullscreen_toggle = null


func _set_content_children_visible(parent: VBoxContainer, start_index: int, visible: bool) -> void:
	for index in range(start_index, parent.get_child_count()):
		(parent.get_child(index) as CanvasItem).visible = visible


func _build_general_settings_pages(parent: VBoxContainer, data: Dictionary, subcategory: String) -> void:
	var start := parent.get_child_count()
	_build_theme_section(parent, data)
	_build_custom_color_section(parent, data)
	_set_content_children_visible(parent, start, subcategory == "appearance")
	start = parent.get_child_count()
	_build_display_section(parent, data)
	_build_audio_section(parent, data)
	_set_content_children_visible(parent, start, subcategory == "window_audio")
	start = parent.get_child_count()
	_build_readability(parent, data)
	_build_size_section(parent, data)
	_build_font_section(parent, data)
	_set_content_children_visible(parent, start, subcategory == "readability")


func _build_2d_presentation_section(parent: VBoxContainer, data: Dictionary) -> void:
	parent.add_child(KIT.section_label("角色表现层", data))
	var card := PanelContainer.new()
	card.add_theme_stylebox_override(
		"panel", KIT.style(Color(data.primary, 0.055), Color(data.text, 0.12), 8, 12)
	)
	parent.add_child(card)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 9)
	card.add_child(column)
	var title := Label.new()
	title.text = "🎭 2D 对话舞台"
	title.add_theme_font_size_override("font_size", 15)
	title.add_theme_color_override("font_color", Color(data.primary))
	column.add_child(title)
	var summary := Label.new()
	summary.text = "对话、记忆、生活状态与互动规则由 Companion Core 统一驱动；立绘、分层动画与未来 Live2D 只负责表现。"
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	summary.add_theme_font_size_override("font_size", 11)
	summary.add_theme_color_override("font_color", Color(data.secondary, 0.96))
	column.add_child(summary)
	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 7)
	column.add_child(mode_row)
	var mode_label := Label.new()
	mode_label.text = "默认入口"
	mode_label.custom_minimum_size = Vector2(92, 0)
	mode_row.add_child(mode_label)
	var current_mode := str(Settings.settings.display.get("view_mode", "2d"))
	var mode_group := ButtonGroup.new()
	mode_group.allow_unpress = false
	for mode in [
		{"id": "2d", "label": "2D 对话舞台"},
		{"id": "3d", "label": "3D 探索实验"},
	]:
		var button := Button.new()
		button.text = str(mode.label)
		button.toggle_mode = true
		button.button_group = mode_group
		button.button_pressed = current_mode == str(mode.id)
		button.custom_minimum_size = Vector2(148, 34)
		var mode_id := str(mode.id)
		button.pressed.connect(func(): Settings.set_setting("display", "view_mode", mode_id))
		mode_row.add_child(button)
	var adapter_status := Label.new()
	adapter_status.text = "当前渲染器：分层立绘适配器 · 已支持眨眼、视线、呼吸、口型、思考与情绪状态"
	adapter_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	adapter_status.add_theme_font_size_override("font_size", 10)
	adapter_status.add_theme_color_override("font_color", Color(data.text, 0.88))
	column.add_child(adapter_status)


func _build_display_section(parent: VBoxContainer, data: Dictionary) -> void:
	parent.add_child(KIT.section_label("显示", data))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)

	_resolution_select = OptionButton.new()
	_resolution_select.custom_minimum_size = Vector2(220, 36)
	_resolution_select.tooltip_text = "窗口分辨率"
	var current_resolution := Settings.get_resolution()
	var selected_index := 0
	for key in Settings.RESOLUTIONS.keys():
		var index := _resolution_select.item_count
		_resolution_select.add_item(str(key))
		_resolution_select.set_item_metadata(index, str(key))
		if str(key) == current_resolution:
			selected_index = index
	_resolution_select.select(selected_index)
	_resolution_select.disabled = bool(Settings.settings.display.fullscreen)
	_resolution_select.item_selected.connect(_on_resolution_selected)
	var resolution_popup := _resolution_select.get_popup()
	resolution_popup.add_theme_color_override("font_color", Color(data.text))
	resolution_popup.add_theme_color_override("font_hover_color", Color(data.text))
	resolution_popup.add_theme_stylebox_override("panel", KIT.style(Color(data.bg), Color(data.text, 0.22), 10, 8))
	resolution_popup.add_theme_stylebox_override("hover", KIT.style(Color(data.primary, 0.16), Color(data.primary), 7, 8))
	row.add_child(_resolution_select)

	_fullscreen_toggle = CheckBox.new()
	_fullscreen_toggle.text = "全屏"
	_fullscreen_toggle.button_pressed = bool(Settings.settings.display.fullscreen)
	_fullscreen_toggle.toggled.connect(_on_fullscreen_toggled)
	row.add_child(_fullscreen_toggle)

	var vsync_toggle := CheckBox.new()
	vsync_toggle.text = "垂直同步"
	vsync_toggle.button_pressed = bool(Settings.settings.display.vsync)
	vsync_toggle.toggled.connect(_on_vsync_toggled)
	row.add_child(vsync_toggle)

func _build_theme_section(parent: VBoxContainer, data: Dictionary) -> void:
	parent.add_child(KIT.section_label("预设主题", data))
	var grid := GridContainer.new()
	var viewport_width: float = host.get_viewport_rect().size.x
	grid.columns = 3 if viewport_width <= 520.0 else 4 if viewport_width <= 820.0 else 6
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	parent.add_child(grid)
	for key in ThemeMgr.get_theme_keys():
		var item_data := ThemeMgr.get_theme_data(str(key))
		var button := Button.new()
		button.text = ""
		button.custom_minimum_size = Vector2(88, 48)
		var style := KIT.style(Color(1, 1, 1, 0.025), Color(item_data.primary) if str(key) == ThemeMgr.current_theme_name else Color(data.text, 0.10), 10, 5)
		button.add_theme_stylebox_override("normal", style)
		var hover := style.duplicate()
		hover.border_color = Color(item_data.primary)
		button.add_theme_stylebox_override("hover", hover)
		var center := CenterContainer.new()
		center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		center.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.add_child(center)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		center.add_child(row)
		var dot := PanelContainer.new()
		dot.custom_minimum_size = Vector2(18, 18)
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dot.add_theme_stylebox_override("panel", KIT.style(Color(item_data.primary), Color(item_data.bg), 9, 0))
		row.add_child(dot)
		var name := Label.new()
		name.text = str(key).capitalize()
		name.add_theme_font_size_override("font_size", 9)
		name.add_theme_color_override("font_color", Color(data.text))
		name.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(name)
		var theme_key := str(key)
		button.pressed.connect(func():
			Settings.settings.ui.theme = theme_key
			Settings.save()
			ThemeMgr.apply_theme(theme_key)
		)
		grid.add_child(button)

func _build_audio_section(parent: VBoxContainer, data: Dictionary) -> void:
	parent.add_child(KIT.section_label("声音", data))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)

	var label := Label.new()
	label.text = "背景音乐"
	label.custom_minimum_size = Vector2(76, 0)
	row.add_child(label)

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.value = Audio.get_music_volume()
	slider.custom_minimum_size = Vector2(230, 32)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(slider)

	var value_label := Label.new()
	value_label.text = "%d%%" % roundi(slider.value * 100.0)
	value_label.custom_minimum_size = Vector2(48, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value_label)

	var mute_button := Button.new()
	mute_button.text = "静音" if slider.value > 0.0 else "恢复"
	mute_button.custom_minimum_size = Vector2(70, 32)
	row.add_child(mute_button)

	slider.value_changed.connect(func(value: float):
		Audio.set_music_volume(value)
		value_label.text = "%d%%" % roundi(value * 100.0)
		mute_button.text = "静音" if value > 0.0 else "恢复"
	)
	mute_button.pressed.connect(func():
		slider.value = 0.0 if slider.value > 0.0 else 0.7
	)
func _build_custom_color_section(parent: VBoxContainer, data: Dictionary) -> void:
	parent.add_child(KIT.section_label("自定义颜色", data))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	parent.add_child(row)
	_bg_picker = _color_picker("背景", Color(data.bg), row)
	_primary_picker = _color_picker("主色", Color(data.primary), row)
	_accent_picker = _color_picker("强调", Color(data.accent), row)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var apply_button := Button.new()
	apply_button.text = "应用"
	apply_button.custom_minimum_size = Vector2(76, 34)
	apply_button.pressed.connect(_apply_custom_colors)
	row.add_child(apply_button)

func _build_readability(parent: VBoxContainer, data: Dictionary) -> void:
	_readability_panel = PanelContainer.new()
	parent.add_child(_readability_panel)
	_readability_row = HBoxContainer.new()
	_readability_row.add_theme_constant_override("separation", 8)
	_readability_panel.add_child(_readability_row)
	_update_readability(data)

func _build_size_section(parent: VBoxContainer, data: Dictionary) -> void:
	parent.add_child(KIT.section_label("界面字号", data))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	parent.add_child(row)
	var labels := {13: "小", 15: "默认", 17: "大", 19: "特大", 21: "超大"}
	for size in labels:
		var button := Button.new()
		button.text = labels[size]
		button.custom_minimum_size = Vector2(74, 34)
		if int(Settings.settings.ui.font_size) == size:
			button.add_theme_stylebox_override("normal", KIT.style(Color(data.primary, 0.24), Color(data.primary), 17, 5))
		var selected_size: int = size
		button.pressed.connect(func():
			Settings.settings.ui.font_size = selected_size
			Settings.save()
			ThemeMgr.apply_theme(str(Settings.settings.ui.theme))
			Global.font_size_changed.emit(selected_size)
		)
		row.add_child(button)

func _build_font_section(parent: VBoxContainer, data: Dictionary) -> void:
	parent.add_child(KIT.section_label("界面字体", data))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	parent.add_child(row)
	var fonts := {"system": "系统", "serif": "宋体", "modern": "现代", "mono": "等宽"}
	for family in fonts:
		var button := Button.new()
		button.text = fonts[family]
		button.custom_minimum_size = Vector2(82, 34)
		if str(Settings.settings.ui.font_family) == family:
			button.add_theme_stylebox_override("normal", KIT.style(Color(data.primary, 0.24), Color(data.primary), 17, 5))
		var selected_family := str(family)
		button.pressed.connect(func():
			Settings.settings.ui.font_family = selected_family
			Settings.save()
			ThemeMgr.apply_theme(str(Settings.settings.ui.theme))
			Global.font_size_changed.emit(int(Settings.settings.ui.font_size))
		)
		row.add_child(button)


func _color_picker(label_text: String, color: Color, parent: HBoxContainer) -> ColorPickerButton:
	var group := VBoxContainer.new()
	group.add_theme_constant_override("separation", 3)
	parent.add_child(group)
	var label := Label.new()
	label.text = label_text
	label.add_theme_font_size_override("font_size", 11)
	group.add_child(label)
	var picker := ColorPickerButton.new()
	picker.color = color
	picker.custom_minimum_size = Vector2(88, 32)
	picker.edit_alpha = false
	picker.tooltip_text = "%s  #%s" % [label_text, color.to_html(false).to_upper()]
	var data := ThemeMgr.get_current_theme_data()
	var normal := KIT.style(color, Color(data.text, 0.28), 7, 3)
	var hover := normal.duplicate()
	hover.border_color = Color(data.primary)
	var focus := KIT.style(Color(0, 0, 0, 0), Color(data.primary), 7, 0)
	picker.add_theme_stylebox_override("normal", normal)
	picker.add_theme_stylebox_override("hover", hover)
	picker.add_theme_stylebox_override("pressed", hover)
	picker.add_theme_stylebox_override("focus", focus)
	_configure_color_picker(picker, data)
	group.add_child(picker)
	return picker

func _configure_color_picker(button: ColorPickerButton, data: Dictionary) -> void:
	var picker := button.get_picker()
	picker.picker_shape = ColorPicker.SHAPE_HSV_RECTANGLE
	picker.color_modes_visible = false
	picker.sliders_visible = true
	picker.hex_visible = true
	picker.presets_visible = false
	picker.sampler_visible = false
	picker.custom_minimum_size = Vector2(300, 300)

	var popup := button.get_popup()
	popup.transparent_bg = false
	popup.add_theme_stylebox_override("panel", KIT.style(Color(data.bg), Color(data.text, 0.24), 10, 12))
	popup.about_to_popup.connect(func():
		popup.size = Vector2i(324, 340)
	)

func _apply_custom_colors() -> void:
	Settings.set_custom_colors(_bg_picker.color.to_html(false), _primary_picker.color.to_html(false), _accent_picker.color.to_html(false))

func _on_resolution_selected(index: int) -> void:
	var key := str(_resolution_select.get_item_metadata(index))
	Settings.set_resolution(key)

func _on_fullscreen_toggled(enabled: bool) -> void:
	Settings.settings.display.fullscreen = enabled
	Settings.save()
	Settings.apply_display()
	_resolution_select.disabled = enabled

func _on_vsync_toggled(enabled: bool) -> void:
	Settings.settings.display.vsync = enabled
	Settings.save()
	Settings.apply_display()

func _update_readability(data: Dictionary) -> void:
	for child in _readability_row.get_children():
		child.free()
	var ratio := KIT.contrast_ratio(Color(data.bg), Color(data.text))
	var icon := "✅"
	var message := "对比度 %.1f:1 · AAA 级 · 极佳" % ratio
	var status := Color("#4CAF7D")
	if ratio < 3.0:
		icon = "❌"
		message = "对比度 %.1f:1 · 可读性不足！" % ratio
		status = Color("#D9534F")
	elif ratio < 4.5:
		icon = "⚠"
		message = "对比度 %.1f:1 · 建议调整" % ratio
		status = Color("#D9A441")
	elif ratio < 7.0:
		message = "对比度 %.1f:1 · AA 级 · 良好" % ratio
	_readability_panel.add_theme_stylebox_override("panel", KIT.style(Color(status, 0.10), Color(status, 0.35), 10, 9))
	var label := Label.new()
	label.text = icon + "  " + message
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 12)
	_readability_row.add_child(label)
	if ratio < 4.5:
		var optimize := Button.new()
		optimize.text = "智能优化"
		optimize.pressed.connect(func():
			Settings.settings.ui.theme = "amber"
			Settings.save()
			ThemeMgr.apply_theme("amber")
		)
		_readability_row.add_child(optimize)
