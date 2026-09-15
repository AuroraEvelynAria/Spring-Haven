class_name HouseLayoutEditor
extends Control

"""家の地图编辑器：2D 俯视编辑角色可去的锚点位置，保存到 user_data/house_layout.json。

数据格式：
{ "version": 1, "room_width": 6.0, "room_depth": 5.0,
  "anchors": [ {"id": "sofa", "label": "沙发", "x": -0.85, "z": 1.3, "icon": "🛋"} ] }
"""

const LAYOUT_PATH := "user://house_layout.json"
const DEFAULT_ICONS := ["🛋", "🍽", "🪴", "🚪", "🛏", "📚", "🪟", "🛁"]

var _anchors: Array[Dictionary] = []
var _room_width := 6.0
var _room_depth := 5.0
var _selected := -1
var _dragging := -1
var _hover := -1
var _icons_used: Dictionary = {}
var _scrim: ColorRect
var _panel: PanelContainer
var _canvas: Control
var _list: VBoxContainer
var _status: Label
var _add_button: Button
var _save_button: Button
var _close_button: Button


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_shell()
	_load_layout()
	get_viewport().size_changed.connect(_update_panel_size)
	Global.theme_changed.connect(_apply_colors)
	hide()


func show_panel() -> void:
	_load_layout()
	_refresh_list()
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
	_panel.custom_minimum_size = Vector2(880, 620)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(_panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	_panel.add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	root.add_child(header)
	var title := Label.new()
	title.text = "🏠 家の地图"
	title.add_theme_font_size_override("font_size", 20)
	header.add_child(title)
	var hint := Label.new()
	hint.text = "拖拽锚点调整位置（俯视图，米）"
	hint.add_theme_font_size_override("font_size", 12)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_child(hint)
	_close_button = Button.new()
	_close_button.text = "✕"
	_close_button.flat = true
	_close_button.custom_minimum_size = Vector2(36, 36)
	_close_button.pressed.connect(close_panel)
	header.add_child(_close_button)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)

	# 左：画布（俯视图）
	_canvas = Control.new()
	_canvas.custom_minimum_size = Vector2(480, 460)
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.gui_input.connect(_on_canvas_input)
	_canvas.draw.connect(_draw_canvas)
	_canvas.mouse_entered.connect(func(): _canvas.mouse_filter = Control.MOUSE_FILTER_STOP)
	body.add_child(_canvas)

	# 右：锚点列表 + 操作
	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(300, 0)
	side.add_theme_constant_override("separation", 8)
	body.add_child(side)
	var list_label := Label.new()
	list_label.text = "锚点列表"
	list_label.add_theme_font_size_override("font_size", 14)
	side.add_child(list_label)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_list)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 6)
	side.add_child(buttons)
	_add_button = Button.new()
	_add_button.text = "＋ 添加锚点"
	_add_button.custom_minimum_size = Vector2(0, 36)
	_add_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_add_button.pressed.connect(_add_anchor)
	buttons.add_child(_add_button)
	_save_button = Button.new()
	_save_button.text = "💾 保存"
	_save_button.custom_minimum_size = Vector2(0, 36)
	_save_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_button.pressed.connect(_save_layout)
	buttons.add_child(_save_button)

	_status = Label.new()
	_status.text = "加载自 user://house_layout.json"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 11)
	side.add_child(_status)
	_apply_colors()
	_update_panel_size()


func _draw_canvas() -> void:
	if not is_instance_valid(_canvas):
		return
	var data := ThemeMgr.get_current_theme_data()
	var rect := _canvas_rect()
	# 房间底
	draw_rect(rect, Color(data.bg, 0.35))
	draw_rect(rect, Color(data.text, 0.22), false, 2.0)
	# 网格（0.5m）
	var step := rect.size.x / _room_width
	for gx in range(int(_room_width * 2) + 1):
		var x := rect.position.x + gx * step * 0.5
		draw_line(Vector2(x, rect.position.y), Vector2(x, rect.position.y + rect.size.y), Color(1, 1, 1, 0.05), 1.0)
	for gz in range(int(_room_depth * 2) + 1):
		var y := rect.position.y + gz * step * 0.5
		draw_line(Vector2(rect.position.x, y), Vector2(rect.position.x + rect.size.x, y), Color(1, 1, 1, 0.05), 1.0)
	# 尺寸标签
	var size_label := "%.1f m × %.1f m" % [_room_width, _room_depth]
	draw_string(get_theme_default_font(), rect.position + Vector2(8, 18), size_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(data.secondary, 0.6))
	# 锚点
	for index in _anchors.size():
		var anchor: Dictionary = _anchors[index]
		var pos := _world_to_canvas(float(anchor.get("x", 0.0)), float(anchor.get("z", 0.0)))
		var radius := 22.0
		var color := Color("#E8C97A") if index != _selected else Color("#FFF2C5")
		if index == _hover:
			color = Color("#FFE9A8")
		draw_circle(pos, radius, Color(color, 0.22))
		draw_circle(pos, radius, Color(color, 0.9), false, 2.0)
		var icon := str(anchor.get("icon", "📍"))
		draw_string(get_theme_default_font(), pos + Vector2(-radius * 0.72, 6), icon, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(1, 1, 1, 0.95))
		# 标签
		var label := str(anchor.get("label", anchor.get("id", "")))
		draw_string(get_theme_default_font(), pos + Vector2(-radius, radius + 16), label, HORIZONTAL_ALIGNMENT_CENTER, radius * 2.0, 11, Color(data.text, 0.9))


func _on_canvas_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _dragging >= 0:
		var pos := _canvas_to_world(event.position)
		var anchor: Dictionary = _anchors[_dragging]
		anchor["x"] = roundf(clampf(pos.x, -_room_width / 2.0, _room_width / 2.0) * 10.0) / 10.0
		anchor["z"] = roundf(clampf(pos.y, -_room_depth / 2.0, _room_depth / 2.0) * 10.0) / 10.0
		_canvas.queue_redraw()
		_refresh_list()
	elif event is InputEventMouseMotion and _hover != _hit_anchor(event.position):
		_hover = _hit_anchor(event.position)
		_canvas.queue_redraw()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var hit := _hit_anchor(event.position)
		_selected = hit
		_dragging = hit if hit >= 0 else -1
		_canvas.queue_redraw()
		_refresh_list()
	elif event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = -1
	elif event is InputEventKey and event.pressed and event.keycode == KEY_DELETE and _selected >= 0:
		_anchors.remove_at(_selected)
		_selected = -1
		_canvas.queue_redraw()
		_refresh_list()
		_set_status("已删除锚点（Delete 键）")


func _hit_anchor(screen_pos: Vector2) -> int:
	for index in _anchors.size():
		var anchor: Dictionary = _anchors[index]
		var pos := _world_to_canvas(float(anchor.get("x", 0.0)), float(anchor.get("z", 0.0)))
		if screen_pos.distance_to(pos) <= 26.0:
			return index
	return -1


func _add_anchor() -> void:
	var count := _anchors.size() + 1
	var icon := ""
	for candidate in DEFAULT_ICONS:
		if not _icons_used.has(candidate):
			icon = candidate
			break
	if icon.is_empty():
		icon = "📍"
	_icons_used[icon] = true
	_anchors.append({
		"id": "anchor%d" % count,
		"label": "锚点%d" % count,
		"x": 0.0, "z": 0.0, "icon": icon,
	})
	_selected = _anchors.size() - 1
	_canvas.queue_redraw()
	_refresh_list()
	_set_status("已添加锚点，拖拽到合适位置")


func _refresh_list() -> void:
	for child in _list.get_children():
		child.queue_free()
	for index in _anchors.size():
		var anchor: Dictionary = _anchors[index]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var icon_label := Label.new()
		icon_label.text = str(anchor.get("icon", "📍"))
		icon_label.custom_minimum_size = Vector2(30, 0)
		row.add_child(icon_label)
		var name_label := Label.new()
		name_label.text = "%s  (%.1f, %.1f)" % [
			str(anchor.get("label", anchor.get("id", ""))),
			float(anchor.get("x", 0.0)), float(anchor.get("z", 0.0)),
		]
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_label)
		var select_btn := Button.new()
		select_btn.text = "选择"
		select_btn.flat = true
		select_btn.custom_minimum_size = Vector2(52, 28)
		select_btn.pressed.connect(func(): _select_from_list(index))
		row.add_child(select_btn)
		_list.add_child(row)


func _select_from_list(index: int) -> void:
	_selected = index
	_canvas.queue_redraw()
	_refresh_list()


func _save_layout() -> void:
	var payload := {
		"version": 1,
		"room_width": _room_width,
		"room_depth": _room_depth,
		"anchors": _anchors.duplicate(true),
	}
	var file := FileAccess.open(LAYOUT_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(payload, "  "))
		file.close()
		_set_status("已保存到 user://house_layout.json（%d 个锚点）" % _anchors.size())
	else:
		_set_status("保存失败：无法写入 user://", true)


func _load_layout() -> void:
	_anchors.clear()
	_icons_used.clear()
	if not FileAccess.file_exists(LAYOUT_PATH):
		_set_status("暂无自定义布局，运行时使用默认锚点")
		return
	var file := FileAccess.open(LAYOUT_PATH, FileAccess.READ)
	if file:
		var parsed = JSON.parse_string(file.get_as_text())
		file.close()
		if parsed is Dictionary:
			var data: Dictionary = parsed
			_room_width = maxf(3.0, float(data.get("room_width", 6.0)))
			_room_depth = maxf(3.0, float(data.get("room_depth", 5.0)))
			var raw_anchors = data.get("anchors", [])
			if raw_anchors is Array:
				for raw in raw_anchors:
					if raw is Dictionary:
						var a: Dictionary = raw
						_anchors.append({
							"id": str(a.get("id", "")),
							"label": str(a.get("label", a.get("id", ""))),
							"x": float(a.get("x", 0.0)),
							"z": float(a.get("z", 0.0)),
							"icon": str(a.get("icon", "📍")),
						})
						_icons_used[str(a.get("icon", "📍"))] = true
		_set_status("已加载 %d 个锚点" % _anchors.size())


func _set_status(text: String, is_error := false) -> void:
	if not is_instance_valid(_status):
		return
	_status.text = text
	var data := ThemeMgr.get_current_theme_data()
	_status.add_theme_color_override("font_color", Color("#D9534F" if is_error else data.secondary, 0.85))


func _on_scrim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		close_panel()


func _apply_colors(_data: Dictionary = {}) -> void:
	if not is_instance_valid(_panel):
		return
	var data := ThemeMgr.get_current_theme_data()
	_panel.add_theme_stylebox_override("panel", _style(Color(data.bg, 0.98), Color(data.text, 0.14), 8, 0))


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
		minf(880.0, viewport.x - 24.0),
		minf(620.0, viewport.y - 24.0)
	)


func _canvas_rect() -> Rect2:
	var size := _canvas.size - Vector2(28, 40)
	var origin := Vector2(14, 20)
	return Rect2(origin, size)


func _world_to_canvas(world_x: float, world_z: float) -> Vector2:
	var rect := _canvas_rect()
	var scale := rect.size.x / _room_width
	return rect.position + Vector2(
		(world_x + _room_width / 2.0) * scale,
		(world_z + _room_depth / 2.0) * scale
	)


func _canvas_to_world(screen: Vector2) -> Vector2:
	var rect := _canvas_rect()
	var scale := rect.size.x / _room_width
	return Vector2(
		(screen.x - rect.position.x) / scale - _room_width / 2.0,
		(screen.y - rect.position.y) / scale - _room_depth / 2.0
	)
