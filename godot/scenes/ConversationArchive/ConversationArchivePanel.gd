extends Control

signal closed

const ARCHIVE := preload("res://scripts/domain/ConversationArchive.gd")
const ROLE_NAMES := {"ling": "🐾 小玲", "nai": "🐇 小奈"}

var _scrim: ColorRect
var _panel: PanelContainer
var _date_select: OptionButton
var _role_select: OptionButton
var _sender_select: OptionButton
var _search_input: LineEdit
var _results: VBoxContainer
var _status: Label
var _search_timer: Timer

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_shell()
	get_viewport().size_changed.connect(_update_panel_size)
	Global.theme_changed.connect(_on_theme_changed)
	hide()

func show_panel() -> void:
	_reload_dates()
	_refresh_results()
	show()
	move_to_front()
	modulate.a = 0.0
	_panel.scale = Vector2(0.98, 0.98)
	_panel.pivot_offset = _panel.size / 2.0
	var tween := create_tween().set_parallel(true)
	tween.tween_property(self, "modulate:a", 1.0, 0.18)
	tween.tween_property(_panel, "scale", Vector2.ONE, 0.24).set_ease(Tween.EASE_OUT)
	_search_input.grab_focus()

func close_panel() -> void:
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 0.14)
	await tween.finished
	hide()
	closed.emit()

func _build_shell() -> void:
	_scrim = ColorRect.new()
	_scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scrim.color = Color(0, 0, 0, 0.66)
	_scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	_scrim.gui_input.connect(_on_scrim_input)
	add_child(_scrim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(_panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 20)
	_panel.add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 12)
	margin.add_child(content)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	content.add_child(header)
	var title := Label.new()
	title.text = "📚  聊天归档"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 19)
	header.add_child(title)
	var refresh_button := Button.new()
	refresh_button.text = "↻"
	refresh_button.tooltip_text = "刷新归档"
	refresh_button.flat = true
	refresh_button.custom_minimum_size = Vector2(34, 32)
	refresh_button.pressed.connect(func():
		_reload_dates()
		_refresh_results()
	)
	header.add_child(refresh_button)
	var close_button := Button.new()
	close_button.text = "✕"
	close_button.tooltip_text = "关闭"
	close_button.flat = true
	close_button.custom_minimum_size = Vector2(34, 32)
	close_button.pressed.connect(close_panel)
	header.add_child(close_button)

	var filters := HFlowContainer.new()
	filters.add_theme_constant_override("h_separation", 8)
	filters.add_theme_constant_override("v_separation", 8)
	content.add_child(filters)
	_date_select = OptionButton.new()
	_date_select.custom_minimum_size = Vector2(168, 34)
	_date_select.item_selected.connect(func(_index: int): _refresh_results())
	filters.add_child(_date_select)
	_role_select = OptionButton.new()
	_role_select.custom_minimum_size = Vector2(116, 34)
	_add_option(_role_select, "全部角色", "")
	_add_option(_role_select, "🐾 小玲", "ling")
	_add_option(_role_select, "🐇 小奈", "nai")
	_role_select.item_selected.connect(func(_index: int): _refresh_results())
	filters.add_child(_role_select)
	_sender_select = OptionButton.new()
	_sender_select.custom_minimum_size = Vector2(116, 34)
	_add_option(_sender_select, "全部发送者", "")
	_add_option(_sender_select, "主人", "user")
	_add_option(_sender_select, "AI", "ai")
	_sender_select.item_selected.connect(func(_index: int): _refresh_results())
	filters.add_child(_sender_select)
	_search_input = LineEdit.new()
	_search_input.placeholder_text = "搜索聊天内容"
	_search_input.clear_button_enabled = true
	_search_input.custom_minimum_size = Vector2(250, 34)
	_search_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search_input.text_changed.connect(_on_search_text_changed)
	_search_input.text_submitted.connect(func(_text: String): _refresh_results())
	filters.add_child(_search_input)
	var search_button := Button.new()
	search_button.text = "🔍"
	search_button.tooltip_text = "搜索"
	search_button.custom_minimum_size = Vector2(42, 34)
	search_button.pressed.connect(_refresh_results)
	filters.add_child(search_button)

	var separator := HSeparator.new()
	content.add_child(separator)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(scroll)
	_results = VBoxContainer.new()
	_results.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_results.add_theme_constant_override("separation", 10)
	scroll.add_child(_results)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status.add_theme_font_size_override("font_size", 11)
	content.add_child(_status)

	_search_timer = Timer.new()
	_search_timer.one_shot = true
	_search_timer.wait_time = 0.24
	_search_timer.timeout.connect(_refresh_results)
	add_child(_search_timer)
	_update_panel_size()
	_apply_theme()

func _reload_dates() -> void:
	var previous := _selected_metadata(_date_select)
	_date_select.clear()
	_add_option(_date_select, "全部日期", "")
	for summary in ARCHIVE.list_dates(Global.get_active_save_id()):
		_add_option(
			_date_select,
			"%s  (%d)" % [str(summary.date), int(summary.count)],
			str(summary.date)
		)
	for index in _date_select.item_count:
		if str(_date_select.get_item_metadata(index)) == previous:
			_date_select.select(index)
			break

func _refresh_results() -> void:
	for child in _results.get_children():
		child.queue_free()
	var entries := ARCHIVE.search_entries(
		_search_input.text,
		_selected_metadata(_date_select),
		_selected_metadata(_role_select),
		_selected_metadata(_sender_select),
		Global.get_active_save_id()
	)
	if entries.is_empty():
		var empty := Label.new()
		empty.text = "没有匹配的聊天记录"
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.custom_minimum_size = Vector2(0, 90)
		empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		empty.add_theme_color_override("font_color", Color(ThemeMgr.get_current_theme_data().secondary, 0.62))
		_results.add_child(empty)
	else:
		for entry in entries:
			_add_result_row(entry)
	_status.text = "共 %d 条" % entries.size()
	var error := ARCHIVE.get_last_error()
	if not error.is_empty():
		_status.text = error
		_status.add_theme_color_override("font_color", Color("#D9534F"))
	else:
		_status.add_theme_color_override("font_color", Color(ThemeMgr.get_current_theme_data().secondary, 0.72))

func _add_result_row(entry: Dictionary) -> void:
	var data := ThemeMgr.get_current_theme_data()
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	_results.add_child(row)
	var meta := HBoxContainer.new()
	row.add_child(meta)
	var sender := str(entry.get("sender", ""))
	var role := str(entry.get("role", ""))
	var speaker := "主人" if sender == "user" else str(ROLE_NAMES.get(role, "AI"))
	var meta_label := Label.new()
	meta_label.text = "%s  ·  %s" % [
		ARCHIVE.format_local_timestamp(int(entry.get("created_at", 0))),
		speaker,
	]
	meta_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	meta_label.add_theme_font_size_override("font_size", 11)
	meta_label.add_theme_color_override("font_color", Color(data.secondary, 0.72))
	meta.add_child(meta_label)
	if str(entry.get("status", "sent")) == "failed":
		var failed := Label.new()
		failed.text = "发送失败"
		failed.add_theme_font_size_override("font_size", 10)
		failed.add_theme_color_override("font_color", Color("#D9534F"))
		meta.add_child(failed)
	var body := RichTextLabel.new()
	body.text = str(entry.get("text", ""))
	body.bbcode_enabled = false
	body.fit_content = true
	body.scroll_active = false
	body.selection_enabled = true
	body.custom_minimum_size = Vector2(0, 26)
	body.add_theme_font_size_override("font_size", 13)
	body.add_theme_color_override("default_color", Color(data.text, 0.94))
	row.add_child(body)
	var separator := HSeparator.new()
	separator.modulate.a = 0.46
	_results.add_child(separator)

func _add_option(select: OptionButton, label: String, metadata: String) -> void:
	var index := select.item_count
	select.add_item(label)
	select.set_item_metadata(index, metadata)

func _selected_metadata(select: OptionButton) -> String:
	if not is_instance_valid(select) or select.item_count == 0 or select.selected < 0:
		return ""
	return str(select.get_item_metadata(select.selected))

func _on_search_text_changed(_text: String) -> void:
	_search_timer.start()

func _update_panel_size() -> void:
	if not is_instance_valid(_panel):
		return
	var viewport := get_viewport_rect().size
	_panel.custom_minimum_size = Vector2(
		clampf(viewport.x - 32.0, 360.0, 920.0),
		clampf(viewport.y - 32.0, 440.0, 650.0)
	)

func _apply_theme() -> void:
	if not is_instance_valid(_panel):
		return
	var data := ThemeMgr.get_current_theme_data()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(data.bg, 0.985)
	style.set_border_width_all(1)
	style.border_color = Color(data.primary, 0.48)
	style.set_corner_radius_all(8)
	style.shadow_color = Color(0, 0, 0, 0.42)
	style.shadow_size = 18
	_panel.add_theme_stylebox_override("panel", style)

func _on_theme_changed(_data: Dictionary) -> void:
	_apply_theme()
	if visible:
		_refresh_results()

func _on_scrim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		close_panel()

func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		close_panel()
