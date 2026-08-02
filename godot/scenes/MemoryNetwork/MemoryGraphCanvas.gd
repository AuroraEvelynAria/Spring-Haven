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


func get_visible_edge_count() -> int:
	var count := 0
	for edge in _edges:
		if float(edge.get("strength", 0.0)) >= _min_strength:
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


func _process(_delta: float) -> void:
	if _layout_steps <= 0 or _nodes.size() <= 1:
		return
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
	queue_redraw()


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
		var highlighted := source == _selected_id or target == _selected_id
		var edge_color: Color = Color(_palette.edge, 0.04 + strength * (0.55 if highlighted else 0.12))
		if highlighted:
			edge_color = Color("#F2D58A", 0.52 + strength * 0.38)
		draw_line(
			_world_to_screen(_positions[source]),
			_world_to_screen(_positions[target]),
			edge_color,
			(1.0 + strength * 2.2) if highlighted else (0.45 + strength * 0.72),
			true
		)
	var font := get_theme_default_font()
	var occupied_label_rects: Array[Rect2] = []
	for node in _nodes:
		var node_id := str(node.id)
		var screen_position := _world_to_screen(_positions[node_id])
		if screen_position.x < -80.0 or screen_position.y < -60.0 or screen_position.x > size.x + 80.0 or screen_position.y > size.y + 60.0:
			continue
		var radius := _node_radius(node) * sqrt(_zoom)
		var color := _node_color(node)
		var selected := node_id == _selected_id
		var hovered := node_id == _hovered_id
		if selected:
			draw_circle(screen_position, radius + 7.0, Color(color, 0.16))
			draw_arc(screen_position, radius + 5.0, 0.0, TAU, 32, Color("#FFF2C5"), 2.2, true)
		elif hovered:
			draw_circle(screen_position, radius + 5.0, Color(color, 0.18))
		draw_circle(screen_position, radius, Color(color, 0.88 if bool(node.get("enabled", true)) else 0.38))
		draw_circle(screen_position - Vector2(radius * 0.28, radius * 0.28), maxf(2.0, radius * 0.22), Color(1, 1, 1, 0.34))
		if bool(node.get("always_active", false)):
			draw_arc(screen_position, radius + 2.5, 0.0, TAU, 24, Color("#FFF0A8", 0.88), 1.5, true)
		var should_label := selected or hovered or (
			_zoom >= 0.72 and float(node.get("importance", 0.5)) >= 0.66
		)
		if should_label:
			var label := _short_title(str(node.get("display_title", node.get("title", "未命名记忆"))), 12)
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
