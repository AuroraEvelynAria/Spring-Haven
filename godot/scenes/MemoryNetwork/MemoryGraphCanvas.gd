class_name MemoryGraphCanvas
extends Control

signal node_selected(node: Dictionary)

const DEFAULT_SCOPE_COLORS := {
	"*": Color("#E8C97A"),
	"ling": Color("#72C7B8"),
	"nai": Color("#E6A4BD"),
}
const MIN_ZOOM := 0.42
const MAX_ZOOM := 2.4

var _nodes: Array[Dictionary] = []
var _edges: Array[Dictionary] = []
var _node_by_id: Dictionary = {}
var _positions: Dictionary = {}
var _velocities: Dictionary = {}
var _selected_id := ""
var _hovered_id := ""
var _dragged_id := ""
var _panning := false
var _zoom := 1.0
var _pan := Vector2.ZERO
var _layout_steps := 0
var _min_strength := 0.55
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


func set_graph(graph: Dictionary) -> void:
	_nodes.clear()
	_edges.clear()
	_node_by_id.clear()
	_positions.clear()
	_velocities.clear()
	_selected_id = ""
	_hovered_id = ""
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
		for edge_variant in raw_edges:
			if not edge_variant is Dictionary:
				continue
			var edge: Dictionary = (edge_variant as Dictionary).duplicate(true)
			if _node_by_id.has(str(edge.get("source", ""))) and _node_by_id.has(str(edge.get("target", ""))):
				_edges.append(edge)
	_initialize_positions()
	_layout_steps = 180 if _nodes.size() <= 120 else 120
	_seed_ghost_amounts()
	reset_view()
	queue_redraw()


func set_palette(theme_data: Dictionary) -> void:
	var background := Color(str(theme_data.get("bg", "#100E0D")))
	var text := Color(str(theme_data.get("text", "#F2E9DF")))
	var secondary := Color(str(theme_data.get("secondary", "#A79B90")))
	_palette = {
		"background": background.darkened(0.12) if bool(theme_data.get("is_dark", true)) else background.darkened(0.025),
		"grid": Color(text, 0.045),
		"edge": Color(secondary, 0.72),
		"text": text,
		"muted": secondary,
	}
	queue_redraw()


func set_min_strength(value: float) -> void:
	_min_strength = clampf(value, 0.0, 1.0)
	_layout_steps = maxi(_layout_steps, 90)
	queue_redraw()


func set_time_cursor(world_day: float) -> void:
	"""ADR-010:客户端时间调光。只改亮度目标,不重置布局;
	实际亮度经 _process 逐帧趋近 —— 拖动全程节点不动、过渡平滑。"""
	_time_cursor = world_day
	queue_redraw()


func set_time_fade_days(days: float) -> void:
	_time_fade_days = clampf(days, 0.5, 120.0)
	queue_redraw()


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


func get_visible_edge_count() -> int:
	var count := 0
	for edge in _edges:
		if float(edge.get("strength", 0.0)) >= _min_strength and not _is_ghost_edge(edge):
			count += 1
	return count


func reset_view() -> void:
	_zoom = 1.0
	_pan = Vector2.ZERO
	queue_redraw()


func select_node_by_id(node_id: String, center_node := true) -> void:
	if not _node_by_id.has(node_id):
		return
	_selected_id = node_id
	if center_node and _positions.has(node_id):
		_pan = -(_positions[node_id] as Vector2) * _zoom
	node_selected.emit((_node_by_id[node_id] as Dictionary).duplicate(true))
	queue_redraw()


func get_node_by_id(node_id: String) -> Dictionary:
	return (
		(_node_by_id[node_id] as Dictionary).duplicate(true)
		if _node_by_id.has(node_id)
		else {}
	)


func _initialize_positions() -> void:
	var count := maxi(1, _nodes.size())
	for index in _nodes.size():
		var node: Dictionary = _nodes[index]
		var node_id := str(node.id)
		var seed := absi(hash(node_id))
		var angle := TAU * (float(index) / float(count)) + float(seed % 1000) / 4000.0
		var ring := 100.0 + float(index % 5) * 54.0 + float(seed % 41)
		var anchor := _scope_anchor(str(node.get("scope_role_id", "*")))
		_positions[node_id] = anchor + Vector2.from_angle(angle) * ring
		_velocities[node_id] = Vector2.ZERO


func _process(delta: float) -> void:
	var animating := _advance_ghost_animation(delta)
	if _layout_steps > 0 and _nodes.size() > 1:
		_step_force_layout(delta)
		animating = true
	if animating:
		queue_redraw()


func _step_force_layout(_delta: float) -> void:
	var forces: Dictionary = {}
	for node in _nodes:
		forces[str(node.id)] = Vector2.ZERO
	for left_index in _nodes.size():
		var left_id := str(_nodes[left_index].id)
		var left_position: Vector2 = _positions[left_id]
		for right_index in range(left_index + 1, _nodes.size()):
			var right_id := str(_nodes[right_index].id)
			var difference: Vector2 = (_positions[right_id] as Vector2) - left_position
			var distance_squared := maxf(144.0, difference.length_squared())
			var direction := difference.normalized() if difference.length_squared() > 0.01 else Vector2.RIGHT
			var repulsion := minf(1.8, 4500.0 / distance_squared)
			forces[left_id] = (forces[left_id] as Vector2) - direction * repulsion
			forces[right_id] = (forces[right_id] as Vector2) + direction * repulsion
	for edge in _edges:
		if float(edge.get("strength", 0.0)) < _min_strength:
			continue
		var source := str(edge.get("source", ""))
		var target := str(edge.get("target", ""))
		if not _positions.has(source) or not _positions.has(target):
			continue
		var difference: Vector2 = (_positions[target] as Vector2) - (_positions[source] as Vector2)
		var distance := maxf(1.0, difference.length())
		var direction := difference / distance
		var strength := clampf(float(edge.get("strength", 0.4)), 0.1, 1.0)
		var desired_distance := lerpf(176.0, 108.0, strength)
		var attraction := clampf((distance - desired_distance) * 0.006 * strength, -1.8, 2.6)
		forces[source] = (forces[source] as Vector2) + direction * attraction
		forces[target] = (forces[target] as Vector2) - direction * attraction
	for node in _nodes:
		var node_id := str(node.id)
		if node_id == _dragged_id:
			continue
		var position: Vector2 = _positions[node_id]
		var anchor := _scope_anchor(str(node.get("scope_role_id", "*")))
		var force: Vector2 = forces[node_id]
		force += (anchor - position) * 0.012
		force += -position * 0.008
		var velocity: Vector2 = ((_velocities[node_id] as Vector2) + force) * 0.84
		if velocity.length() > 8.0:
			velocity = velocity.normalized() * 8.0
		_velocities[node_id] = velocity
		var next_position := position + velocity
		var world_half := Vector2(
			maxf(120.0, size.x / maxf(0.2, _zoom) * 0.5 - 48.0),
			maxf(100.0, size.y / maxf(0.2, _zoom) * 0.5 - 58.0)
		)
		next_position.x = clampf(next_position.x, -world_half.x, world_half.x)
		next_position.y = clampf(next_position.y, -world_half.y, world_half.y)
		_positions[node_id] = next_position
	_layout_steps -= 1


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), _palette.background)
	_draw_grid()
	for edge in _edges:
		if float(edge.get("strength", 0.0)) < _min_strength:
			continue
		var source := str(edge.get("source", ""))
		var target := str(edge.get("target", ""))
		if not _positions.has(source) or not _positions.has(target):
			continue
		var strength := clampf(float(edge.get("strength", 0.3)), 0.0, 1.0)
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
		var edge_color: Color
		var edge_width: float
		# ADR-010:亮度经动画量平滑过渡 —— 游标拨过时边"渐亮"
		if is_claim_edge:
			var claim_base := Color("#8A8078") if link_type == "claim_source" else Color("#D8B26A")
			var claim_alpha := 0.16 if link_type == "claim_source" else 0.26 + strength * 0.40
			if highlighted or hovered_endpoint:
				claim_alpha += 0.22
			edge_color = Color(claim_base, lerpf(GHOST_EDGE_ALPHA, claim_alpha, lit_amount) * dead_damp)
			edge_width = lerpf(0.4, 0.5 if link_type == "claim_source" else 0.6 + strength * 0.8, lit_amount)
		elif highlighted:
			edge_color = Color(Color("#F2D58A"), lerpf(GHOST_EDGE_ALPHA, 0.52 + strength * 0.38, lit_amount))
			edge_width = lerpf(0.4, 1.0 + strength * 2.2, lit_amount)
		else:
			edge_color = Color(Color(_palette.edge), lerpf(GHOST_EDGE_ALPHA, 0.04 + strength * 0.12, lit_amount))
			edge_width = lerpf(0.4, 0.45 + strength * 0.72, lit_amount)
		draw_line(
			_world_to_screen(_positions[source]),
			_world_to_screen(_positions[target]),
			edge_color,
			edge_width,
			true
		)
		# ADR-015:谓词标签只在端点选中/悬停时绘制(避免刷屏)
		if is_claim_edge and lit_amount > 0.5 and (highlighted or hovered_endpoint):
			var predicate := str(edge.get("predicate", ""))
			if not predicate.is_empty():
				var midpoint := (
					_world_to_screen(_positions[source])
					+ _world_to_screen(_positions[target])
				) * 0.5
				draw_string(
					get_theme_default_font(),
					midpoint + Vector2(-30.0, -3.0),
					predicate,
					HORIZONTAL_ALIGNMENT_CENTER,
					60.0,
					11,
					Color(Color("#F2D58A"), 0.9 * lit_amount * dead_damp)
				)
	var font := get_theme_default_font()
	var occupied_label_rects: Array[Rect2] = []
	for node in _nodes:
		var node_id := str(node.id)
		var screen_position := _world_to_screen(_positions[node_id])
		if screen_position.x < -80.0 or screen_position.y < -60.0 or screen_position.x > size.x + 80.0 or screen_position.y > size.y + 60.0:
			continue
		var is_entity := _is_entity_node(node)
		var radius := (9.0 if is_entity else _node_radius(node)) * sqrt(_zoom)
		var color := _entity_color(node) if is_entity else _node_color(node)
		var ghost_amount := clampf(_node_ghost_amount(node), 0.0, 1.0)
		var lit_amount := 1.0 - ghost_amount
		var selected := node_id == _selected_id and lit_amount > 0.5
		var hovered := node_id == _hovered_id and lit_amount > 0.5
		if is_entity:
			# ADR-015:实体 = 细环 + 中心点(空心),与记忆实心圆一眼区分
			var ring_alpha := lerpf(0.92, GHOST_NODE_ALPHA, ghost_amount)
			if selected:
				draw_circle(screen_position, radius + 6.0, Color(color, 0.14 * lit_amount))
				draw_arc(screen_position, radius + 4.0, 0.0, TAU, 32, Color(Color("#FFF2C5"), lit_amount), 1.8, true)
			elif hovered:
				draw_arc(screen_position, radius + 3.0, 0.0, TAU, 32, Color(color, 0.6 * lit_amount), 1.4, true)
			draw_arc(screen_position, radius, 0.0, TAU, 32, Color(color, ring_alpha), 1.6, true)
			if lit_amount > 0.02:
				draw_circle(screen_position, maxf(1.5, radius * 0.28), Color(color, ring_alpha))
		else:
			if selected:
				draw_circle(screen_position, radius + 7.0, Color(color, 0.16 * lit_amount))
				draw_arc(screen_position, radius + 5.0, 0.0, TAU, 32, Color(Color("#FFF2C5"), lit_amount), 2.2, true)
			elif hovered:
				draw_circle(screen_position, radius + 5.0, Color(color, 0.18 * lit_amount))
			# ADR-010:游标之后诞生的记忆 = 低亮度"幽灵";亮度经动画量平滑过渡
			var base_alpha := 0.88 if bool(node.get("enabled", true)) else 0.38
			draw_circle(screen_position, radius, Color(color, lerpf(base_alpha, GHOST_NODE_ALPHA, ghost_amount)))
			if lit_amount > 0.02:
				draw_circle(screen_position - Vector2(radius * 0.28, radius * 0.28), maxf(2.0, radius * 0.22), Color(1, 1, 1, 0.34 * lit_amount))
			if bool(node.get("always_active", false)) and lit_amount > 0.02:
				draw_arc(screen_position, radius + 2.5, 0.0, TAU, 24, Color(Color("#FFF0A8"), 0.88 * lit_amount), 1.5, true)
			# ADR-013 D4:夜织/季织节点上方的细线弦月 glyph(自绘,非 emoji)
			if _is_weave_node(node) and lit_amount > 0.02:
				var moon_center := screen_position + Vector2(0.0, -radius - 8.0)
				var moon_radius := maxf(3.5, radius * 0.38)
				var moon_color := Color(Color("#D9CFAE"), 0.85 * lit_amount)
				draw_arc(moon_center, moon_radius, 0.42 * PI, 1.58 * PI, 20, moon_color, 1.4, true)
				draw_arc(moon_center, moon_radius * 0.62, 1.05 * PI, 1.95 * PI, 16, Color(moon_color, 0.55 * lit_amount), 1.1, true)
		var should_label := false
		if is_entity:
			# 实体标签:选中/悬停必显;普通态需放大且有一定主张量
			should_label = selected or hovered or (
				_zoom >= 0.85 and int(node.get("claim_count", 0)) >= 2
			)
		else:
			should_label = selected or hovered or (
				_zoom >= 0.72 and float(node.get("importance", 0.5)) >= 0.66
			)
		should_label = should_label and lit_amount > 0.5
		if should_label:
			var label := _short_title(
				str(node.get("name", "")) if is_entity else str(node.get("display_title", node.get("title", "未命名记忆"))),
				12
			)
			var label_width := clampf(float(label.length()) * 13.0 + 18.0, 86.0, 190.0)
			var label_position := screen_position + Vector2(-label_width * 0.5, radius + 17.0)
			var label_rect := Rect2(label_position - Vector2(2.0, 14.0), Vector2(label_width + 4.0, 20.0))
			var overlaps := false
			if not selected and not hovered:
				for occupied in occupied_label_rects:
					if occupied.intersects(label_rect, true):
						overlaps = true
						break
			if overlaps:
				continue
			occupied_label_rects.append(label_rect)
			draw_string(
				font,
				label_position,
				label,
				HORIZONTAL_ALIGNMENT_CENTER,
				label_width,
				12,
				Color(_palette.text, 0.97 if selected or hovered else 0.78)
			)


func _draw_grid() -> void:
	var spacing := 72.0 * _zoom
	if spacing < 30.0:
		spacing *= 2.0
	var origin := size * 0.5 + _pan
	var start_x := fmod(origin.x, spacing)
	var start_y := fmod(origin.y, spacing)
	var x := start_x
	while x < size.x:
		draw_line(Vector2(x, 0), Vector2(x, size.y), _palette.grid, 1.0)
		x += spacing
	var y := start_y
	while y < size.y:
		draw_line(Vector2(0, y), Vector2(size.x, y), _palette.grid, 1.0)
		y += spacing


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
					select_node_by_id(hit, false)
				else:
					_panning = true
			else:
				_dragged_id = ""
				_panning = false
			accept_event()
			return
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		var previous_hover := _hovered_id
		_hovered_id = _hit_test(motion.position)
		if _dragged_id != "" and _positions.has(_dragged_id):
			_positions[_dragged_id] = _screen_to_world(motion.position)
			_velocities[_dragged_id] = Vector2.ZERO
			_layout_steps = maxi(_layout_steps, 28)
			accept_event()
		elif _panning:
			_pan += motion.relative
			accept_event()
		if previous_hover != _hovered_id:
			tooltip_text = str((_node_by_id.get(_hovered_id, {}) as Dictionary).get("title", ""))
		queue_redraw()


func _hit_test(screen_position: Vector2) -> String:
	for index in range(_nodes.size() - 1, -1, -1):
		var node: Dictionary = _nodes[index]
		var node_id := str(node.id)
		if not _positions.has(node_id):
			continue
		var radius := _node_radius(node) * sqrt(_zoom) + 8.0
		if _world_to_screen(_positions[node_id]).distance_to(screen_position) <= radius:
			return node_id
	return ""


func _world_to_screen(world_position: Vector2) -> Vector2:
	return world_position * _zoom + size * 0.5 + _pan


func _screen_to_world(screen_position: Vector2) -> Vector2:
	return (screen_position - size * 0.5 - _pan) / _zoom


func _node_radius(node: Dictionary) -> float:
	var importance := clampf(float(node.get("importance", 0.5)), 0.0, 1.0)
	var recall_boost := minf(3.0, log(1.0 + float(node.get("recall_count", 0))) * 0.8)
	return 8.0 + importance * 8.0 + recall_boost


func _node_color(node: Dictionary) -> Color:
	return _scope_colors.get(str(node.get("scope_role_id", "*")), Color("#B8AEA4"))


func _is_weave_node(node: Dictionary) -> bool:
	# ADR-013:夜织(consolidation_*)与季织(season_weave)节点画弦月 glyph
	var source := str(node.get("source", ""))
	return source.begins_with("consolidation_") or source == "season_weave"


func _is_entity_node(node: Dictionary) -> bool:
	# ADR-015:实体星座节点(细环 + 中心点)
	return str(node.get("node_type", "")) == "entity"


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


func _scope_anchor(scope: String) -> Vector2:
	match scope:
		"ling":
			return Vector2(-180.0, 12.0)
		"nai":
			return Vector2(180.0, 12.0)
		_:
			return Vector2(0.0, -70.0)


func _short_title(value: String, limit: int) -> String:
	var compact := " ".join(value.split())
	return compact if compact.length() <= limit else compact.left(limit) + "…"
