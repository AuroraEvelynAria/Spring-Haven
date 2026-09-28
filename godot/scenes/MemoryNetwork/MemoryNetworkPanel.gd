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
var _time_slider: HSlider
var _time_label: Label
var _status: Label
var _empty_state: Label
var _detail_title: Label
var _detail_meta: Label
var _detail_content: RichTextLabel
var _detail_keywords: Label
var _related_title: Label
var _related_list: VBoxContainer
var _search_timer: Timer
var _time_pins: MemoryTimePins
var _decay_curve: MemoryDecayCurve
var _graph: Dictionary = {}
var _selected_node_id := ""
var _load_generation := 0
var _world_now := 0.0
# 时间轴状态:true = 跟随「现在」(实时态);用户拨动滑杆后转 false(回溯态)。
# 不能靠"值是否等于最大值"判断 —— 滑杆 step=0.1 会把吸附后的值卡在
# 最大值之下,导致一打开就误判为回溯、整图变幽灵
var _time_following_now := true


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
	# 默认只画强关联(与标签一致);悬停聚焦时弱连接仍会展开
	_strength_slider.value = 0.55
	_strength_slider.custom_minimum_size = Vector2(132, 34)
	_strength_slider.value_changed.connect(_on_strength_changed)
	filters.add_child(_strength_slider)

	# ADR-010:世界日时间滑杆 —— 拨回过去看心智生长,拖动结束才请求
	var time_row := HBoxContainer.new()
	time_row.add_theme_constant_override("separation", 8)
	content.add_child(time_row)
	_time_label = Label.new()
	_time_label.text = "时间 · 现在"
	_time_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_time_label.custom_minimum_size = Vector2(120, 30)
	_time_label.tooltip_text = "把心织图谱拨回过去：只显示那一刻已经存在的记忆与联系。"
	_time_label.add_theme_font_size_override("font_size", 12)
	time_row.add_child(_time_label)
	_time_slider = HSlider.new()
	_time_slider.min_value = 0.0
	_time_slider.max_value = 1.0
	_time_slider.step = 0.1
	_time_slider.value = 1.0
	_time_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_time_slider.custom_minimum_size = Vector2(180, 30)
	_time_slider.value_changed.connect(_on_time_value_changed)
	time_row.add_child(_time_slider)
	var now_button := Button.new()
	now_button.text = "现在"
	now_button.tooltip_text = "回到当前心智"
	now_button.custom_minimum_size = Vector2(56, 30)
	now_button.pressed.connect(_snap_time_to_now)
	time_row.add_child(now_button)
	# 章节钉:夜织/周织/季织与里程碑按诞生世界日排成书签条(悬停显摘要,点击跳转)
	_time_pins = MemoryTimePins.new()
	_time_pins.custom_minimum_size = Vector2(0, 16)
	_time_pins.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_time_pins.pin_selected.connect(_on_pin_selected)
	content.add_child(_time_pins)

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
	# ADR-014 消费侧:所选记忆的艾宾浩斯 R(t) 曲线(仅记忆节点显示)
	_decay_curve = MemoryDecayCurve.new()
	_decay_curve.custom_minimum_size = Vector2(0, 58)
	_decay_curve.visible = false
	detail.add_child(_decay_curve)
	_detail_keywords = Label.new()
	_detail_keywords.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_keywords.add_theme_font_size_override("font_size", 11)
	detail.add_child(_detail_keywords)
	_related_title = Label.new()
	_related_title.text = "关联记忆"
	_related_title.add_theme_font_size_override("font_size", 13)
	detail.add_child(_related_title)
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
	# ADR-010(修订):时间滑杆纯客户端调光 —— 始终加载全量图谱,
	# 拖动滑杆只改画布亮度,不发请求、不重排布局
	# ADR-015:并载实体星座(实体节点细环 + claim 边)
	var result: Dictionary = await CompanionCore.get_heartloom_graph(
		_selected_scope(),
		_search_input.text,
		200,
		"",
		-1.0,
		true
	)
	if generation != _load_generation or not is_inside_tree():
		return
	if not bool(result.get("ok", false)):
		_graph = {}
		_canvas.set_graph({})
		_empty_state.text = "无法读取记忆网络\n%s" % str(result.get("message", "Companion Core 请求失败"))
		_status.text = "加载失败"
		_status.add_theme_color_override("font_color", ThemeMgr.SEMANTIC_DANGER)
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
			# ADR-015:实体节点用 node_id(entity_id);记忆节点回退 memory_id
			node["id"] = str(node.get("node_id", node.get("memory_id", "")))
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
	# ADR-010:用响应里的世界时间量程校准滑杆(earliest→world_now,恒定量程)
	var world_now := float(data.get("world_now", 0.0))
	_world_now = world_now
	var earliest := 0.0
	var latest := maxf(world_now, 1.0)
	var world_range_variant = data.get("world_range", {})
	if world_range_variant is Dictionary:
		var world_range: Dictionary = world_range_variant
		earliest = float(world_range.get("earliest", 0.0))
		latest = maxf(world_now, earliest + 1.0)
		# 改 min/max/step 会让 Range 重新量化并触发 value_changed(会把
		# 「跟随现在」误置为 false),所以先快照意图、配好量程后再恢复
		var follow_now := _time_following_now
		_time_slider.min_value = earliest
		_time_slider.max_value = latest
		_time_slider.step = 0.1
		# 软边渐变带宽度 ≈ 时间线总量的 3%(限制在 1~45 世界日)
		_canvas.set_time_fade_days(clampf((latest - earliest) * 0.03, 1.0, 45.0))
		_time_following_now = follow_now
		if _time_following_now:
			# 跟着「现在」:每次加载都把滑杆贴到最新量程右端
			_time_slider.set_value_no_signal(latest)
		_update_time_label(_time_slider.value)
	# 章节钉:织结节/周反思/里程碑 → 时间轴书签(纯客户端,随图重建)
	_time_pins.set_range(earliest, latest)
	_time_pins.set_pins(_collect_chapter_pins())
	# 游标必须在滑杆量程校准/首开吸附之后再取值——否则画布停在滑杆初值上
	# (实测首开会停在"世界第 2 天"的幽灵态)
	_time_pins.set_cursor(_current_cursor_value())
	_canvas.set_time_cursor(_current_cursor_value())
	var node_count := int(data.get("node_count", 0))
	_empty_state.visible = node_count == 0
	_empty_state.text = "没有匹配的长期记忆" if node_count == 0 else ""
	_update_summary_status(node_count, node_count, mapped_edges.size(), 0)
	_status.add_theme_color_override("font_color", Color(ThemeMgr.get_current_theme_data().secondary, 0.82))
	_selected_node_id = ""
	_clear_details()


func _show_node_details(node: Dictionary) -> void:
	_selected_node_id = str(node.get("id", ""))
	if str(node.get("node_type", "memory")) == "entity":
		_show_entity_details(node)
		return
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
	_related_title.text = "关联记忆"
	# ADR-014:遗忘曲线跟随所选记忆(与召回打分同款双参数公式)
	_decay_curve.set_series({
		"half_life_days": float(node.get("half_life_days", 0.0)),
		"intrinsic": float(node.get("intrinsic", 1.0)),
		"world_updated_at": float(node.get("world_updated_at", 0.0)),
		"world_now": _world_now,
	})
	_decay_curve.visible = true
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


func _show_entity_details(node: Dictionary) -> void:
	_decay_curve.visible = false
	var kind_names := {"person": "人物", "object": "器物", "place": "地点", "event": "事件", "concept": "概念"}
	_detail_title.text = str(node.get("name", "未名实体"))
	_detail_meta.text = "%s · 首次相遇 世界第 %.1f 天\n现行主张 %d 条" % [
		str(kind_names.get(str(node.get("kind", "concept")), "概念")),
		float(node.get("world_created_at", 0.0)),
		int(node.get("claim_count", 0)),
	]
	var aliases: Array[String] = []
	for item in node.get("aliases", []):
		var alias := str(item)
		if not alias.is_empty():
			aliases.append(alias)
	_detail_content.text = ("别名：%s" % "、".join(aliases)) if not aliases.is_empty() else "由主张与出处记忆勾勒出的存在。"
	_detail_keywords.text = "生命线：点下方条目可在图谱中跳转"
	_related_title.text = "生命线 · 主张与出处"
	_rebuild_entity_lifeline(_selected_node_id)


func _rebuild_entity_lifeline(entity_id: String) -> void:
	for child in _related_list.get_children():
		child.queue_free()
	var claims: Array[Dictionary] = []
	var sources: Array[Dictionary] = []
	var raw_edges = _graph.get("edges", [])
	if raw_edges is Array:
		for edge_variant in raw_edges:
			if not edge_variant is Dictionary:
				continue
			var edge: Dictionary = edge_variant
			var source := str(edge.get("source", ""))
			var target := str(edge.get("target", ""))
			if source != entity_id and target != entity_id:
				continue
			var link_type := str(edge.get("link_type", ""))
			var other_id := target if source == entity_id else source
			var other := _canvas.get_node_by_id(other_id)
			if other.is_empty():
				continue
			if link_type == "claim":
				claims.append({"node": other, "edge": edge})
			elif link_type == "claim_source":
				sources.append({"node": other, "edge": edge})
	if claims.is_empty() and sources.is_empty():
		var empty := Label.new()
		empty.text = "这张星座还没有连线"
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.add_theme_font_size_override("font_size", 11)
		empty.add_theme_color_override("font_color", Color(ThemeMgr.get_current_theme_data().secondary, 0.82))
		_related_list.add_child(empty)
		return
	var text := Color(ThemeMgr.get_current_theme_data().text)
	for item in claims:
		var other: Dictionary = item.node
		var edge: Dictionary = item.edge
		var world_to_variant = edge.get("world_to")
		var state_label := "现行" if world_to_variant == null else "已于第 %d 天改变" % int(float(world_to_variant))
		var button := Button.new()
		button.text = "〔主张〕%s → %s · %s" % [
			str(edge.get("predicate", "")),
			str(other.get("name", "未名实体")),
			state_label,
		]
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.flat = true
		button.add_theme_font_size_override("font_size", 11)
		button.add_theme_color_override("font_color", text)
		button.add_theme_color_override("font_hover_color", text)
		var object_text := str(edge.get("object_text", ""))
		button.tooltip_text = object_text if not object_text.is_empty() else state_label
		button.pressed.connect(func(): _canvas.select_node_by_id(str(other.get("id", ""))))
		_related_list.add_child(button)
	for item in sources:
		var other: Dictionary = item.node
		var edge: Dictionary = item.edge
		var button := Button.new()
		button.text = "〔出处〕%s" % str(other.get("display_title", other.get("title", "未命名记忆")))
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.flat = true
		button.add_theme_font_size_override("font_size", 11)
		button.add_theme_color_override("font_color", text)
		button.add_theme_color_override("font_hover_color", text)
		button.tooltip_text = "跳到这段记忆 · %s" % str(edge.get("predicate", ""))
		button.pressed.connect(func(): _canvas.select_node_by_id(str(other.get("id", ""))))
		_related_list.add_child(button)


func _collect_chapter_pins() -> Array[Dictionary]:
	var pins: Array[Dictionary] = []
	for node_variant in _graph.get("nodes", []):
		if not node_variant is Dictionary:
			continue
		var node: Dictionary = node_variant
		if str(node.get("node_type", "memory")) != "memory":
			continue
		var source := str(node.get("source", ""))
		var pin_kind := ""
		if source.begins_with("consolidation_") or source == "season_weave":
			pin_kind = "weave"
		elif source == "weekly_insight":
			pin_kind = "weekly"
		elif source == "milestone":
			pin_kind = "milestone"
		if pin_kind.is_empty():
			continue
		pins.append({
			"day": float(node.get("world_created_at", 0.0)),
			"title": str(node.get("display_title", node.get("title", ""))),
			"kind": pin_kind,
		})
	pins.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.day) < float(b.day)
	)
	if pins.size() > 60:
		var trimmed: Array[Dictionary] = []
		for index in range(pins.size() - 60, pins.size()):
			trimmed.append(pins[index])
		pins = trimmed
	return pins


func _on_pin_selected(day: float) -> void:
	_time_slider.set_value(day)


func _clear_details() -> void:
	_detail_title.text = "选择一条记忆"
	_detail_meta.text = "点击节点查看它与其他记忆的联系"
	_detail_content.text = ""
	_detail_keywords.text = ""
	_related_title.text = "关联记忆"
	_decay_curve.visible = false
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


func _update_time_label(value: float) -> void:
	if _time_slider == null:
		return
	if _time_following_now or value >= _time_slider.max_value - 0.06:
		_time_label.text = "时间 · 现在"
	else:
		_time_label.text = "时间 · 世界第 %d 天" % (int(value) + 1)


func _current_cursor_value() -> float:
	"""跟随「现在」时返回 -1(实时态,全部点亮);否则返回世界日(回溯态)。"""
	if _time_slider == null or _time_following_now:
		return -1.0
	if _time_slider.value >= _time_slider.max_value - 0.06:
		return -1.0
	return float(_time_slider.value)


func _on_time_value_changed(value: float) -> void:
	# 纯客户端调光:不发请求、不重排,画布只改亮度
	_time_following_now = value >= _time_slider.max_value - 0.06
	_update_time_label(value)
	if _canvas != null:
		_canvas.set_time_cursor(_current_cursor_value())
	if _time_pins != null:
		_time_pins.set_cursor(_current_cursor_value())


func _snap_time_to_now() -> void:
	_time_following_now = true
	_time_slider.set_value_no_signal(_time_slider.max_value)
	_update_time_label(_time_slider.max_value)
	_canvas.set_time_cursor(-1.0)
	_time_pins.set_cursor(-1.0)


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
	if _time_pins != null:
		_time_pins.set_palette(data)
	if _decay_curve != null:
		_decay_curve.set_palette(data)


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
