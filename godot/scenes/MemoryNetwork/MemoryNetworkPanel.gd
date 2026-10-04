extends Control

signal closed

const GRAPH_CANVAS := preload("res://scenes/MemoryNetwork/MemoryGraphCanvas.gd")
const LINE_ICON_BUTTON := preload("res://scripts/ui/LineIconButton.gd")
const SCOPE_NAMES := {"*": "共享记忆", "ling": "小玲", "nai": "小奈"}
# 低于这个宽度就不再并排:改成"画布聚焦 / 详情聚焦"二选一。
const NARROW_WIDTH := 840.0
# 观察台形态:外框保留庭院氛围,但图内容区与详情卡必须是实心的,
# 否则节点、标签和连线会跟底下的 GameWorld 糊在一起。
const SCRIM_ALPHA := 0.55
const SHEET_ALPHA := 0.88
const PLATE_ALPHA := 0.97
const DETAIL_ALPHA := 0.96
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
var _canvas_plate: PanelContainer
var _canvas: MemoryGraphCanvas
var _detail_panel: PanelContainer
var _detail_back_button: Button
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
var _stat_row: HBoxContainer
var _stat_value_labels: Array[Label] = []
var _stat_caption_labels: Array[Label] = []
var _decay_title: Label
var _last_retention := -1.0
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
var _theme_source: Node


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_interface()
	_theme_source = get_node_or_null("/root/Global")
	if is_instance_valid(_theme_source) and _theme_source.has_signal("theme_changed"):
		_theme_source.theme_changed.connect(_on_theme_changed)
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
	_background.color = Color(0, 0, 0, 0.34)
	add_child(_background)

	var outer_margin := MarginContainer.new()
	outer_margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		outer_margin.add_theme_constant_override("margin_%s" % side, 14)
	add_child(outer_margin)

	_sheet = PanelContainer.new()
	_sheet.name = "MemoryObservationSheet"
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
	title.text = "心织记忆网络"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 20)
	header.add_child(title)
	var legend := RichTextLabel.new()
	legend.bbcode_enabled = true
	legend.fit_content = true
	legend.scroll_active = false
	legend.custom_minimum_size = Vector2(268, 28)
	# 颜色必须与 MemoryGraphCanvas.DEFAULT_SCOPE_COLORS 逐字一致:
	# 图例与图里的点对不上色,比没有图例更误导。
	legend.text = "[color=#E8C97A]●[/color] 共享  [color=#72C7B8]●[/color] 小玲  [color=#E6A4BD]●[/color] 小奈  [color=#9A93A8]○[/color] 实体"
	legend.tooltip_text = "金=共享记忆，青=小玲，粉=小奈；空心环=实体，实心圆=记忆主题（越大重要度越高）；半透明=时间游标之后的记忆。"
	legend.add_theme_font_size_override("font_size", 12)
	header.add_child(legend)
	var reset_button := _icon_button("reset", "重置网络视角")
	reset_button.pressed.connect(func(): _canvas.reset_view())
	header.add_child(reset_button)
	var refresh_button := _icon_button("refresh", "重新计算记忆关系")
	refresh_button.pressed.connect(_load_graph)
	header.add_child(refresh_button)
	var close_button := _icon_button("close", "关闭记忆网络")
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
	_add_scope_option("仅小玲", "ling")
	_add_scope_option("仅小奈", "nai")
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
	var search_button := _icon_button("search", "搜索记忆网络")
	search_button.custom_minimum_size = Vector2(42, 34)
	search_button.pressed.connect(_load_graph)
	filters.add_child(search_button)
	_strength_label = Label.new()
	_strength_label.text = "关联 ≥ 0.55"
	_strength_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_strength_label.add_theme_font_size_override("font_size", 12)
	_strength_label.custom_minimum_size = Vector2(92, 34)
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

	# 图内容区必须有自己的一层实心衬底:庭院场景与 GameWorld 只能透过外框被
	# 看见,不能透到节点、标签和连线底下来。
	_canvas_plate = PanelContainer.new()
	_canvas_plate.name = "GraphPlate"
	_canvas_plate.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas_plate.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(_canvas_plate)
	_canvas = GRAPH_CANVAS.new()
	_canvas.name = "MemoryGraphCanvas"
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.custom_minimum_size = Vector2(460, 360)
	_canvas.node_selected.connect(_show_node_details)
	_canvas.selection_invalidated.connect(_clear_details)
	_canvas_plate.add_child(_canvas)
	_empty_state = Label.new()
	_empty_state.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_empty_state.text = "正在读取心织记忆……"
	_empty_state.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_state.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty_state.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_empty_state.add_theme_font_size_override("font_size", 15)
	_canvas.add_child(_empty_state)
	# 交互提示:画布手势(滚轮/平移/甩节点)没有任何可见入口,不写出来没人知道
	var gesture_hint := Label.new()
	gesture_hint.name = "GestureHint"
	gesture_hint.text = "滚轮缩放 · 空白处拖动平移 · 拖住节点可甩动"
	gesture_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gesture_hint.add_theme_font_size_override("font_size", 11)
	gesture_hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	gesture_hint.offset_left = 14.0
	gesture_hint.offset_top = -30.0
	gesture_hint.offset_right = 480.0
	gesture_hint.offset_bottom = -12.0
	_canvas.add_child(gesture_hint)

	_detail_panel = PanelContainer.new()
	_detail_panel.name = "MemoryDetailSheet"
	_detail_panel.visible = false
	_detail_panel.custom_minimum_size = Vector2(318, 0)
	_detail_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(_detail_panel)
	var detail_margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		detail_margin.add_theme_constant_override("margin_%s" % side, 14)
	_detail_panel.add_child(detail_margin)
	# 详情卡内容包一层滚动:标题/统计/遗忘曲线/正文/关联列表的最小高度会无上界
	# 地叠起来(实测 700+),把 content VBox 总 min 高撑过 720 视口,状态行与
	# 章节钉被裁出窗口。卡内滚动让整卡 min 高度有界,超出的部分滚着看。
	var detail_scroll := ScrollContainer.new()
	detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	detail_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_margin.add_child(detail_scroll)
	var detail := VBoxContainer.new()
	detail.add_theme_constant_override("separation", 9)
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_scroll.add_child(detail)
	# 窄屏在"画布聚焦"与"详情聚焦"之间切换,需要一个明确的返回图谱入口,
	# 而不是把两块一上一下堆着让人自己分辨。
	_detail_back_button = _icon_button("back", "返回图谱")
	_detail_back_button.visible = false
	_detail_back_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_detail_back_button.pressed.connect(_clear_details)
	detail.add_child(_detail_back_button)
	_detail_title = Label.new()
	_detail_title.text = "选择一条记忆"
	_detail_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_title.add_theme_font_size_override("font_size", 19)
	detail.add_child(_detail_title)
	_detail_meta = Label.new()
	_detail_meta.text = "点击节点查看它与其他记忆的联系"
	_detail_meta.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_meta.add_theme_font_size_override("font_size", 12)
	detail.add_child(_detail_meta)
	# 记忆强度统计条:留存率 / 回想加固 / 有效半衰期。遗忘曲线是本项目的
	# 招牌特性(ADR-014),值得在详情卡里常驻一块数值面板
	_stat_row = HBoxContainer.new()
	_stat_row.add_theme_constant_override("separation", 10)
	_stat_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.add_child(_stat_row)
	_stat_value_labels.clear()
	_stat_caption_labels.clear()
	for index in 3:
		var cell := VBoxContainer.new()
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.add_theme_constant_override("separation", 0)
		_stat_row.add_child(cell)
		var value := Label.new()
		value.add_theme_font_size_override("font_size", 19)
		cell.add_child(value)
		var caption := Label.new()
		caption.add_theme_font_size_override("font_size", 10)
		cell.add_child(caption)
		_stat_value_labels.append(value)
		_stat_caption_labels.append(caption)
	_stat_row.visible = false
	_decay_title = Label.new()
	_decay_title.text = "遗忘曲线 · 记忆强度"
	_decay_title.add_theme_font_size_override("font_size", 12)
	_decay_title.visible = false
	detail.add_child(_decay_title)
	# ADR-014 消费侧:所选记忆的艾宾浩斯 R(t) 曲线(仅记忆节点显示)
	_decay_curve = MemoryDecayCurve.new()
	_decay_curve.custom_minimum_size = Vector2(0, 104)
	_decay_curve.visible = false
	detail.add_child(_decay_curve)
	var separator := HSeparator.new()
	detail.add_child(separator)
	_detail_content = RichTextLabel.new()
	_detail_content.bbcode_enabled = false
	_detail_content.selection_enabled = true
	# fit_content + 卡内滚动:正文随内容自然长高,由 detail_scroll 统一滚动,
	# 不再在自己的 120px 视口里内滚(嵌套滚动会抢滚轮、读长文像窥视孔)。
	_detail_content.fit_content = true
	_detail_content.scroll_active = false
	_detail_content.custom_minimum_size = Vector2(0, 120)
	for font_size_key in ["normal_font_size", "bold_font_size", "italics_font_size", "bold_italics_font_size", "mono_font_size"]:
		_detail_content.add_theme_font_size_override(font_size_key, 13)
	detail.add_child(_detail_content)
	_detail_keywords = Label.new()
	_detail_keywords.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_keywords.add_theme_font_size_override("font_size", 12)
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
	_status.add_theme_font_size_override("font_size", 12)
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
	_apply_graph_payload(data)
	_clear_details()



# 把 /heartloom/graph 的响应落到画布、时间轴与章节钉上。
# 抽出来是为了让这条「API 字段 → 画布字段」的契约可以被直接断言：
# src/dst 与 source/target 一旦对不上，图会安静地一条线都不画。
func _apply_graph_payload(data: Dictionary) -> void:
	# /heartloom/graph 契约字段映射到画布结构:
	# memory_id→id、content(缺省回退 summary)、edges 的 src/dst→source/target。
	var mapped_nodes: Array = []
	var raw_nodes = data.get("nodes", [])
	if raw_nodes is Array:
		for node_variant in raw_nodes:
			if not node_variant is Dictionary:
				continue
			var node: Dictionary = (node_variant as Dictionary).duplicate(true)
			# ADR-015:实体节点用 node_id(entity_id);记忆节点回退 memory_id。
			node["id"] = str(node.get("node_id", node.get("memory_id", "")))
			node["content"] = str(node.get("content", node.get("summary", "")))
			if str(node.get("node_type", "memory")) != "entity" and str(node.get("title", "")).strip_edges().is_empty():
				# 空标题不能在折叠阶段消失；给每条无题记忆独立的内容预览键。
				var preview := str(node.get("summary", node.get("content", ""))).strip_edges()
				node["title"] = preview.left(28) if not preview.is_empty() else "未命名记忆"
				node["display_title"] = str(node["title"])
				# 不同无题条目不可因为相同占位标题被错误合并。
				node["collapse_key"] = "untitled:" + str(node["id"])
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
			var reason := str(edge.get("reason", "")).strip_edges()
			edge["reasons"] = [reason] if not reason.is_empty() else []
			mapped_edges.append(edge)
	_graph = _collapse_duplicate_nodes(mapped_nodes, mapped_edges)
	_graph["summary"] = _build_presentation_summary(data, _graph)
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
	var raw_memory_count := int(data.get("memory_node_count", data.get("node_count", 0)))
	_empty_state.visible = raw_memory_count == 0
	_empty_state.text = "没有匹配的长期记忆" if raw_memory_count == 0 else ""
	_update_summary_status(_graph.get("summary", {}))

	_status.add_theme_color_override("font_color", Color(ThemeMgr.get_current_theme_data().secondary, 0.82))
	_selected_node_id = ""


func _collapse_duplicate_nodes(nodes: Array, edges: Array) -> Dictionary:
	"""把同标题条目投影为主题节点，同时保留其完整时间成员集。

	主题节点的诞生时间取最早成员、最后演化取最晚成员；详情与章节钉从
	member_records 推导，不能再由重要度最高的单条代表覆盖整段历史。
	"""
	var groups: Dictionary = {}
	for node_variant in nodes:
		var node: Dictionary = node_variant
		if str(node.get("node_type", "memory")) == "entity":
			continue
		var key := str(node.get("collapse_key", node.get("title", ""))).strip_edges()
		if key.is_empty():
			key = "untitled:" + str(node.get("id", ""))
		if not groups.has(key):
			groups[key] = []
		groups[key].append(node)
	var rep_of: Dictionary = {}
	var collapsed: Array = []
	for key in groups:
		var group: Array = groups[key]
		var rep: Dictionary = group[0]
		var earliest := INF
		var latest := 0.0
		var members: Array[Dictionary] = []
		for node_variant in group:
			var member: Dictionary = node_variant
			if _node_rank(member) > _node_rank(rep):
				rep = member
			earliest = minf(earliest, float(member.get("world_created_at", 0.0)))
			latest = maxf(latest, float(member.get("world_updated_at", 0.0)))
			members.append(member.duplicate(true))
		members.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return float(a.get("world_created_at", 0.0)) < float(b.get("world_created_at", 0.0))
		)
		for member_variant in group:
			rep_of[str((member_variant as Dictionary).get("id", ""))] = str(rep.get("id", ""))
		var kept: Dictionary = rep.duplicate(true)
		kept["member_count"] = group.size()
		kept["member_records"] = members
		kept["world_created_at"] = earliest if earliest < INF else float(rep.get("world_created_at", 0.0))
		kept["world_updated_at"] = latest
		collapsed.append(kept)
	for node_variant in nodes:
		var node: Dictionary = node_variant
		if str(node.get("node_type", "memory")) == "entity":
			collapsed.append(node)
			rep_of[str(node.get("id", ""))] = str(node.get("id", ""))
	var seen: Dictionary = {}
	var merged_edges: Array = []
	for edge_variant in edges:
		var edge: Dictionary = edge_variant
		var source := str(rep_of.get(str(edge.get("source", "")), edge.get("source", "")))
		var target := str(rep_of.get(str(edge.get("target", "")), edge.get("target", "")))
		if source == target or source.is_empty() or target.is_empty():
			continue
		var pair: Array = [source, target]
		pair.sort()
		var edge_key := "%s|%s|%s" % [pair[0], pair[1], str(edge.get("link_type", ""))]
		var mapped: Dictionary = edge.duplicate(true)
		mapped["source"] = source
		mapped["target"] = target
		if seen.has(edge_key):
			var index: int = seen[edge_key]
			var existing: Dictionary = merged_edges[index]
			existing["world_created_at"] = minf(
				float(existing.get("world_created_at", 0.0)),
				float(mapped.get("world_created_at", 0.0))
			)
			var reasons: Array = existing.get("reasons", [])
			for reason_variant in mapped.get("reasons", []):
				var reason := str(reason_variant)
				if not reason.is_empty() and reason not in reasons:
					reasons.append(reason)
			existing["reasons"] = reasons
			if float(existing.get("strength", 0.0)) < float(mapped.get("strength", 0.0)):
				mapped["world_created_at"] = float(existing["world_created_at"])
				mapped["reasons"] = reasons
				merged_edges[index] = mapped
			else:
				merged_edges[index] = existing
			continue
		seen[edge_key] = merged_edges.size()
		merged_edges.append(mapped)
	return {"nodes": collapsed, "edges": merged_edges}


func _node_rank(node: Dictionary) -> float:
	return (
		float(node.get("importance", 0.5)) * 2.0
		+ minf(2.0, log(1.0 + float(node.get("recall_count", 0))) * 0.4)
	)


func _members_at_cursor(node: Dictionary) -> Array[Dictionary]:
	var members: Array[Dictionary] = []
	var records_variant = node.get("member_records", [])
	if records_variant is Array:
		for record_variant in records_variant:
			if not record_variant is Dictionary:
				continue
			var record: Dictionary = record_variant
			if _current_cursor_value() >= 0.0 and float(record.get("world_created_at", 0.0)) > _current_cursor_value():
				continue
			members.append(record)
	if members.is_empty():
		members.append(node)
	return members


func _detail_member_at_cursor(node: Dictionary) -> Dictionary:
	var members := _members_at_cursor(node)
	var selected: Dictionary = members[0]
	for member in members:
		if _node_rank(member) > _node_rank(selected):
			selected = member
	return selected


func _show_node_details(node: Dictionary) -> void:
	_detail_panel.show()
	_selected_node_id = str(node.get("id", ""))
	_apply_detail_focus()
	if str(node.get("node_type", "memory")) == "entity":
		_show_entity_details(node)
		return
	var detail := _detail_member_at_cursor(node)
	_detail_title.text = str(node.get("title", detail.get("title", "未命名记忆")))
	var scope := str(detail.get("scope_role_id", "*"))
	var kind := str(detail.get("kind", "episodic"))
	var bucket_names := {"high": "高", "normal": "中", "low": "低"}
	var importance_label := str(
		bucket_names.get(str(detail.get("importance_bucket", "normal")), "中")
	)
	var members_at_cursor := _members_at_cursor(node)
	var total_members := int(node.get("member_count", members_at_cursor.size()))
	var member_note := ""
	if total_members > 1:
		member_note = "　（此时已有 %d / %d 条同类记忆）" % [members_at_cursor.size(), total_members]
	_detail_meta.text = "%s · %s · 重要度：%s\n世界第 %.1f 天%s" % [
		str(SCOPE_NAMES.get(scope, scope)),
		str(KIND_NAMES.get(kind, kind)),
		importance_label,
		float(detail.get("world_updated_at", 0.0)),
		member_note,
	]
	_fill_memory_stats(detail)
	_stat_row.visible = true
	_decay_title.visible = true
	_detail_content.text = str(detail.get("content", ""))
	var keywords: Array[String] = []
	for item in detail.get("keywords", []):
		var keyword := str(item)
		if not keyword.is_empty() and keyword not in keywords:
			keywords.append(keyword)
	_detail_keywords.text = "主题：%s" % ("、".join(keywords) if not keywords.is_empty() else "尚未提取")
	_related_title.text = "关联记忆"
	# ADR-014:遗忘曲线跟随所选记忆(与召回打分同款双参数公式)
	_decay_curve.set_series({
		"half_life_days": float(detail.get("half_life_days", 0.0)),
		"intrinsic": float(detail.get("intrinsic", 1.0)),
		"world_updated_at": float(detail.get("world_updated_at", 0.0)),
		"world_now": _world_now,
	})
	_decay_curve.visible = true
	_rebuild_related_memories(_selected_node_id)


# 记忆强度统计条:R(t) 与遗忘曲线同一条公式(ADR-014 双参数),
# 留存率按语义色分级 —— 醒目但不花哨。
func _fill_memory_stats(detail: Dictionary) -> void:
	var half_life := float(detail.get("half_life_days", 0.0))
	var intrinsic := maxf(0.05, float(detail.get("intrinsic", 1.0)))
	var age := maxf(0.0, _world_now - float(detail.get("world_updated_at", 0.0)))
	if half_life <= 0.0:
		# ADR-001 语义:half_life = 0 是常驻记忆
		_last_retention = 1.0
		(_stat_value_labels[0] as Label).text = "常驻"
		(_stat_caption_labels[0] as Label).text = "不随时间衰减"
	else:
		_last_retention = pow(0.5, age / (half_life * intrinsic))
		(_stat_value_labels[0] as Label).text = "%d%%" % roundi(_last_retention * 100.0)
		(_stat_caption_labels[0] as Label).text = "当前留存 R(t)"
	(_stat_value_labels[0] as Label).add_theme_color_override(
		"font_color", _retention_color(_last_retention)
	)
	(_stat_value_labels[1] as Label).text = "%d 次" % int(detail.get("recall_count", 0))
	(_stat_caption_labels[1] as Label).text = "回想加固"
	(_stat_value_labels[2] as Label).text = (
		"常驻" if half_life <= 0.0 else "%.1f 天" % (half_life * intrinsic)
	)
	(_stat_caption_labels[2] as Label).text = "有效半衰期"


func _retention_color(retention: float) -> Color:
	if retention >= 0.6:
		return ThemeMgr.SEMANTIC_SUCCESS
	if retention >= 0.3:
		return ThemeMgr.SEMANTIC_WARNING
	return ThemeMgr.SEMANTIC_DANGER


# 主题切换会把所有 Label 的颜色刷成正文色,留存率的语义色必须随后补回
func _apply_stat_colors() -> void:
	if _stat_value_labels.is_empty():
		return
	var value := _stat_value_labels[0] as Label
	if is_instance_valid(value) and _last_retention >= 0.0:
		value.add_theme_color_override("font_color", _retention_color(_last_retention))


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
			# 关联列表是"这条记忆在当时跟谁有关"。游标拨回过去之后,
			# 还没诞生的邻居不能出现在列表里。
			if not _canvas.is_node_selectable(other_id):
				continue
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
		empty.add_theme_font_size_override("font_size", 12)
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
		button.add_theme_font_size_override("font_size", 12)
		button.add_theme_color_override("font_color", Color(ThemeMgr.get_current_theme_data().text))
		button.add_theme_color_override("font_hover_color", Color(ThemeMgr.get_current_theme_data().text))
		button.tooltip_text = "；".join(edge.get("reasons", []))
		button.pressed.connect(func(): _canvas.select_node_by_id(str(other.get("id", ""))))
		_related_list.add_child(button)


func _show_entity_details(node: Dictionary) -> void:
	_decay_curve.visible = false
	_decay_title.visible = false
	_stat_row.visible = false
	var kind_names := {"person": "人物", "object": "器物", "place": "地点", "event": "事件", "concept": "概念"}
	_detail_title.text = str(node.get("name", "未名实体"))
	var claim_total := _visible_claim_count(str(node.get("id", "")))
	var claim_label := (
		"现行主张 %d 条" % claim_total
		if _current_cursor_value() < 0.0
		else "当时主张 %d 条" % claim_total
	)
	_detail_meta.text = "%s · 首次相遇 世界第 %.1f 天\n%s" % [
		str(kind_names.get(str(node.get("kind", "concept")), "概念")),
		float(node.get("world_created_at", 0.0)),
		claim_label,
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


# 主张条数按当前游标重算。直接用后端返回的 claim_count 会把未来才出现、
# 或者当时已经作废的主张算进来。
func _visible_claim_count(entity_id: String) -> int:
	var count := 0
	var raw_edges = _graph.get("edges", [])
	if raw_edges is Array:
		for edge_variant in raw_edges:
			if not edge_variant is Dictionary:
				continue
			var edge: Dictionary = edge_variant
			if str(edge.get("link_type", "")) != "claim":
				continue
			var source := str(edge.get("source", ""))
			var target := str(edge.get("target", ""))
			if source != entity_id and target != entity_id:
				continue
			if not _canvas.is_edge_visible_now(edge):
				continue
			count += 1
	return count


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
			# 生命线同样是"当时这张星座长什么样":没诞生的主张与出处不进列表。
			if not _canvas.is_node_selectable(other_id):
				continue
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
		empty.add_theme_font_size_override("font_size", 12)
		empty.add_theme_color_override("font_color", Color(ThemeMgr.get_current_theme_data().secondary, 0.82))
		_related_list.add_child(empty)
		return
	var text := Color(ThemeMgr.get_current_theme_data().text)
	var cursor := _current_cursor_value()
	for item in claims:
		var other: Dictionary = item.node
		var edge: Dictionary = item.edge
		var world_to_variant = edge.get("world_to")
		# 回溯态下"当时还没被改写"的主张必须显示为现行,否则等于把未来
		# 才发生的改写提前告诉了看过去的人。
		var state_label := "现行"
		if world_to_variant != null:
			var world_to := float(world_to_variant)
			if cursor >= 0.0 and world_to > cursor:
				state_label = "现行"
			else:
				state_label = "已于第 %d 天改变" % int(world_to)
		var button := Button.new()
		button.text = "〔主张〕%s → %s · %s" % [
			str(edge.get("predicate", "")),
			str(other.get("name", "未名实体")),
			state_label,
		]
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.flat = true
		button.add_theme_font_size_override("font_size", 12)
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
		button.add_theme_font_size_override("font_size", 12)
		button.add_theme_color_override("font_color", text)
		button.add_theme_color_override("font_hover_color", text)
		button.tooltip_text = "跳到这段记忆 · %s" % str(edge.get("predicate", ""))
		button.pressed.connect(func(): _canvas.select_node_by_id(str(other.get("id", ""))))
		_related_list.add_child(button)


func _pin_kind_for_source(source: String) -> String:
	if source.begins_with("consolidation_") or source == "season_weave":
		return "weave"
	if source == "weekly_insight":
		return "weekly"
	if source == "milestone":
		return "milestone"
	return ""


func _collect_chapter_pins() -> Array[Dictionary]:
	# 从主题成员收集章节事件，再按世界日聚合；不能只使用折叠代表节点，
	# 否则同标题组的早期章节会被后来代表静默覆盖。
	var bins: Dictionary = {}
	for node_variant in _graph.get("nodes", []):
		if not node_variant is Dictionary:
			continue
		var node: Dictionary = node_variant
		if str(node.get("node_type", "memory")) != "memory":
			continue
		var records_variant = node.get("member_records", [node])
		if not records_variant is Array:
			records_variant = [node]
		for record_variant in records_variant:
			if not record_variant is Dictionary:
				continue
			var record: Dictionary = record_variant
			var pin_kind := _pin_kind_for_source(str(record.get("source", "")))
			if pin_kind.is_empty():
				continue
			var day := floori(float(record.get("world_created_at", 0.0)))
			var key := "%d|%s" % [day, pin_kind]
			if not bins.has(key):
				bins[key] = {
					"day": float(day),
					"title": str(record.get("display_title", record.get("title", ""))),
					"kind": pin_kind,
					"count": 0,
					# 点击时要把游标拨到「这一天结束」,而不是当天 0 点:
					# 幽灵判据是 created >= cursor,拨到 0 点会把这一整天
					# (包括这根钉自己)全变成幽灵,和 tooltip 的承诺相反。
					"cursor": float(day) + 1.0,
					# 回溯态下"当时已发生几个事件"要按成员逐个过滤,不能沿用总数。
					"member_days": [],
				}
			var bin: Dictionary = bins[key]
			bin["count"] = int(bin.get("count", 0)) + 1
			(bin["member_days"] as Array).append(
				float(record.get("world_created_at", 0.0))
			)
			bins[key] = bin
	var pins: Array[Dictionary] = []
	for bin_variant in bins.values():
		var bin: Dictionary = bin_variant
		if int(bin.get("count", 1)) > 1:
			bin["title"] = "%s（%d 个章节）" % [str(bin.get("title", "")), int(bin["count"])]
		pins.append(bin)
	pins.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.day) < float(b.day)
	)
	return pins


func _on_pin_selected(cursor_day: float) -> void:
	# 章节钉给的是「那一天结束」的时刻,不是当天 0 点。见 _collect_chapter_pins。
	_time_slider.set_value(cursor_day)


func _clear_details() -> void:
	_selected_node_id = ""
	_detail_panel.hide()
	_apply_detail_focus()
	_detail_title.text = "选择一条记忆"
	_detail_meta.text = "点击节点查看它与其他记忆的联系"
	_stat_row.visible = false
	_decay_title.visible = false
	_decay_curve.visible = false
	_last_retention = -1.0
	_detail_content.text = ""
	_detail_keywords.text = ""
	_related_title.text = "关联记忆"
	_decay_curve.visible = false
	for child in _related_list.get_children():
		child.queue_free()


func _on_strength_changed(value: float) -> void:
	_strength_label.text = "关联 ≥ %.2f" % value
	_canvas.set_min_strength(value)
	# 加载失败时 _graph 是空的;此时动滑杆不能把"加载失败"覆盖成 0 个主题 · 0/0。
	if _graph.is_empty():
		return
	_update_summary_status(_graph.get("summary", {}))


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
	if not _graph.is_empty():
		_update_summary_status(_graph.get("summary", {}))


func _snap_time_to_now() -> void:
	_time_following_now = true
	_time_slider.set_value_no_signal(_time_slider.max_value)
	_update_time_label(_time_slider.max_value)
	_canvas.set_time_cursor(-1.0)
	_time_pins.set_cursor(-1.0)


func _build_presentation_summary(data: Dictionary, graph: Dictionary) -> Dictionary:
	var nodes: Array = graph.get("nodes", [])
	var edges: Array = graph.get("edges", [])
	var degrees: Dictionary = {}
	for edge_variant in edges:
		if not edge_variant is Dictionary:
			continue
		var edge: Dictionary = edge_variant
		if float(edge.get("strength", 0.0)) < float(_strength_slider.value):
			continue
		var source := str(edge.get("source", ""))
		var target := str(edge.get("target", ""))
		degrees[source] = int(degrees.get(source, 0)) + 1
		degrees[target] = int(degrees.get(target, 0)) + 1
	var isolated := 0
	for node_variant in nodes:
		if node_variant is Dictionary and int(degrees.get(str((node_variant as Dictionary).get("id", "")), 0)) == 0:
			isolated += 1
	return {
		"raw_memory_count": int(data.get("memory_node_count", data.get("node_count", 0))),
		"raw_entity_count": int(data.get("entity_node_count", 0)),
		"visual_node_count": nodes.size(),
		"edge_count": edges.size(),
		"isolated_count": isolated,
		"truncated": bool(data.get("truncated", false)),
	}


func _update_summary_status(summary_variant: Variant) -> void:
	var summary: Dictionary = summary_variant if summary_variant is Dictionary else {}
	var visual_nodes := int(summary.get("visual_node_count", 0))
	var raw_memories := int(summary.get("raw_memory_count", visual_nodes))
	var raw_entities := int(summary.get("raw_entity_count", 0))
	var edge_count := int(summary.get("edge_count", 0))
	var visible_edges := _canvas.get_visible_edge_count() if is_instance_valid(_canvas) else edge_count
	# 孤立主题数用画布自己的显示口径重算:后端 summary 用的是未剪枝的度数,
	# 而且只在加载时算过一次,滑杆与游标动过之后就和旁边的 visible_edges 打架。
	var isolated := (
		_canvas.get_isolated_node_count()
		if is_instance_valid(_canvas)
		else int(summary.get("isolated_count", 0))
	)
	var node_label := "%d 个主题" % visual_nodes
	if raw_memories > visual_nodes:
		node_label = "%d 个主题 / %d 条记忆" % [visual_nodes, raw_memories]
	if raw_entities > 0:
		node_label += " · %d 个实体" % raw_entities
	_status.text = "%s · 默认显示 %d / %d 条联系%s%s" % [
		node_label,
		visible_edges,
		edge_count,
		" · %d 个孤立主题" % isolated if isolated > 0 else "",
		" · 结果已分页" if bool(summary.get("truncated", false)) else "",
	]


func _icon_button(icon_id: String, hint: String) -> LineIconButton:
	var button := LINE_ICON_BUTTON.new() as LineIconButton
	button.set_icon(icon_id)
	button.tooltip_text = hint
	button.flat = true
	button.custom_minimum_size = Vector2(36, 34)
	return button


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
	var narrow := get_viewport_rect().size.x < NARROW_WIDTH
	_body.vertical = false
	_detail_panel.custom_minimum_size = Vector2(0, 0) if narrow else Vector2(318, 0)
	_detail_panel.size_flags_horizontal = (
		Control.SIZE_EXPAND_FILL if narrow else Control.SIZE_SHRINK_BEGIN
	)
	_canvas.custom_minimum_size = Vector2(340, 300) if narrow else Vector2(460, 360)
	_apply_detail_focus()


# 窄屏不做"图谱与详情上下堆叠"——两块都残缺。改成二选一:没选节点时看图谱,
# 选中后整块让给详情卡,详情卡顶部的返回键切回图谱。
func _apply_detail_focus() -> void:
	if not is_instance_valid(_canvas_plate) or not is_instance_valid(_detail_panel):
		return
	var narrow := get_viewport_rect().size.x < NARROW_WIDTH
	var has_selection := not _selected_node_id.is_empty()
	_canvas_plate.visible = not narrow or not has_selection
	_detail_panel.visible = has_selection
	if is_instance_valid(_detail_back_button):
		_detail_back_button.visible = narrow and has_selection


func _on_theme_changed(_theme_data: Dictionary) -> void:
	_apply_theme()


func _apply_theme() -> void:
	var data := ThemeMgr.get_current_theme_data()
	var background := Color(str(data.bg))
	var text := Color(str(data.text))
	var secondary := Color(str(data.secondary))
	_background.color = Color(background, SCRIM_ALPHA)
	_sheet.add_theme_stylebox_override(
		"panel", _style(Color(background, SHEET_ALPHA), Color(text, 0.18), 16)
	)
	_canvas_plate.add_theme_stylebox_override(
		"panel", _style(Color(background, PLATE_ALPHA), Color(text, 0.14), 8)
	)
	_detail_panel.add_theme_stylebox_override(
		"panel", _style(Color(background, DETAIL_ALPHA), Color(text, 0.16), 8)
	)
	_apply_readable_colors(_sheet, text, secondary)
	_detail_meta.add_theme_color_override("font_color", Color(secondary, 0.86))
	_detail_keywords.add_theme_color_override("font_color", Color(secondary, 0.92))
	_empty_state.add_theme_color_override("font_color", Color(secondary, 0.82))
	var gesture_hint := _canvas.get_node_or_null("GestureHint") as Label
	if gesture_hint != null:
		gesture_hint.add_theme_color_override("font_color", Color(secondary, 0.66))
	for caption in _stat_caption_labels:
		if is_instance_valid(caption):
			caption.add_theme_color_override("font_color", Color(secondary, 0.78))
	_apply_stat_colors()
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
