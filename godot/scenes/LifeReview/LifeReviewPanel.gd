class_name LifeReviewPanel
extends Control

"""生活回顾面板：展示角色自主生活的时间线（来自 Core GET /life/events）。"""

const ROLE_NAMES := {"ling": "小玲", "nai": "小奈"}
const ROLE_COLORS := {"ling": "#E8A0BF", "nai": "#A0C4E8"}

var _scrim: ColorRect
var _panel: PanelContainer
var _rows: VBoxContainer
var _status: Label
var _role_filter: OptionButton
var _loading := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_shell()
	get_viewport().size_changed.connect(_update_panel_size)
	Global.theme_changed.connect(_apply_colors)
	hide()


func show_panel() -> void:
	_refresh()
	show()
	modulate.a = 0.0
	_panel.scale = Vector2(0.98, 0.98)
	_panel.pivot_offset = _panel.size * 0.5
	var tween := create_tween().set_parallel(true)
	tween.tween_property(self, "modulate:a", 1.0, 0.18)
	tween.tween_property(_panel, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_CUBIC)


func close_panel() -> void:
	hide()


func _build_shell() -> void:
	_scrim = ColorRect.new()
	_scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scrim.color = Color(0, 0, 0, 0.58)
	_scrim.gui_input.connect(_on_scrim_input)
	add_child(_scrim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(860, 600)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 22)
	margin.add_theme_constant_override("margin_right", 22)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 18)
	_panel.add_child(margin)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 10)
	margin.add_child(content)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	content.add_child(header)
	var title := Label.new()
	title.text = "🌿 生活回顾"
	title.add_theme_font_size_override("font_size", 20)
	header.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var refresh := Button.new()
	refresh.text = "⟳ 刷新"
	refresh.tooltip_text = "重新拉取生活时间线"
	refresh.flat = true
	refresh.custom_minimum_size = Vector2(72, 36)
	refresh.pressed.connect(_refresh)
	header.add_child(refresh)
	var close := Button.new()
	close.text = "✕"
	close.flat = true
	close.tooltip_text = "关闭"
	close.custom_minimum_size = Vector2(36, 36)
	close.pressed.connect(close_panel)
	header.add_child(close)

	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 8)
	content.add_child(toolbar)
	var filter_label := Label.new()
	filter_label.text = "角色："
	filter_label.add_theme_font_size_override("font_size", 12)
	toolbar.add_child(filter_label)
	_role_filter = OptionButton.new()
	_role_filter.add_item("全部", 0)
	_role_filter.add_item("小玲", 1)
	_role_filter.add_item("小奈", 2)
	_role_filter.custom_minimum_size = Vector2(110, 34)
	_role_filter.item_selected.connect(func(_index: int): _refresh())
	toolbar.add_child(_role_filter)
	var hint := Label.new()
	hint.text = "角色不在时，她们也在按自己的节奏生活。"
	hint.add_theme_font_size_override("font_size", 11)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	toolbar.add_child(hint)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(scroll)
	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override("separation", 6)
	scroll.add_child(_rows)

	_status = Label.new()
	_status.text = ""
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 11)
	content.add_child(_status)
	_apply_colors()
	_update_panel_size()


func _refresh() -> void:
	if _loading or not CompanionCore.is_active():
		_set_status("Companion Core 未连接", true)
		return
	_loading = true
	_set_status("正在拉取生活时间线…")
	_render_loading()
	var role_id := ""
	match _role_filter.selected:
		1:
			role_id = "ling"
		2:
			role_id = "nai"
	var result: Dictionary = await CompanionCore.fetch_life_events(200, role_id)
	_loading = false
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "拉取失败")), true)
		_render_empty("生活时间线暂时不可用")
		return
	var data_variant = result.get("data", {})
	if not data_variant is Dictionary:
		_render_empty("返回数据格式异常")
		return
	var events_variant = (data_variant as Dictionary).get("events", [])
	if not events_variant is Array:
		_render_empty("没有生活记录")
		return
	var events: Array = events_variant
	if events.is_empty():
		_render_empty("还没有生活记录——她们会在离开玩家时开始自己的日常。")
		_set_status("共 0 条生活记录")
		return
	_render_events(events)
	_set_status("共 %d 条生活记录（最近 200 条）" % events.size())


func _render_loading() -> void:
	for child in _rows.get_children():
		child.queue_free()
	var label := Label.new()
	label.text = "加载中…"
	label.add_theme_font_size_override("font_size", 12)
	_rows.add_child(label)


func _render_empty(text: String) -> void:
	for child in _rows.get_children():
		child.queue_free()
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color(ThemeMgr.get_current_theme_data().secondary, 0.9))
	_rows.add_child(label)


func _render_events(events: Array) -> void:
	for child in _rows.get_children():
		child.queue_free()
	var current_day := ""
	for event_variant in events:
		if not event_variant is Dictionary:
			continue
		var event: Dictionary = event_variant
		var occurred := int(event.get("occurred_at_unix", 0))
		var day_key := _day_key(occurred)
		if day_key != current_day:
			current_day = day_key
			var day_header := Label.new()
			day_header.text = _day_label(occurred)
			day_header.add_theme_font_size_override("font_size", 13)
			day_header.add_theme_color_override("font_color", Color(ThemeMgr.get_current_theme_data().primary, 0.95))
			_rows.add_child(day_header)
		_rows.add_child(_event_row(event))


func _event_row(event: Dictionary) -> Control:
	var role_id := str(event.get("role_id", ""))
	var role_color := Color(ROLE_COLORS.get(role_id, "#A0C4E8"))
	var time_str := _time_label(int(event.get("occurred_at_unix", 0)))
	var description := str(event.get("description", "")).strip_edges()
	if description.is_empty():
		description = str(event.get("action", "生活片段"))
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	var time_label := Label.new()
	time_label.text = time_str
	time_label.custom_minimum_size = Vector2(52, 0)
	time_label.add_theme_font_size_override("font_size", 11)
	time_label.add_theme_color_override("font_color", Color(ThemeMgr.get_current_theme_data().secondary, 0.8))
	hbox.add_child(time_label)
	var role_label := Label.new()
	role_label.text = ROLE_NAMES.get(role_id, role_id)
	role_label.custom_minimum_size = Vector2(44, 0)
	role_label.add_theme_font_size_override("font_size", 11)
	role_label.add_theme_color_override("font_color", Color(role_color, 0.95))
	hbox.add_child(role_label)
	var action_label := Label.new()
	action_label.text = description.left(160)
	action_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	action_label.add_theme_font_size_override("font_size", 12)
	action_label.add_theme_color_override("font_color", Color(ThemeMgr.get_current_theme_data().text, 0.92))
	hbox.add_child(action_label)
	return hbox


func _set_status(text: String, is_error := false) -> void:
	if not is_instance_valid(_status):
		return
	_status.text = text
	var data := ThemeMgr.get_current_theme_data()
	_status.add_theme_color_override(
		"font_color", Color("#D9534F" if is_error else data.secondary, 0.85)
	)


func _on_scrim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		close_panel()


func _apply_colors(_data: Dictionary = {}) -> void:
	if not is_instance_valid(_panel):
		return
	var data := ThemeMgr.get_current_theme_data()
	_panel.add_theme_stylebox_override(
		"panel", _style(Color(data.bg, 0.98), Color(data.text, 0.14), 8, 0)
	)


func _style(bg: Color, border: Color, radius: int, width: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.set_border_width_all(width)
	style.set_corner_radius_all(radius)
	return style


func _update_panel_size() -> void:
	if not is_instance_valid(_panel):
		return
	var viewport := get_viewport_rect().size
	_panel.custom_minimum_size = Vector2(
		minf(860.0, viewport.x - 24.0),
		minf(600.0, viewport.y - 24.0)
	)


func _day_key(unix: int) -> String:
	var dict := Time.get_datetime_dict_from_system(unix)
	return "%04d-%02d-%02d" % [int(dict.get("year", 0)), int(dict.get("month", 0)), int(dict.get("day", 0))]


func _day_label(unix: int) -> String:
	var dict := Time.get_datetime_dict_from_system(unix)
	var today := Time.get_datetime_dict_from_system()
	if int(dict.get("year", 0)) == int(today.get("year", 0)) \
		and int(dict.get("month", 0)) == int(today.get("month", 0)) \
		and int(dict.get("day", 0)) == int(today.get("day", 0)):
		return "今天"
	return "%d月%d日" % [int(dict.get("month", 0)), int(dict.get("day", 0))]


func _time_label(unix: int) -> String:
	var dict := Time.get_datetime_dict_from_system(unix)
	return "%02d:%02d" % [int(dict.get("hour", 0)), int(dict.get("minute", 0))]
