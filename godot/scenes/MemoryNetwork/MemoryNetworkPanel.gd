extends Control

signal closed

const GRAPH_CANVAS := preload("res://scenes/MemoryNetwork/MemoryGraphCanvas.gd")
const SCOPE_NAMES := {"*": "共享记忆", "ling": "小玲", "nai": "小奈"}
const KIND_NAMES := {
	"episodic": "经历",
	"semantic": "事实",
	"relationship": "关系",
	"preference": "偏好",
	"identity": "身份",
	"routine": "习惯",
	"worldbook": "世界设定",
}

var _background: ColorRect
var _sheet: PanelContainer
var _body: BoxContainer
var _canvas: MemoryGraphCanvas
var _detail_panel: PanelContainer
var _scope_select: OptionButton
var _search_input: LineEdit
var _strength_slider: HSlider
var _strength_label: Label
var _status: Label
var _empty_state: Label
var _detail_title: Label
var _detail_meta: Label
var _detail_content: RichTextLabel
var _detail_keywords: Label
var _related_list: VBoxContainer
var _search_timer: Timer
var _graph: Dictionary = {}
var _selected_node_id := ""
var _load_generation := 0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_interface()
	Global.theme_changed.connect(_on_theme_changed)
	get_viewport().size_changed.connect(_apply_responsive_layout)
	hide()


func show_panel() -> void:
	show()
	move_to_front()
	modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 1.0, 0.18)
	_search_input.grab_focus()
	_load_graph()


func close_panel() -> void:
	_load_generation += 1
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 0.13)
	await tween.finished
	hide()
	closed.emit()


func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close_panel()
		get_viewport().set_input_as_handled()


func _build_interface() -> void:
	_background = ColorRect.new()
	_background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_background.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_background)

	var outer_margin := MarginContainer.new()
	outer_margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		outer_margin.add_theme_constant_override("margin_%s" % side, 14)
	add_child(outer_margin)

	_sheet = PanelContainer.new()
	_sheet.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sheet.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer_margin.add_child(_sheet)

	var content_margin := MarginContainer.new()
	content_margin.add_theme_constant_override("margin_left", 16)
	content_margin.add_theme_constant_override("margin_right", 16)
	content_margin.add_theme_constant_override("margin_top", 12)
	content_margin.add_theme_constant_override("margin_bottom", 12)
	_sheet.add_child(content_margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 10)
	content_margin.add_child(content)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 9)
	content.add_child(header)
	var title := Label.new()
	title.text = "🧶  心织记忆网络"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 20)
	header.add_child(title)
	var legend := RichTextLabel.new()
	legend.bbcode_enabled = true
	legend.fit_content = true
	legend.scroll_active = false
	legend.custom_minimum_size = Vector2(194, 28)
	legend.text = "[color=#C9A64B]●[/color] 共享   [color=#3D9F91]●[/color] 小玲   [color=#CE7899]●[/color] 小奈"
	legend.tooltip_text = "金色为共享记忆，青绿色为小玲记忆，粉色为小奈记忆；节点越大表示重要度越高。"
	legend.add_theme_font_size_override("font_size", 11)
	header.add_child(legend)
	var reset_button := Button.new()
	reset_button.text = "⌂"
	reset_button.tooltip_text = "重置网络视角"
	reset_button.flat = true
	reset_button.custom_minimum_size = Vector2(36, 34)
	reset_button.pressed.connect(func(): _canvas.reset_view())
	header.add_child(reset_button)
	var refresh_button := Button.new()
	refresh_button.text = "↻"
	refresh_button.tooltip_text = "重新计算记忆关系"
	refresh_button.flat = true
	refresh_button.custom_minimum_size = Vector2(36, 34)
	refresh_button.pressed.connect(_load_graph)
	header.add_child(refresh_button)
	var close_button := Button.new()
	close_button.text = "✕"
	close_button.tooltip_text = "关闭记忆网络"
	close_button.flat = true
	close_button.custom_minimum_size = Vector2(36, 34)
	close_button.pressed.connect(close_panel)
	header.add_child(close_button)

	var filters := HFlowContainer.new()
	filters.add_theme_constant_override("h_separation", 8)
	filters.add_theme_constant_override("v_separation", 8)
	content.add_child(filters)
	_scope_select = OptionButton.new()
	_scope_select.custom_minimum_size = Vector2(132, 34)
	_add_scope_option("全部记忆", "")
	_add_scope_option("共享记忆", "*")
	_add_scope_option("🐾 仅小玲", "ling")
	_add_scope_option("🐇 仅小奈", "nai")
	_scope_select.item_selected.connect(func(_index: int): _load_graph())
	filters.add_child(_scope_select)
	_search_input = LineEdit.new()
	_search_input.placeholder_text = "搜索记忆标题或内容"
	_search_input.clear_button_enabled = true
	_search_input.custom_minimum_size = Vector2(250, 34)
	_search_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search_input.text_changed.connect(func(_text: String): _search_timer.start())
	_search_input.text_submitted.connect(func(_text: String): _load_graph())
	filters.add_child(_search_input)
	var search_button := Button.new()
	search_button.text = "🔍"
	search_button.tooltip_text = "搜索记忆网络"
	search_button.custom_minimum_size = Vector2(42, 34)
	search_button.pressed.connect(_load_graph)
	filters.add_child(search_button)
	_strength_label = Label.new()
	_strength_label.text = "关联 ≥ 0.55"
	_strength_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_strength_label.custom_minimum_size = Vector2(82, 34)
	filters.add_child(_strength_label)
	_strength_slider = HSlider.new()
	_strength_slider.min_value = 0.2
	_strength_slider.max_value = 0.9
	_strength_slider.step = 0.01
	_strength_slider.value = 0.55
	_strength_slider.custom_minimum_size = Vector2(132, 34)
	_strength_slider.value_changed.connect(_on_strength_changed)
	filters.add_child(_strength_slider)

	_body = BoxContainer.new()
	_body.vertical = false
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 10)
	content.add_child(_body)

	_canvas = GRAPH_CANVAS.new()
	_canvas.name = "MemoryGraphCanvas"
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.custom_minimum_size = Vector2(460, 360)
	_canvas.node_selected.connect(_show_node_details)
	_body.add_child(_canvas)
	_empty_state = Label.new()
	_empty_state.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_empty_state.text = "正在读取心织记忆……"
	_empty_state.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_state.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty_state.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_empty_state.add_theme_font_size_override("font_size", 15)
	_canvas.add_child(_empty_state)

	_detail_panel = PanelContainer.new()
	_detail_panel.custom_minimum_size = Vector2(318, 0)
	_detail_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(_detail_panel)
	var detail_margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		detail_margin.add_theme_constant_override("margin_%s" % side, 14)
	_detail_panel.add_child(detail_margin)
	var detail := VBoxContainer.new()
	detail.add_theme_constant_override("separation", 9)
	detail_margin.add_child(detail)
	_detail_title = Label.new()
	_detail_title.text = "选择一条记忆"
	_detail_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_title.add_theme_font_size_override("font_size", 17)
	detail.add_child(_detail_title)
	_detail_meta = Label.new()
	_detail_meta.text = "点击节点查看它与其他记忆的联系"
	_detail_meta.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_meta.add_theme_font_size_override("font_size", 11)
	detail.add_child(_detail_meta)
	var separator := HSeparator.new()
	detail.add_child(separator)
	_detail_content = RichTextLabel.new()
	_detail_content.bbcode_enabled = false
	_detail_content.selection_enabled = true
	_detail_content.fit_content = false
	_detail_content.custom_minimum_size = Vector2(0, 120)
	_detail_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for font_size_key in ["normal_font_size", "bold_font_size", "italics_font_size", "bold_italics_font_size", "mono_font_size"]:
		_detail_content.add_theme_font_size_override(font_size_key, 13)
	detail.add_child(_detail_content)
	_detail_keywords = Label.new()
	_detail_keywords.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_keywords.add_theme_font_size_override("font_size", 11)
	detail.add_child(_detail_keywords)
	var related_title := Label.new()
	related_title.text = "关联记忆"
	related_title.add_theme_font_size_override("font_size", 13)
	detail.add_child(related_title)
	var related_scroll := ScrollContainer.new()
	related_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	related_scroll.custom_minimum_size = Vector2(0, 116)
	related_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail.add_child(related_scroll)
	_related_list = VBoxContainer.new()
	_related_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_related_list.add_theme_constant_override("separation", 4)
	related_scroll.add_child(_related_list)

	_status = Label.new()
	_status.text = "等待加载"
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status.add_theme_font_size_override("font_size", 11)
	content.add_child(_status)

	_search_timer = Timer.new()
	_search_timer.one_shot = true
	_search_timer.wait_time = 0.32
	_search_timer.timeout.connect(_load_graph)
	add_child(_search_timer)
	_apply_theme()
	_apply_responsive_layout()


func _load_graph() -> void:
	_load_generation += 1
	var generation := _load_generation
	_status.text = "正在整理记忆之间的联系……"
	_empty_state.text = "正在读取心织记忆……"
	_empty_state.show()
	var result: Dictionary = await CompanionCore.get_heartloom_graph(
		_selected_scope(),
		_search_input.text,
		100
	)
	if generation != _load_generation or not is_inside_tree():
		return
	if not bool(result.get("ok", false)):
		_graph = {}
		_canvas.set_graph({})
		_empty_state.text = "无法读取记忆网络\n%s" % str(result.get("message", "Companion Core 请求失败"))
		_status.text = "加载失败"
		_status.add_theme_color_override("font_color", Color("#D9534F"))
		_clear_details()
		return
	var data = result.get("data", {})
	if not data is Dictionary:
		_empty_state.text = "Companion Core 返回了无效的记忆网络"
		_status.text = "加载失败"
		return
	# /heartloom/graph 契约(v2)字段映射到画布结构:
	# memory_id→id、summary→content、edges 的 src/dst→source/target
	var mapped_nodes: Array = []
	var raw_nodes = data.get("nodes", [])
	if raw_nodes is Array:
		for node_variant in raw_nodes:
			if not node_variant is Dictionary:
				continue
			var node: Dictionary = (node_variant as Dictionary).duplicate(true)
			node["id"] = str(node.get("memory_id", ""))
			node["content"] = str(node.get("summary", ""))
			mapped_nodes.append(node)
	var mapped_edges: Array = []
	var raw_edges = data.get("edges", [])
	if raw_edges is Array:
		for edge_variant in raw_edges:
			if not edge_variant is Dictionary:
				continue
			var edge: Dictionary = (edge_variant as Dictionary).duplicate(true)
			edge["source"] = str(edge.get("src", ""))
			edge["target"] = str(edge.get("dst", ""))
			edge["strength"] = float(edge.get("link_strength", 0.5))
			mapped_edges.append(edge)
	_graph = {"nodes": mapped_nodes, "edges": mapped_edges}
	_canvas.set_graph(_graph)
	_canvas.set_min_strength(float(_strength_slider.value))
	var node_count := int(data.get("node_count", 0))
	_empty_state.visible = node_count == 0
	_empty_state.text = "没有匹配的长期记忆" if node_count == 0 else ""
	_update_summary_status(node_count, node_count, mapped_edges.size(), 0)
	_status.add_theme_color_override("font_color", Color(ThemeMgr.get_current_theme_data().secondary, 0.82))
	_selected_node_id = ""
	_clear_details()


func _show_node_details(node: Dictionary) -> void:
	_selected_node_id = str(node.get("id", ""))
	_detail_title.text = str(node.get("title", "未命名记忆"))
	var scope := str(node.get("scope_role_id", "*"))
	var kind := str(node.get("kind", "episodic"))
	var bucket_names := {"high": "高", "normal": "中", "low": "低"}
	var importance_label := str(
		bucket_names.get(str(node.get("importance_bucket", "normal")), "中")
	)
	_detail_meta.text = "%s · %s · 重要度：%s\n世界第 %.1f 天" % [
		str(SCOPE_NAMES.get(scope, scope)),
		str(KIND_NAMES.get(kind, kind)),
		importance_label,
		float(node.get("world_updated_at", 0.0)),
	]
	_detail_content.text = str(node.get("content", ""))
	var keywords: Array[String] = []
	for item in node.get("keywords", []):
		var keyword := str(item)
		if not keyword.is_empty() and keyword not in keywords:
			keywords.append(keyword)
	_detail_keywords.text = "主题：%s" % ("、".join(keywords) if not keywords.is_empty() else "尚未提取")
	_rebuild_related_memories(_selected_node_id)


func _rebuild_related_memories(node_id: String) -> void:
	for child in _related_list.get_children():
		child.queue_free()
	var related: Array[Dictionary] = []
	var raw_edges = _graph.get("edges", [])
	if raw_edges is Array:
		for edge_variant in raw_edges:
			if not edge_variant is Dictionary:
				continue
			var edge: Dictionary = edge_variant
			var source := str(edge.get("source", ""))
			var target := str(edge.get("target", ""))
			if source != node_id and target != node_id:
				continue
			var other_id := target if source == node_id else source
			var other := _canvas.get_node_by_id(other_id)
			if other.is_empty():
				continue
			related.append({"node": other, "edge": edge})
	related.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float((a.edge as Dictionary).get("strength", 0.0)) > float((b.edge as Dictionary).get("strength", 0.0))
	)
	if related.is_empty():
		var empty := Label.new()
		empty.text = "尚未发现足够明确的联系"
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.add_theme_font_size_override("font_size", 11)
		empty.add_theme_color_override("font_color", Color(ThemeMgr.get_current_theme_data().secondary, 0.82))
		_related_list.add_child(empty)
		return
	for item in related:
		var other: Dictionary = item.node
		var edge: Dictionary = item.edge
		var button := Button.new()
		button.text = "↗  %s  ·  %.0f%%" % [
			str(other.get("display_title", other.get("title", "未命名记忆"))),
			float(edge.get("strength", 0.0)) * 100.0,
		]
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.flat = true
		button.add_theme_font_size_override("font_size", 11)
		button.add_theme_color_override("font_color", Color(ThemeMgr.get_current_theme_data().text))
		button.add_theme_color_override("font_hover_color", Color(ThemeMgr.get_current_theme_data().text))
		button.tooltip_text = "；".join(edge.get("reasons", []))
		button.pressed.connect(func(): _canvas.select_node_by_id(str(other.get("id", ""))))
		_related_list.add_child(button)


func _clear_details() -> void:
	_detail_title.text = "选择一条记忆"
	_detail_meta.text = "点击节点查看它与其他记忆的联系"
	_detail_content.text = ""
	_detail_keywords.text = ""
	for child in _related_list.get_children():
		child.queue_free()


func _on_strength_changed(value: float) -> void:
	_strength_label.text = "关联 ≥ %.2f" % value
	_canvas.set_min_strength(value)
	var summary_variant = _graph.get("summary", {})
	if summary_variant is Dictionary:
		var summary: Dictionary = summary_variant
		_update_summary_status(
			int(summary.get("node_count", 0)),
			int(summary.get("available_node_count", summary.get("node_count", 0))),
			int(summary.get("edge_count", 0)),
			int(summary.get("isolated_node_count", 0))
		)


func _update_summary_status(node_count: int, available_count: int, edge_count: int, isolated: int) -> void:
	var visible_edges := _canvas.get_visible_edge_count() if is_instance_valid(_canvas) else edge_count
	_status.text = "%s · 显示 %d / %d 条联系%s" % [
		("显示 %d / %d 条记忆" % [node_count, available_count]) if available_count > node_count else ("%d 条记忆" % node_count),
		visible_edges,
		edge_count,
		" · %d 条暂未建立联系" % isolated if isolated > 0 else "",
	]


func _add_scope_option(label: String, metadata: String) -> void:
	var index := _scope_select.item_count
	_scope_select.add_item(label)
	_scope_select.set_item_metadata(index, metadata)


func _selected_scope() -> String:
	if _scope_select.selected < 0:
		return ""
	return str(_scope_select.get_item_metadata(_scope_select.selected))


func _format_time(timestamp: int) -> String:
	if timestamp <= 0:
		return "时间未知"
	return Time.get_datetime_string_from_unix_time(timestamp, true)


func _apply_responsive_layout() -> void:
	if not is_instance_valid(_body):
		return
	var narrow := get_viewport_rect().size.x < 840.0
	_body.vertical = narrow
	_detail_panel.custom_minimum_size = Vector2(0, 220) if narrow else Vector2(318, 0)
	_canvas.custom_minimum_size = Vector2(340, 300) if narrow else Vector2(460, 360)


func _on_theme_changed(_theme_data: Dictionary) -> void:
	_apply_theme()


func _apply_theme() -> void:
	var data := ThemeMgr.get_current_theme_data()
	var background := Color(str(data.bg))
	var text := Color(str(data.text))
	var secondary := Color(str(data.secondary))
	_background.color = background
	_sheet.add_theme_stylebox_override("panel", _style(Color(background, 0.99), Color(text, 0.14), 6))
	_detail_panel.add_theme_stylebox_override("panel", _style(Color(1, 1, 1, 0.035), Color(text, 0.12), 5))
	_apply_readable_colors(_sheet, text, secondary)
	_detail_meta.add_theme_color_override("font_color", Color(secondary, 0.86))
	_detail_keywords.add_theme_color_override("font_color", Color(secondary, 0.92))
	_empty_state.add_theme_color_override("font_color", Color(secondary, 0.82))
	_canvas.set_palette(data)


func _apply_readable_colors(node: Node, text: Color, secondary: Color) -> void:
	if node is Label:
		(node as Label).add_theme_color_override("font_color", text)
	elif node is Button:
		var button := node as Button
		button.add_theme_color_override("font_color", text)
		button.add_theme_color_override("font_hover_color", text)
		button.add_theme_color_override("font_pressed_color", text)
		button.add_theme_color_override("font_disabled_color", Color(secondary, 0.72))
	elif node is LineEdit:
		var input := node as LineEdit
		input.add_theme_color_override("font_color", text)
		input.add_theme_color_override("font_focus_color", text)
		input.add_theme_color_override("font_placeholder_color", Color(secondary, 0.88))
	elif node is OptionButton:
		var option := node as OptionButton
		option.add_theme_color_override("font_color", text)
		option.add_theme_color_override("font_hover_color", text)
		option.add_theme_color_override("font_pressed_color", text)
	elif node is RichTextLabel:
		(node as RichTextLabel).add_theme_color_override("default_color", text)
	for child in node.get_children():
		_apply_readable_colors(child, text, secondary)


func _style(background: Color, border: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	return style
