class_name MemoryGraphCanvas
extends Control

signal node_selected(node: Dictionary)
# 时间游标把当前选中/悬停的节点拨成幽灵时必须广播出去:画布只负责亮度,
# 右侧详情卡属于面板 —— 不发信号的话详情会继续展示未来的标题与正文。
signal selection_invalidated

const DEFAULT_SCOPE_COLORS := {
	"*": Color("#E8C97A"),
	"ling": Color("#72C7B8"),
	"nai": Color("#E6A4BD"),
}
const MIN_ZOOM := 0.2
const MAX_ZOOM := 2.4

# ── Obsidian 式连续力导向(可读性优先)─────────────────────────────
# 每帧模拟直至能量沉降:库仑斥力(全对,半径感知)+ 弹簧(可见边)+
# 向心 + 阻尼 + 软边界。拖拽把光标速度传给节点,松手后惯性滑行,
# 弹簧拖着邻居弹性跟随 —— 「弹弓」手感来自连续模拟,而非固定步数。
const REPULSION_K := 14000.0
const REPULSION_FLOOR := 0.08
const REPULSION_CUTOFF_SQ := 190000.0
const LINK_SPRING_K := 0.03
const LINK_LEN_STRONG := 112.0
const LINK_LEN_WEAK := 165.0
const CENTER_PULL := 0.012
const DAMPING := 0.865
const MAX_SPEED := 26.0
const FLING_MAX := 22.0
# 模拟温度(alpha):唤醒置 1,逐帧衰减——力随温度冷却,布局约 2 秒收敛后
# 冻结(d3/Obsidian 同款)。初始布局已是均匀云,冷却快、观感静
const SIM_COOL_PER_FRAME := 0.004
const SIM_ALPHA_MIN := 0.01
const SIM_ALPHA_DRAG := 0.5
const COLLISION_PAD := 8.0
# 标签 LOD:≥LABEL_ZOOM 时全量画名字;更远的远景只画实体/枢纽/高重要度
# (LABEL_PRIORITY_ZOOM 门槛),避免几十个标签糊成一团。阈值实测:自适应视角
# 通常落在 0.6~1.15 之间,旧的 1.2 门槛等于"打开永远没有名字"——
# 一张没有名字的关系图什么都读不出来,这正是 Obsidian 默认全标签的原因。
const LABEL_ZOOM := 0.72
const LABEL_PRIORITY_ZOOM := 0.45
const LABEL_FONT_SIZE := 12
const FOCUS_DIM := 0.10
# 悬停/聚焦的亮度过渡:指数趋入速率(1/s),12/s ≈ 0.19s 到 90% ——
# 「放上来渐显」不闪不抢;焦点圈与因聚焦展开的边按 FOCUS_GLOW_RISE 渐入,
# 焦点一挪开瞬间清零(移开突灭,用户点名的要求)。
const EMPHASIS_RISE_SPEED := 12.0
const FOCUS_GLOW_RISE := 0.16
# 数值兜底半径（世界单位）：只在极端斥力下生效，正常布局碰不到。
# 它必须远大于任何正常云团，否则又会变成一堵墙。
const HARD_BOUNDARY := 4000.0
## 度数软上限(Obsidian「毛线球」对策):连接数超过它,相关弹簧变软
const HUB_DEGREE_SOFT_CAP := 7

var _nodes: Array[Dictionary] = []
var _edges: Array[Dictionary] = []
var _node_by_id: Dictionary = {}
var _positions: Dictionary = {}
var _velocities: Dictionary = {}
var _selected_id := ""
var _hovered_id := ""
var _dragged_id := ""
var _drag_target := Vector2.ZERO
var _drag_velocity := Vector2.ZERO
var _physics_awake := true
var _sim_alpha := 1.0
var _panning := false
# 空白处按下手势的行程记录:松手时行程几乎为零 = 干净点击 = 取消选中。
var _press_position := Vector2.ZERO
var _press_travel := 0.0
var _press_was_blank := false
var _zoom := 1.0
# 图装载后等力导向沉降完，再把视角套到内容上（Obsidian 的重置视角即此）
var _auto_fit_pending := false
# 云团形状跟随面板长宽比(只由控件尺寸决定,与相机无关,避免反馈环)。
var _pane_stretch := 1.0
var _pan := Vector2.ZERO
## 度数上限(Obsidian「毛线球」对策):每个节点默认只绘制最强的 K 条边,
## 其余边在聚焦/悬停/选中时展开 —— 高连接节点不再喷成"蜘蛛"
# 每节点默认常显的边数上限。6 在密集存档下整张图像铁丝网(用户原话),
# 4 配合更散的斥力布局能把线量压下来;被藏起的联系在悬停/选中时完整展开。
const EDGE_KEEP_PER_NODE := 4

var _min_strength := 0.55
var _primary_edge_ids: Dictionary = {}
var _degrees: Dictionary = {}
# 布局位置缓存(静态,跨面板开关):再次打开直接复用上次沉降结果,开局即稳定
static var _layout_cache: Dictionary = {}
# ADR-010:世界日时间游标(客户端调光)。-1 = 实时态(全部点亮);
# 游标之后诞生的节点/边降为低亮度"幽灵",布局不受影响 —— 拖动全程零重排。
# 幽灵程度带时间插值(指数趋近),拨动滑杆时亮度平滑过渡。
var _time_cursor := -1.0
var _ghost_amounts: Dictionary = {}
const GHOST_NODE_ALPHA := 0.14
const GHOST_EDGE_ALPHA := 0.05
const GHOST_ANIM_SPEED := 9.0
## 软边渐变带(世界日):游标附近这个宽度内的记忆亮度连续过渡,
## 消除"成批翻面"的顿挫感。由面板按时间线总量校准。
const GHOST_FADE_DAYS_DEFAULT := 4.0
var _time_fade_days := GHOST_FADE_DAYS_DEFAULT
# 悬停聚焦(Obsidian 式):聚焦节点的邻域保持明亮,其余淡出
var _focus_id := ""
var _focus_neighbors: Dictionary = {}
# 亮度过渡的动画量:emphasis = 每节点/边在聚焦态下的亮度(1=常态),
# focus_glow = 当前焦点节点的「在场程度」—— 悬停圈、因聚焦展开的边随它渐入。
var _emphasis: Dictionary = {}
var _focus_glow: Dictionary = {}
var _palette := {
	"background": Color("#100E0D"),
	"grid": Color(1, 1, 1, 0.045),
	"edge": Color("#8E877F"),
	"text": Color("#F2E9DF"),
	"muted": Color("#A79B90"),
}
var _scope_colors := DEFAULT_SCOPE_COLORS.duplicate()


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	set_process(true)
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_wake_physics()
	elif what == NOTIFICATION_MOUSE_EXIT:
		# 鼠标离开后悬停与聚焦必须清掉：聚焦态会让整图"除邻域外全部变暗"，
		# 不清的话人早就离开图了、图却一直维持那个样子 —— 和"平移甩不掉"是
		# 同一种"卡住了"的体感。拖拽过程中不清，否则拖到控件外会中断拖拽。
		# 但若此时有选中节点，焦点锚在选中上（_effective_focus_id 兜底）。
		if _dragged_id == "" and _hovered_id != "":
			_hovered_id = ""
			tooltip_text = ""
			_update_focus(_effective_focus_id())
		queue_redraw()


func set_graph(graph: Dictionary) -> void:
	_nodes.clear()
	_edges.clear()
	_node_by_id.clear()
	_positions.clear()
	_velocities.clear()
	_selected_id = ""
	_hovered_id = ""
	_dragged_id = ""
	_focus_id = ""
	_focus_neighbors.clear()
	_emphasis.clear()
	_focus_glow.clear()
	# 沉降结束后自动套住整张图：静置的图会缩成中间一小团，
	# 默认视角必须自己跟上去，用户不该手动缩放去找。
	_auto_fit_pending = true
	var raw_nodes = graph.get("nodes", [])
	if raw_nodes is Array:
		for node_variant in raw_nodes:
			if not node_variant is Dictionary:
				continue
			var node: Dictionary = (node_variant as Dictionary).duplicate(true)
			var node_id := str(node.get("id", node.get("memory_id", "")))
			if node_id.is_empty() or _node_by_id.has(node_id):
				continue
			node["id"] = node_id
			_nodes.append(node)
			_node_by_id[node_id] = node
	var raw_edges = graph.get("edges", [])
	if raw_edges is Array:
		for index in raw_edges.size():
			var edge_variant = raw_edges[index]
			if not edge_variant is Dictionary:
				continue
			var edge: Dictionary = (edge_variant as Dictionary).duplicate(true)
			var source := str(edge.get("source", ""))
			var target := str(edge.get("target", ""))
			if not _node_by_id.has(source) or not _node_by_id.has(target):
				continue
			# 生产 API 会提供 link_id；诊断/mock 省略时也必须按边独立计数、
			# 幽灵化和 Top-K 筛选，不能把所有空 id 折成同一条边。
			if str(edge.get("link_id", "")).is_empty():
				edge["link_id"] = "fallback:%s:%s:%s:%d" % [
					source,
					target,
					str(edge.get("link_type", "association")),
					index,
				]
			_edges.append(edge)
	# 亮度动画量从常态起步:不初始化的话首次悬停的渐入会从默认值起跳
	for node in _nodes:
		_emphasis["n:%s" % str(node.id)] = 1.0
	for edge in _edges:
		_emphasis["e:%s" % str(edge.get("link_id", ""))] = 1.0
	_compute_primary_edges()
	_compute_degrees()
	var reused := _apply_cached_layout()
	if not reused:
		_initialize_positions()
	_seed_ghost_amounts()
	_wake_physics()
	if reused:
		_sim_alpha = 0.3
	reset_view()
	queue_redraw()


func _compute_primary_edges() -> void:
	"""每节点保留最强的 K 条边;两端都进各自 Top-K 的边才是"常显"。

	枢纽节点因此只留 3 条辐条(不是每条辐条都常显),其余边在聚焦/悬停/
	选中时完整展开 —— 这是 Obsidian 式"度数十限"在渲染侧的落地。
	"""
	var keep_count: Dictionary = {}
	var by_node: Dictionary = {}
	for index in _edges.size():
		var edge: Dictionary = _edges[index]
		for endpoint in [str(edge.get("source", "")), str(edge.get("target", ""))]:
			if not by_node.has(endpoint):
				by_node[endpoint] = []
			(by_node[endpoint] as Array).append(index)
	for node_id in by_node:
		var indices: Array = by_node[node_id]
		indices.sort_custom(func(a: int, b: int) -> bool:
			return float(_edges[a].get("strength", 0.0)) > float(_edges[b].get("strength", 0.0))
		)
		for index in mini(indices.size(), EDGE_KEEP_PER_NODE):
			var link_id := str(_edges[indices[index]].get("link_id", ""))
			keep_count[link_id] = int(keep_count.get(link_id, 0)) + 1
	_primary_edge_ids.clear()
	for link_id in keep_count:
		if int(keep_count[link_id]) >= 2:
			_primary_edge_ids[link_id] = true


func _compute_degrees() -> void:
	_degrees.clear()
	for edge in _edges:
		if not _is_primary_layout_edge(edge):
			continue
		var source := str(edge.get("source", ""))
		var target := str(edge.get("target", ""))
		_degrees[source] = int(_degrees.get(source, 0)) + 1
		_degrees[target] = int(_degrees.get(target, 0)) + 1


func _is_primary_layout_edge(edge: Dictionary) -> bool:
	return (
		float(edge.get("strength", 0.0)) >= _min_strength
		and _primary_edge_ids.has(str(edge.get("link_id", "")))
	)


func _apply_cached_layout() -> bool:
	"""复用上次沉降的位置(命中 ≥70% 才用);开局即稳定,不再重新炸开。"""
	if _layout_cache.is_empty() or _nodes.size() < 8:
		return false
	var hits := 0
	for node in _nodes:
		if _layout_cache.has(str(node.id)):
			hits += 1
	if hits < int(float(_nodes.size()) * 0.7):
		return false
	for node in _nodes:
		var node_id := str(node.id)
		if _layout_cache.has(node_id):
			_positions[node_id] = _layout_cache[node_id]
		else:
			_positions[node_id] = Vector2(randf_range(-50.0, 50.0), randf_range(-50.0, 50.0))
		_velocities[node_id] = Vector2.ZERO
	return true


func set_palette(theme_data: Dictionary) -> void:
	var background := Color(str(theme_data.get("bg", "#100E0D")))
	var text := Color(str(theme_data.get("text", "#F2E9DF")))
	var secondary := Color(str(theme_data.get("secondary", "#A79B90")))
	_palette = {
		# 图区必须是独立的一层表面。浅色主题下只压 0.025 时它与面板几乎同色,
		# 节点像浮在白纸上的淡点 —— 这是原先最刺眼的问题之一。
		"background": background.darkened(0.12) if bool(theme_data.get("is_dark", true)) else background.darkened(0.07),
		"grid": Color(text, 0.045),
		"edge": Color(secondary, 0.72),
		"text": text,
		"muted": secondary,
	}
	queue_redraw()


func set_min_strength(value: float) -> void:
	_min_strength = clampf(value, 0.0, 1.0)
	_compute_degrees()
	_wake_physics()
	queue_redraw()


func set_time_cursor(world_day: float) -> void:
	"""ADR-010:客户端时间调光。只改亮度目标,不重置布局;
	实际亮度经 _process 逐帧趋近 —— 拖动全程节点不动、过渡平滑。"""
	_time_cursor = world_day
	var invalidated := false
	if _hovered_id != "" and not is_node_selectable(_hovered_id):
		_hovered_id = ""
		tooltip_text = ""
	if _dragged_id != "" and not is_node_selectable(_dragged_id):
		_dragged_id = ""
	if _selected_id != "" and not is_node_selectable(_selected_id):
		_selected_id = ""
		invalidated = true
	_update_focus(_effective_focus_id())
	if invalidated:
		selection_invalidated.emit()
	queue_redraw()


func is_node_selectable(node_id: String) -> bool:
	if not _node_by_id.has(node_id):
		return false
	return not _is_ghost_node(_node_by_id[node_id] as Dictionary)


# 某条边在当前游标下是否"存在且有效":还没诞生的不算,当时已经作废的也不算。
# 面板的生命线、主张计数都按这个口径走,避免把未来透露给看过去的人。
func is_edge_visible_now(edge: Dictionary) -> bool:
	if _is_ghost_edge(edge):
		return false
	var world_to_variant = edge.get("world_to")
	if _time_cursor >= 0.0 and world_to_variant != null:
		if float(world_to_variant) <= _time_cursor:
			return false
	return true


func set_time_fade_days(days: float) -> void:
	_time_fade_days = clampf(days, 0.5, 120.0)
	queue_redraw()


func _wake_physics() -> void:
	_physics_awake = true
	_sim_alpha = 1.0


func _is_ghost_node(node: Dictionary) -> bool:
	return _ghost_target_for_node(node) >= 0.5


func _is_ghost_edge(edge: Dictionary) -> bool:
	return _ghost_target_for_edge(edge) >= 0.5


func _ghost_target_for_node(node: Dictionary) -> float:
	if _time_cursor < 0.0:
		return 0.0
	# 软边:诞生时刻每偏离游标 1 个 fade 宽度,幽灵程度变化 1/2;
	# 游标正经过的记忆半亮 —— 拖动 1 像素,亮度就连续变化
	var birth_delta := float(node.get("world_created_at", 0.0)) - _time_cursor
	return clampf(birth_delta / _time_fade_days + 0.5, 0.0, 1.0)


func _ghost_target_for_edge(edge: Dictionary) -> float:
	if _time_cursor < 0.0:
		return 0.0
	var target := 0.0
	for node_id in [str(edge.get("source", "")), str(edge.get("target", ""))]:
		var node_variant: Dictionary = _node_by_id.get(node_id, {})
		if not node_variant.is_empty():
			target = maxf(target, _ghost_target_for_node(node_variant))
	var birth_delta := float(edge.get("world_created_at", 0.0)) - _time_cursor
	target = maxf(target, clampf(birth_delta / _time_fade_days + 0.5, 0.0, 1.0))
	return target


func _seed_ghost_amounts() -> void:
	"""新图加载时把动画量直接置到目标值(避免每次搜索都全屏闪一遍)。"""
	_ghost_amounts.clear()
	for node in _nodes:
		_ghost_amounts["n:%s" % str(node.id)] = _ghost_target_for_node(node)
	for edge in _edges:
		_ghost_amounts["e:%s" % str(edge.get("link_id", ""))] = _ghost_target_for_edge(edge)


func _advance_ghost_animation(delta: float) -> bool:
	var k := clampf(delta * GHOST_ANIM_SPEED, 0.0, 1.0)
	var animating := false
	for node in _nodes:
		var key := "n:%s" % str(node.id)
		var target := _ghost_target_for_node(node)
		var current := float(_ghost_amounts.get(key, target))
		var updated := lerpf(current, target, k)
		_ghost_amounts[key] = updated
		if absf(updated - target) > 0.004:
			animating = true
	for edge in _edges:
		var key := "e:%s" % str(edge.get("link_id", ""))
		var target := _ghost_target_for_edge(edge)
		var current := float(_ghost_amounts.get(key, target))
		var updated := lerpf(current, target, k)
		_ghost_amounts[key] = updated
		if absf(updated - target) > 0.004:
			animating = true
	return animating


func _node_ghost_amount(node: Dictionary) -> float:
	return float(_ghost_amounts.get("n:%s" % str(node.id), _ghost_target_for_node(node)))


func _edge_ghost_amount(edge: Dictionary) -> float:
	return float(_ghost_amounts.get("e:%s" % str(edge.get("link_id", "")), _ghost_target_for_edge(edge)))


# ── 悬停/聚焦亮度过渡 ─────────────────────────────────────────
# 目标亮度与 _draw 的聚焦判据同源:焦点邻域 1,其余 FOCUS_DIM。
# 上下两个方向都按 EMPHASIS_RISE_SPEED 指数趋入,聚焦切换不再硬切;
# 焦点节点的 focus_glow 单独渐入、挪开瞬间清零 —— 「放上来渐显,移开突灭」。
func _emphasis_target_for_node(node: Dictionary) -> float:
	if _focus_id == "":
		return 1.0
	var node_id := str(node.id)
	if node_id == _focus_id or _focus_neighbors.has(node_id):
		return 1.0
	return FOCUS_DIM


func _emphasis_target_for_edge(edge: Dictionary) -> float:
	if _focus_id == "":
		return 1.0
	for endpoint in [str(edge.get("source", "")), str(edge.get("target", ""))]:
		if endpoint == _focus_id:
			return 1.0
	return FOCUS_DIM


func _advance_emphasis_animation(delta: float) -> bool:
	var k := clampf(delta * EMPHASIS_RISE_SPEED, 0.0, 1.0)
	var animating := false
	for node in _nodes:
		var key := "n:%s" % str(node.id)
		var target := _emphasis_target_for_node(node)
		var updated := lerpf(float(_emphasis.get(key, 1.0)), target, k)
		_emphasis[key] = updated
		if absf(updated - target) > 0.004:
			animating = true
	for edge in _edges:
		var key := "e:%s" % str(edge.get("link_id", ""))
		var target := _emphasis_target_for_edge(edge)
		var updated := lerpf(float(_emphasis.get(key, 1.0)), target, k)
		_emphasis[key] = updated
		if absf(updated - target) > 0.004:
			animating = true
	if _focus_id != "":
		var glow := clampf(
			float(_focus_glow.get(_focus_id, 0.0)) + delta / FOCUS_GLOW_RISE, 0.0, 1.0
		)
		_focus_glow[_focus_id] = glow
		if glow < 1.0:
			animating = true
	return animating


# 当前焦点节点的「在场程度」:悬停圈与因聚焦展开的弱边随它渐入渐灭
func _focus_presence() -> float:
	if _focus_id == "":
		return 1.0
	return clampf(float(_focus_glow.get(_focus_id, 0.0)), 0.0, 1.0)


func get_visible_edge_count() -> int:
	var count := 0
	for edge in _edges:
		if float(edge.get("strength", 0.0)) < _min_strength or _is_ghost_edge(edge):
			continue
		if not _primary_edge_ids.has(str(edge.get("link_id", ""))):
			continue
		count += 1
	return count


# 孤立主题数必须与画布自己的显示口径一致:同一套主边 Top-K、同一套幽灵过滤。
# 用后端 summary.isolated_count 会漏掉被 Top-K 剪掉的辐条(枢纽图能少报一大截),
# 而且它是加载时的快照,滑杆与游标动过之后就对不上了。
func get_isolated_node_count() -> int:
	var connected: Dictionary = {}
	for edge in _edges:
		if not _is_primary_layout_edge(edge) or _is_ghost_edge(edge):
			continue
		connected[str(edge.get("source", ""))] = true
		connected[str(edge.get("target", ""))] = true
	var count := 0
	for node in _nodes:
		var node_id := str(node.id)
		if _is_ghost_node(node):
			continue
		if not connected.has(node_id):
			count += 1
	return count


func reset_view() -> void:
	# 重置网络视角 = 套住整张图，而不是回到 1 倍缩放 —— 用户点它的意图
	# 永远是「把图找回来」，而 1 倍缩放对已经缩过的图看起来毫无反应。
	fit_to_content()


func fit_to_content(padding := 0.10) -> void:
	"""把视角缩放到刚好容纳所有节点（四周留 padding 比例的边距）。"""
	if _positions.is_empty() or size.x < 8.0 or size.y < 8.0:
		return
	var min_point := Vector2.INF
	var max_point := -Vector2.INF
	for value in _positions.values():
		var point: Vector2 = value
		min_point.x = minf(min_point.x, point.x)
		min_point.y = minf(min_point.y, point.y)
		max_point.x = maxf(max_point.x, point.x)
		max_point.y = maxf(max_point.y, point.y)
	var span := (max_point - min_point).max(Vector2(160.0, 160.0))
	var available := size * (1.0 - padding * 2.0)
	_zoom = clampf(
		minf(available.x / span.x, available.y / span.y), MIN_ZOOM, 1.15
	)
	_pan = -(min_point + max_point) * 0.5 * _zoom
	queue_redraw()


func select_node_by_id(node_id: String, center_node := true) -> void:
	if not is_node_selectable(node_id):
		return
	_selected_id = node_id
	if center_node and _positions.has(node_id):
		_pan = -(_positions[node_id] as Vector2) * _zoom
	# 选中即锚定邻域高亮:从关联列表跳转时鼠标不在画布上,焦点也必须跟上
	_update_focus(node_id)
	node_selected.emit((_node_by_id[node_id] as Dictionary).duplicate(true))
	queue_redraw()


func get_node_by_id(node_id: String) -> Dictionary:
	return (
		(_node_by_id[node_id] as Dictionary).duplicate(true)
		if _node_by_id.has(node_id)
		else {}
	)


func _initialize_positions() -> void:
	# 椭圆向日葵(phyllotaxis)出生:按画布宽高比把节点均匀铺满,第一帧就是
	# "像样的云",力导向只做轻微整理 —— 避免开场一秒还在打结
	var count := maxi(1, _nodes.size())
	var golden_angle := TAU * (3.0 - sqrt(5.0))
	var ratio := clampf(size.x / maxf(1.0, size.y), 1.0, 2.6)
	var base_r := minf(size.x * 0.5, size.y * 0.5) * 0.92
	for index in _nodes.size():
		var node: Dictionary = _nodes[index]
		var node_id := str(node.id)
		var seed := absi(hash(node_id))
		var t := (float(index) + 0.6) / float(count)
		var ring := base_r * sqrt(t)
		var angle := float(index) * golden_angle + float(seed % 1000) / 7000.0
		var position := Vector2.from_angle(angle) * ring
		position.x *= ratio
		_positions[node_id] = position
		_velocities[node_id] = Vector2.ZERO


func _process(delta: float) -> void:
	if (
		_auto_fit_pending
		and _sim_alpha <= SIM_ALPHA_MIN
		and _dragged_id == ""
		and not _positions.is_empty()
	):
		_auto_fit_pending = false
		fit_to_content()
	var animating := _advance_ghost_animation(delta)
	if _advance_emphasis_animation(delta):
		animating = true
	if _sim_alpha > SIM_ALPHA_MIN or _dragged_id != "":
		_simulate(delta)
		animating = true
	if animating:
		queue_redraw()


func _simulate(delta: float) -> void:
	# 温度冷却:拖拽中保持半温(邻居弹性跟随),松手后整图重新加热收敛
	if _dragged_id != "":
		_sim_alpha = maxf(_sim_alpha, SIM_ALPHA_DRAG)
	else:
		_sim_alpha = maxf(0.0, _sim_alpha - SIM_COOL_PER_FRAME * clampf(delta * 60.0, 0.0, 2.0))
	var alpha := _sim_alpha
	var forces: Dictionary = {}
	for node in _nodes:
		forces[str(node.id)] = Vector2.ZERO
	# 1) 库仑斥力(全对,半径感知):重叠/贴近时按半径和额外强推 —— 防堆叠的核心
	for left_index in _nodes.size():
		var left: Dictionary = _nodes[left_index]
		var left_id := str(left.id)
		var left_position: Vector2 = _positions[left_id]
		for right_index in range(left_index + 1, _nodes.size()):
			var right: Dictionary = _nodes[right_index]
			var right_id := str(right.id)
			var difference: Vector2 = (_positions[right_id] as Vector2) - left_position
			var distance_squared := difference.length_squared()
			if distance_squared > REPULSION_CUTOFF_SQ:
				continue
			var distance := maxf(18.0, sqrt(distance_squared))
			var direction := difference / distance
			var push := REPULSION_K / (distance_squared + 420.0)
			push = maxf(push, REPULSION_FLOOR)
			var overlap := (_base_radius(left) + _base_radius(right) + COLLISION_PAD) - distance
			if overlap > 0.0:
				push += overlap * 0.55
			forces[left_id] = (forces[left_id] as Vector2) - direction * push
			forces[right_id] = (forces[right_id] as Vector2) + direction * push
	# 2) 弹簧只使用默认可见的主边。否则不可见关系仍会暗中把节点
	# 拉成团，用户看见的结构与实际布局原因就会脱节。
	for edge in _edges:

		if not _is_primary_layout_edge(edge):
			continue

		var source := str(edge.get("source", ""))
		var target := str(edge.get("target", ""))
		if not _positions.has(source) or not _positions.has(target):
			continue
		var difference: Vector2 = (_positions[target] as Vector2) - (_positions[source] as Vector2)
		var distance := maxf(1.0, difference.length())
		var direction := difference / distance
		var strength := clampf(float(edge.get("strength", 0.4)), 0.1, 1.0)
		var rest_length := lerpf(LINK_LEN_WEAK, LINK_LEN_STRONG, strength)
		# 度数软上限:高连接节点的边变软,卫星散开、连线不再挤成一束
		var hub_soften := 1.0
		var hub_degree := maxi(int(_degrees.get(source, 0)), int(_degrees.get(target, 0)))
		if hub_degree > HUB_DEGREE_SOFT_CAP:
			hub_soften = maxf(0.35, float(HUB_DEGREE_SOFT_CAP) / float(hub_degree))
		var pull := (distance - rest_length) * LINK_SPRING_K * (0.5 + strength * 0.8) * hub_soften
		forces[source] = (forces[source] as Vector2) + direction * pull
		forces[target] = (forces[target] as Vector2) - direction * pull
	# 3) 积分:向心 + 软边界 + 阻尼 + 限速;拖拽节点钉在光标上并携带手速
	var half_view := Vector2(
		maxf(260.0, size.x / maxf(0.42, _zoom) * 0.5 - 40.0),
		maxf(210.0, size.y / maxf(0.42, _zoom) * 0.5 - 46.0)
	)
	# 只依赖控件尺寸,不含相机 —— 相机在自动适配后会变,含进去就成了反馈环。
	# 指数 0.78 是实测出来的:0.5(=开方)只把云拉到面板比例的 74%,
	# 相机受高度限制,左右仍空一大片;0.78 后宽度填充率才跟高度对齐。
	_pane_stretch = pow(clampf(size.x / maxf(1.0, size.y), 1.0, 2.6), 0.78)
	for node in _nodes:
		var node_id := str(node.id)
		if node_id == _dragged_id:
			_positions[node_id] = _drag_target
			_velocities[node_id] = _drag_velocity
			continue
		var position: Vector2 = _positions[node_id]
		var force: Vector2 = forces[node_id]
		# 向心按面板长宽比做各向异性:让云团的形状自己长成面板的比例,
		# 相机适配后才真正铺满,而不是一个正圆浮在宽面板中间、左右空一大片。
		# 注意系数乘积保持不变(除以/乘以 sqrt),整体尺寸才不会跟着比例跑。
		force += -Vector2(
			position.x / _pane_stretch, position.y * _pane_stretch
		) * CENTER_PULL
		# 软边界按归一化椭圆半径往回推，推回强度随越界量超线性增长。
		# 这里必须用"半径"而不是"四条边"：四边约束让节点沿四条直边排成矩形，
		# 实测 74% 的节点落在包围盒边缘 26px 内 —— 打开就是一张方框。
		# 半径约束的平衡态是圆润的一团，没有直边可贴。
		var velocity: Vector2 = ((_velocities[node_id] as Vector2) + force * alpha) * DAMPING
		if velocity.length() > MAX_SPEED:
			velocity = velocity.normalized() * MAX_SPEED
		_velocities[node_id] = velocity
		var next_position := position + velocity
		# 不设"可见范围"的墙。任何沿画布四边或椭圆边缘的容器都会留下形状痕迹：
		# 四边约束让节点排成矩形（实测 74% 落在包围盒边缘），椭圆约束也仍会把
		# 边缘挤成一条弧。Obsidian 的图谱根本没有墙 —— 图自由沉降，相机去适配
		# 内容（见 fit_to_content）。这里只留一道很远的数值兜底，防止某帧被
		# 极端斥力甩飞，正常布局永远碰不到。
		var guard_radius := next_position.length()
		if guard_radius > HARD_BOUNDARY:
			next_position *= HARD_BOUNDARY / guard_radius
		_positions[node_id] = next_position
	for node in _nodes:
		_layout_cache[str(node.id)] = _positions[str(node.id)]


func _update_focus(focus_id: String) -> void:
	if focus_id == _focus_id:
		return
	# 焦点挪走的瞬间,旧焦点的"在场程度"清零:悬停圈与展开边立即熄灭
	if _focus_id != "":
		_focus_glow[_focus_id] = 0.0
	_focus_id = focus_id
	_focus_neighbors.clear()
	if focus_id != "":
		for edge in _edges:
			var source := str(edge.get("source", ""))
			var target := str(edge.get("target", ""))
			if source == focus_id:
				_focus_neighbors[target] = true
			elif target == focus_id:
				_focus_neighbors[source] = true
	queue_redraw()


# 焦点锚定优先级:拖拽 > 悬停 > 选中。选中必须把"只亮邻域"钉住 ——
# 高亮只跟悬停走的话,点开一条记忆后手一挪开整图就重新点亮,
# "只看这段关系"的意图就断了。悬停仍可临时接管(移开回到选中锚点),
# 与 Obsidian 的手感一致。
func _effective_focus_id() -> String:
	if _dragged_id != "":
		return _dragged_id
	if _hovered_id != "":
		return _hovered_id
	return _selected_id


# 用户在空白处的干净点击 = 取消选中:面板详情卡经 selection_invalidated
# 一并回退,高亮恢复全图。
func _deselect() -> void:
	if _selected_id == "":
		return
	_selected_id = ""
	tooltip_text = ""
	_update_focus(_effective_focus_id())
	selection_invalidated.emit()
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), _palette.background)
	# 悬停/拖拽聚焦:邻域保持明亮,其余整体淡出(Obsidian 式可读性核心)
	var focus_active := _focus_id != ""
	var font := get_theme_default_font()
	for edge in _edges:
		var source := str(edge.get("source", ""))
		var target := str(edge.get("target", ""))
		var touches_focus := focus_active and (source == _focus_id or target == _focus_id)
		var touches_light := (
			touches_focus
			or source == _selected_id or target == _selected_id
			or source == _hovered_id or target == _hovered_id
		)
		# 弱边默认不画;但聚焦节点的连接无论强弱都展开(Obsidian 式)
		if float(edge.get("strength", 0.0)) < _min_strength and not touches_focus:
			continue
		# 度数上限:非"常显"边只在聚焦/悬停/选中时出现
		if not touches_light and not _primary_edge_ids.has(str(edge.get("link_id", ""))):
			continue
		if not _positions.has(source) or not _positions.has(target):
			continue
		var strength := clampf(float(edge.get("strength", 0.3)), 0.0, 1.0)
		# 聚焦展开的弱边按中等强度渲染,保证可读
		var render_strength := strength if not touches_focus else maxf(strength, 0.45)
		var ghost_amount := clampf(_edge_ghost_amount(edge), 0.0, 1.0)
		var lit_amount := 1.0 - ghost_amount
		var highlighted := (source == _selected_id or target == _selected_id) and lit_amount > 0.5
		# ADR-015:claim 边(实体↔实体)/claim_source 边(记忆→实体);
		# 游标越过 world_to 的失效主张压暗 —— 「过去相信过」仍可见
		var link_type := str(edge.get("link_type", ""))
		var is_claim_edge := link_type == "claim" or link_type == "claim_source"
		var dead_damp := 1.0
		if is_claim_edge:
			var world_to_variant = edge.get("world_to")
			if world_to_variant != null and _time_cursor >= 0.0 and _time_cursor >= float(world_to_variant):
				dead_damp = 0.32
		var hovered_endpoint := (source == _hovered_id or target == _hovered_id) and lit_amount > 0.5
		# 聚焦亮度经动画量过渡:悬停切换邻域时整片渐暗渐亮,不再硬切
		var focus_mul := float(_emphasis.get("e:%s" % str(edge.get("link_id", "")), 1.0))
		# 只因聚焦而存在的展开边(弱关联/非主边):随焦点节点的在场程度渐入
		var expansion_only := touches_focus and not touches_light and (
			float(edge.get("strength", 0.0)) < _min_strength
			or not _primary_edge_ids.has(str(edge.get("link_id", "")))
		)
		var edge_color: Color
		var edge_width: float
		# ADR-010:亮度经动画量平滑过渡 —— 游标拨过时边"渐亮"
		if is_claim_edge:
			var claim_base := Color("#8A8078") if link_type == "claim_source" else Color("#D8B26A")
			# claim 底网再压一档:满图的金色细线是「铁丝网」观感的另一半来源
			var claim_alpha := 0.10 if link_type == "claim_source" else 0.22 + render_strength * 0.38
			if highlighted or hovered_endpoint or touches_focus:
				claim_alpha += 0.22
			edge_color = Color(claim_base, lerpf(GHOST_EDGE_ALPHA, claim_alpha, lit_amount) * focus_mul * dead_damp)
			edge_width = lerpf(0.4, 0.5 if link_type == "claim_source" else 0.6 + render_strength * 0.8, lit_amount)
		elif highlighted:
			edge_color = Color(Color("#F2D58A"), lerpf(GHOST_EDGE_ALPHA, 0.52 + render_strength * 0.38, lit_amount) * focus_mul)
			edge_width = lerpf(0.4, 1.0 + render_strength * 2.2, lit_amount)
		else:
			# 普通记忆边:细而均匀的灰线(Obsidian 底网),聚焦时再发亮
			# 底网要看得见:0.08 起步在浅色主题的近白底上等于没画,整张图只剩孤点。
			edge_color = Color(Color(_palette.edge), lerpf(GHOST_EDGE_ALPHA, 0.22 + render_strength * 0.26, lit_amount) * focus_mul)
			edge_width = lerpf(0.4, 0.7 + render_strength * 0.7, lit_amount)
		if expansion_only:
			edge_color.a *= _focus_presence()
		draw_line(
			_world_to_screen(_positions[source]),
			_world_to_screen(_positions[target]),
			edge_color,
			edge_width,
			true
		)
		# ADR-015:谓词标签只在端点选中/悬停/聚焦时绘制(避免刷屏)
		if is_claim_edge and lit_amount > 0.5 and (highlighted or hovered_endpoint or touches_focus):
			var predicate := str(edge.get("predicate", ""))
			if not predicate.is_empty():
				var midpoint := (
					_world_to_screen(_positions[source])
					+ _world_to_screen(_positions[target])
				) * 0.5
				draw_string(
					font,
					midpoint + Vector2(-30.0, -3.0),
					predicate,
					HORIZONTAL_ALIGNMENT_CENTER,
					60.0,
					11,
					Color(Color("#F2D58A"), 0.9 * lit_amount * dead_damp)
				)
	var occupied_label_rects: Array[Rect2] = []
	for node in _nodes:
		var node_id := str(node.id)
		var screen_position := _world_to_screen(_positions[node_id])
		if screen_position.x < -80.0 or screen_position.y < -60.0 or screen_position.x > size.x + 80.0 or screen_position.y > size.y + 60.0:
			continue
		var is_entity := _is_entity_node(node)
		var radius := _base_radius(node) * sqrt(_zoom)
		var color := _entity_color(node) if is_entity else _node_color(node)
		var ghost_amount := clampf(_node_ghost_amount(node), 0.0, 1.0)
		var lit_amount := 1.0 - ghost_amount
		var in_focus := not focus_active or node_id == _focus_id or _focus_neighbors.has(node_id)
		# 聚焦亮度经动画量过渡;glow 是悬停圈的「在场程度」(渐入、移开瞬灭)
		var focus_mul := float(_emphasis.get("n:%s" % node_id, 1.0))
		var glow := clampf(float(_focus_glow.get(node_id, 0.0)), 0.0, 1.0)
		var selected := node_id == _selected_id and lit_amount > 0.5
		var hovered := node_id == _hovered_id and lit_amount > 0.5
		if is_entity:
			# ADR-015:实体 = 细环 + 中心点(空心),与记忆实心圆一眼区分
			var ring_alpha := lerpf(0.92, GHOST_NODE_ALPHA, ghost_amount) * focus_mul
			if selected:
				draw_circle(screen_position, radius + 6.0, Color(color, 0.14 * lit_amount * focus_mul))
				draw_arc(screen_position, radius + 4.0, 0.0, TAU, 32, Color(Color("#FFF2C5"), lit_amount), 1.8, true)
			elif hovered:
				draw_arc(screen_position, radius + 3.0, 0.0, TAU, 32, Color(color, 0.6 * lit_amount * glow), 1.4, true)
			draw_arc(screen_position, radius, 0.0, TAU, 32, Color(color, ring_alpha), 1.6, true)
			if lit_amount > 0.02 and in_focus:
				draw_circle(screen_position, maxf(1.5, radius * 0.28), Color(color, ring_alpha))
		else:
			if selected:
				draw_circle(screen_position, radius + 5.0, Color(color, 0.14 * lit_amount * focus_mul))
				draw_arc(screen_position, radius + 3.5, 0.0, TAU, 28, Color(Color("#FFF2C5"), lit_amount), 1.8, true)
			elif hovered:
				draw_circle(screen_position, radius + 4.0, Color(color, 0.16 * lit_amount * glow))
			# ADR-010:游标之后诞生的记忆 = 低亮度"幽灵";亮度经动画量平滑过渡
			var base_alpha := 0.88 if bool(node.get("enabled", true)) else 0.38
			draw_circle(screen_position, radius, Color(color, lerpf(base_alpha, GHOST_NODE_ALPHA, ghost_amount) * focus_mul))
			if bool(node.get("always_active", false)) and lit_amount > 0.02 and in_focus:
				draw_arc(screen_position, radius + 2.5, 0.0, TAU, 24, Color(Color("#FFF0A8"), 0.88 * lit_amount), 1.5, true)
			# 二手传闻(heard_from)节点:右上角细线空心菱形标记
			if bool(node.get("is_second_hand", false)) and lit_amount > 0.02 and in_focus:
				var mark_center := screen_position + Vector2(radius * 0.92, -radius * 0.92)
				var mark_size := maxf(2.2, radius * 0.26)
				var mark_points := PackedVector2Array([
					mark_center + Vector2(0.0, -mark_size),
					mark_center + Vector2(mark_size, 0.0),
					mark_center + Vector2(0.0, mark_size),
					mark_center + Vector2(-mark_size, 0.0),
					mark_center + Vector2(0.0, -mark_size),
				])
				draw_polyline(
					mark_points, Color(Color("#C9B8A0"), 0.82 * lit_amount * focus_mul), 1.2, true
				)
			# ADR-013 D4:夜织/季织节点上方的细线弦月 glyph(自绘,非 emoji)
			if _is_weave_node(node) and lit_amount > 0.02 and in_focus:
				var moon_center := screen_position + Vector2(0.0, -radius - 8.0)
				var moon_radius := maxf(3.5, radius * 0.38)
				var moon_color := Color(Color("#D9CFAE"), 0.85 * lit_amount * focus_mul)
				draw_arc(moon_center, moon_radius, 0.42 * PI, 1.58 * PI, 20, moon_color, 1.4, true)
				draw_arc(moon_center, moon_radius * 0.62, 1.05 * PI, 1.95 * PI, 16, Color(moon_color, 0.55 * lit_amount * focus_mul), 1.1, true)
		# 标签策略(Obsidian 式):名字默认就画在节点下面;字号克制 + 碰撞避让
		# + 远景 LOD 防糊。聚焦时只留邻域;宽度给足,避免 CJK 被截成省略号。
		var should_label := _label_policy_allows(node, focus_active, in_focus, selected, hovered)
		should_label = should_label and lit_amount > 0.5
		if should_label:
			var label := label_text_for(node)
			# 量宽度只为居中/避让;绘制不传宽度约束 —— 从根上杜绝 CJK 被裁成省略号
			var text_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FONT_SIZE)
			var label_position := screen_position + Vector2(-text_size.x * 0.5, radius + 16.0)
			var label_rect := Rect2(
				label_position - Vector2(3.0, 13.0),
				Vector2(text_size.x + 6.0, 19.0)
			)
			var overlaps := false
			if not selected and not hovered:
				for occupied in occupied_label_rects:
					if occupied.intersects(label_rect, true):
						overlaps = true
						break
			if overlaps:
				continue
			occupied_label_rects.append(label_rect)
			# 文字底下垫一层背景色描影:标签压在连线上时仍能读清(Obsidian 同款)
			var label_alpha := 0.82
			if selected:
				label_alpha = 0.95
			elif hovered:
				label_alpha = lerpf(0.82, 0.95, glow)
			else:
				# 邻域标签随亮度动画量一起渐入(聚焦切换时不再成片蹦出)
				label_alpha = 0.82 * clampf(focus_mul, 0.0, 1.0)
			draw_string(
				font,
				label_position + Vector2(1.0, 1.0),
				label,
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				LABEL_FONT_SIZE,
				Color(_palette.background, 0.85)
			)
			draw_string(
				font,
				label_position,
				label,
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				LABEL_FONT_SIZE,
				Color(_palette.text, label_alpha)
			)



func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and mouse_event.pressed:
			var before := _screen_to_world(mouse_event.position)
			var factor := 1.12 if mouse_event.button_index == MOUSE_BUTTON_WHEEL_UP else (1.0 / 1.12)
			_zoom = clampf(_zoom * factor, MIN_ZOOM, MAX_ZOOM)
			_pan += mouse_event.position - _world_to_screen(before)
			accept_event()
			queue_redraw()
			return
		if mouse_event.button_index == MOUSE_BUTTON_LEFT:
			if mouse_event.pressed:
				grab_focus()
				var hit := _hit_test(mouse_event.position)
				if not hit.is_empty():
					_dragged_id = hit
					_drag_target = _positions[hit]
					_drag_velocity = Vector2.ZERO
					_press_was_blank = false
					_wake_physics()
					_update_focus(hit)
					select_node_by_id(hit, false)
				else:
					_panning = true
					_press_was_blank = true
					_press_position = mouse_event.position
					_press_travel = 0.0
			else:
				# 弹弓松手:把手上的速度交给节点,带着邻居惯性滑行
				if _dragged_id != "":
					_velocities[_dragged_id] = _drag_velocity.limit_length(FLING_MAX)
					_wake_physics()
					_dragged_id = ""
					_update_focus(_effective_focus_id())
				# 平移必须无条件结束。它由"空白处按下"开启,而那条路径不会设置
				# _dragged_id —— 放进上面的 if 里会让松手后画布一直跟着鼠标跑,
				# 用户看到的是"鼠标一进图里就甩不掉"。
				_panning = false
				# 空白处的"干净点击"(按下到松手几乎没动) = 取消选中。
				# 选中会把邻域高亮锚定住,必须给一条回到全图的出路,
				# 否则点开一条记忆后就只能永远盯着那一团。
				if (
					_press_was_blank
					and _press_travel < 6.0
					and _press_position.distance_to(mouse_event.position) < 6.0
				):
					_deselect()

			accept_event()
			return
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		# 自愈:左键已经抬起却还停在拖拽/平移态(松手事件没送达,例如在窗口外松手),
		# 按按钮位掩码纠正,避免画布之后一直跟着鼠标跑。
		var left_held := (motion.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0
		if not left_held:
			_panning = false
			if _dragged_id != "":
				_dragged_id = ""
				_update_focus(_effective_focus_id())
		_update_focus(_effective_focus_id())
		if _dragged_id != "" and _positions.has(_dragged_id):
			var world_position := _screen_to_world(motion.position)
			# 手速采样(指数平滑):松手时作为初速度,形成惯性
			_drag_velocity = _drag_velocity * 0.55 + (world_position - _drag_target) * 0.45
			_drag_velocity = _drag_velocity.limit_length(FLING_MAX)
			_drag_target = world_position
			_positions[_dragged_id] = world_position
			accept_event()
		elif _panning:
			_pan += motion.relative
			_press_travel += motion.relative.length()
			accept_event()
		var previous_hover := _hovered_id
		_hovered_id = _hit_test(motion.position)
		if previous_hover != _hovered_id:
			_update_focus(_effective_focus_id())
			var hovered_node: Dictionary = _node_by_id.get(_hovered_id, {})
			tooltip_text = str(
				(hovered_node as Dictionary).get(
					"title",
					str((hovered_node as Dictionary).get("name", ""))
				)
			)
		queue_redraw()


func _hit_test(screen_position: Vector2) -> String:
	for index in range(_nodes.size() - 1, -1, -1):
		var node: Dictionary = _nodes[index]
		# 历史快照中的未来节点只是视觉提示，不应截获点击、被拖动或泄露详情。
		if _is_ghost_node(node):
			continue
		var node_id := str(node.id)
		if not _positions.has(node_id):
			continue
		var radius := _base_radius(node) * sqrt(_zoom) + 8.0
		if _world_to_screen(_positions[node_id]).distance_to(screen_position) <= radius:
			return node_id
	return ""


func _world_to_screen(world_position: Vector2) -> Vector2:
	return world_position * _zoom + size * 0.5 + _pan


func _screen_to_world(screen_position: Vector2) -> Vector2:
	return (screen_position - size * 0.5 - _pan) / _zoom


func _base_radius(node: Dictionary) -> float:
	# Obsidian 式小节点:留白交给布局,而不是靠小图块撑场面。
	# 但默认缩放下会被缩到 0.5 倍左右,原来 4.5 起步几乎看不见。
	if _is_entity_node(node):
		return 7.5
	var importance := clampf(float(node.get("importance", 0.5)), 0.0, 1.0)
	var recall_boost := minf(1.6, log(1.0 + float(node.get("recall_count", 0))) * 0.4)
	return 5.5 + importance * 4.0 + recall_boost


func _visible_member_count(node: Dictionary) -> int:
	var members_variant = node.get("member_records", [])
	if not members_variant is Array:
		return int(node.get("member_count", 1))
	if _time_cursor < 0.0:
		return (members_variant as Array).size()
	var visible := 0
	for member_variant in members_variant:
		if member_variant is Dictionary and float((member_variant as Dictionary).get("world_created_at", 0.0)) <= _time_cursor:
			visible += 1
	return visible


func _node_radius(node: Dictionary) -> float:
	return _base_radius(node)


func _node_color(node: Dictionary) -> Color:
	return _scope_colors.get(str(node.get("scope_role_id", "*")), Color("#B8AEA4"))


func _is_weave_node(node: Dictionary) -> bool:
	# ADR-013:夜织(consolidation_*)与季织(season_weave)节点画弦月 glyph
	var source := str(node.get("source", ""))
	return source.begins_with("consolidation_") or source == "season_weave"


func _is_entity_node(node: Dictionary) -> bool:
	# ADR-015:实体星座节点(细环 + 中心点)
	return str(node.get("node_type", "")) == "entity"


# 绘制与诊断共用同一份标签文案。抽出来的原因很实际:标签块曾经被多缩进一层
# 落进记忆分支,实体节点整类不再绘制名字,而这类"不画了"只能靠肉眼在截图里
# 发现 —— 现在诊断可以直接断言实体节点也有标签。
func label_text_for(node: Dictionary) -> String:
	var label := _short_title(
		str(node.get("name", ""))
		if _is_entity_node(node)
		else str(node.get("display_title", node.get("title", "未命名记忆"))),
		14
	)
	var member_count := _visible_member_count(node)
	if member_count > 1:
		label += " ×%d" % member_count
	return label


# 远景下仍值得画名字的节点:实体、常驻枢纽与高重要度记忆。
# 全量标签交给 LABEL_ZOOM 门槛,这里只负责"缩得很远也认得出地标"。
func _is_label_priority(node: Dictionary) -> bool:
	if _is_entity_node(node):
		return true
	if bool(node.get("always_active", false)):
		return true
	if clampf(float(node.get("importance", 0.5)), 0.0, 1.0) >= 0.78:
		return true
	return int(_degrees.get(str(node.id), 0)) >= 3


# _draw 与诊断计数共用的标签判据:选中/悬停永远画;聚焦态只画邻域;
# 常态按缩放 LOD(全量 → 仅优先节点)。
func _label_policy_allows(
	node: Dictionary, focus_active: bool, in_focus: bool, selected: bool, hovered: bool
) -> bool:
	if selected or hovered:
		return true
	if focus_active:
		return in_focus
	if _zoom >= LABEL_ZOOM:
		return true
	return _is_label_priority(node) and _zoom >= LABEL_PRIORITY_ZOOM


# 诊断口径:按当前缩放/聚焦/幽灵态统计会绘制标签的节点数(与 _draw 同一判据,
# 不含碰撞避让)。探针用"默认视角下大部分节点必须有名字"钉住回归。
func debug_label_count() -> int:
	var count := 0
	var focus_active := _focus_id != ""
	for node in _nodes:
		var node_id := str(node.id)
		var in_focus := not focus_active or node_id == _focus_id or _focus_neighbors.has(node_id)
		if _node_ghost_amount(node) >= 0.5:
			continue
		if _label_policy_allows(
			node,
			focus_active,
			in_focus,
			node_id == _selected_id,
			node_id == _hovered_id
		):
			count += 1
	return count


func _entity_color(node: Dictionary) -> Color:
	# ADR-015:实体按种类取色(人物/器物/地点/事件/概念)
	match str(node.get("kind", "concept")):
		"person":
			return Color("#E8C87A")
		"object":
			return Color("#8FBF9F")
		"place":
			return Color("#7FA8C9")
		"event":
			return Color("#C99AA8")
		_:
			return Color("#B9A9D0")


func _short_title(value: String, limit: int) -> String:
	# 注意:Godot 的 String.split() 无参时按"单个字符"拆分(与 Python 不同),
	# 曾把标题撑成"字 字 相 隔"、撞上限被截断加省略号;这里只折叠换行/制表
	var compact := value.strip_edges().replace("\n", " ").replace("\t", " ")
	return compact if compact.length() <= limit else compact.left(limit) + "…"
