class_name LineIconButton
extends Button

## 无贴图的线性图标按钮。仍是原生 Button，保留键盘焦点、tooltip、disabled 与 pressed。

@export var icon_id := ""
@export var icon_size := 18.0
@export var icon_stroke := 1.7
@export var icon_only := true

var _icon_color := Color.WHITE


func _ready() -> void:
	custom_minimum_size = Vector2(38, 38) if icon_only else custom_minimum_size
	focus_mode = Control.FOCUS_ALL
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
	button_down.connect(queue_redraw)
	button_up.connect(queue_redraw)
	queue_redraw()


func set_icon(value: String) -> void:
	icon_id = value
	queue_redraw()


func _draw() -> void:
	if icon_id.is_empty():
		return
	var color := _resolve_icon_color()
	var box := Rect2(Vector2.ZERO, size)
	var center := box.get_center()
	var radius := minf(icon_size, minf(size.x, size.y) * 0.56) * 0.5
	_draw_icon(center, radius, color)


func _resolve_icon_color() -> Color:
	var data := ThemeMgr.get_current_theme_data()
	var base := Color(str(data.get("secondary", "#A79B90")))
	if disabled:
		return Color(base, 0.38)
	if button_pressed:
		return Color(str(data.get("accent", data.get("primary", "#C96B2E"))))
	if is_hovered() or has_focus():
		return Color(str(data.get("primary", "#C96B2E")))
	return Color(base, 0.94)


func _line(from: Vector2, to: Vector2, color: Color, width := icon_stroke) -> void:
	draw_line(from, to, color, width, true)


func _draw_icon(center: Vector2, r: float, color: Color) -> void:
	match icon_id:
		"memory", "graph":
			var points := [
				center + Vector2(-r * 0.8, -r * 0.25),
				center + Vector2(r * 0.6, -r * 0.72),
				center + Vector2(r * 0.75, r * 0.62),
				center + Vector2(-r * 0.65, r * 0.72),
			]
			_line(points[0], points[1], color)
			_line(points[1], points[2], color)
			_line(points[2], points[3], color)
			_line(points[3], points[0], color)
			for point in points:
				draw_circle(point, maxf(1.8, r * 0.19), color)
		"archive", "book":
			var left := Rect2(center + Vector2(-r, -r * 0.78), Vector2(r, r * 1.56))
			var right := Rect2(center + Vector2(0.0, -r * 0.78), Vector2(r, r * 1.56))
			draw_arc(left.get_center(), r * 0.86, PI * 0.5, PI * 1.5, 14, color, icon_stroke, true)
			draw_arc(right.get_center(), r * 0.86, -PI * 0.5, PI * 0.5, 14, color, icon_stroke, true)
			_line(center + Vector2(0.0, -r * 0.8), center + Vector2(0.0, r * 0.8), color)
		"settings", "sliders":
			for row_value: float in [-0.58, 0.0, 0.58]:
				var y: float = center.y + row_value * r
				_line(Vector2(center.x - r, y), Vector2(center.x + r, y), color)
				var offset: float = -0.32 if is_equal_approx(row_value, -0.58) else (0.28 if is_zero_approx(row_value) else -0.05)
				draw_circle(Vector2(center.x + offset * r, y), maxf(1.7, r * 0.16), color)
		"search":
			draw_arc(center + Vector2(-r * 0.18, -r * 0.18), r * 0.53, 0.0, TAU, 20, color, icon_stroke, true)
			_line(center + Vector2(r * 0.2, r * 0.2), center + Vector2(r * 0.82, r * 0.82), color)
		"close":
			_line(center + Vector2(-r * 0.65, -r * 0.65), center + Vector2(r * 0.65, r * 0.65), color)
			_line(center + Vector2(r * 0.65, -r * 0.65), center + Vector2(-r * 0.65, r * 0.65), color)
		"stop":
			draw_rect(Rect2(center - Vector2(r * 0.52, r * 0.52), Vector2(r * 1.04, r * 1.04)), color, false, icon_stroke, true)
		"refresh":
			draw_arc(center, r * 0.68, -PI * 0.15, PI * 1.45, 20, color, icon_stroke, true)
			var tip := center + Vector2(r * 0.72, -r * 0.08)
			_line(tip, tip + Vector2(-r * 0.42, -r * 0.05), color)
			_line(tip, tip + Vector2(-r * 0.08, r * 0.38), color)
		"home", "reset":
			var roof := PackedVector2Array([
				center + Vector2(-r * 0.9, -r * 0.05),
				center + Vector2(0.0, -r * 0.8),
				center + Vector2(r * 0.9, -r * 0.05),
			])
			draw_polyline(roof, color, icon_stroke, true)
			draw_rect(Rect2(center + Vector2(-r * 0.54, -r * 0.05), Vector2(r * 1.08, r * 0.86)), color, false, icon_stroke, true)
			_line(center + Vector2(0.0, r * 0.26), center + Vector2(0.0, r * 0.8), color)
		"microphone", "voice":
			draw_arc(center + Vector2(0.0, -r * 0.18), r * 0.36, PI, TAU, 14, color, icon_stroke, true)
			draw_arc(center + Vector2(0.0, -r * 0.18), r * 0.36, 0.0, PI, 14, color, icon_stroke, true)
			_line(center + Vector2(-r * 0.62, r * 0.05), center + Vector2(-r * 0.62, r * 0.28), color)
			draw_arc(center + Vector2(0.0, r * 0.04), r * 0.62, 0.0, PI, 16, color, icon_stroke, true)
			_line(center + Vector2(0.0, r * 0.65), center + Vector2(0.0, r * 0.92), color)
		"send":
			var paper := PackedVector2Array([
				center + Vector2(-r * 0.85, -r * 0.58),
				center + Vector2(r * 0.9, 0.0),
				center + Vector2(-r * 0.85, r * 0.58),
				center + Vector2(-r * 0.38, 0.0),
				center + Vector2(-r * 0.85, -r * 0.58),
			])
			draw_polyline(paper, color, icon_stroke, true)
			_line(center + Vector2(-r * 0.38, 0.0), center + Vector2(r * 0.38, 0.0), color)
		"theme", "sun":
			draw_arc(center, r * 0.38, 0.0, TAU, 18, color, icon_stroke, true)
			for angle in [0.0, PI * 0.25, PI * 0.5, PI * 0.75, PI, PI * 1.25, PI * 1.5, PI * 1.75]:
				var direction := Vector2.from_angle(angle)
				_line(center + direction * r * 0.58, center + direction * r * 0.88, color, icon_stroke)
		"moon":
			draw_arc(center, r * 0.64, PI * 0.30, PI * 1.70, 20, color, icon_stroke, true)
			draw_arc(center + Vector2(r * 0.25, -r * 0.06), r * 0.54, PI * 0.44, PI * 1.58, 18, color, icon_stroke, true)
		"leaf", "life":
			var leaf := PackedVector2Array([
				center + Vector2(-r * 0.78, r * 0.62),
				center + Vector2(-r * 0.22, -r * 0.72),
				center + Vector2(r * 0.78, -r * 0.52),
				center + Vector2(r * 0.48, r * 0.55),
				center + Vector2(-r * 0.78, r * 0.62),
			])
			draw_polyline(leaf, color, icon_stroke, true)
			_line(center + Vector2(-r * 0.54, r * 0.46), center + Vector2(r * 0.52, -r * 0.38), color)
		"compass", "explore":
			draw_arc(center, r * 0.72, 0.0, TAU, 20, color, icon_stroke, true)
			var needle := PackedVector2Array([
				center + Vector2(0.0, -r * 0.58),
				center + Vector2(r * 0.25, r * 0.24),
				center + Vector2(0.0, r * 0.58),
				center + Vector2(-r * 0.25, -r * 0.24),
				center + Vector2(0.0, -r * 0.58),
			])
			draw_polyline(needle, color, icon_stroke, true)
		"status", "heart":
			var left := center + Vector2(-r * 0.28, -r * 0.16)
			var right := center + Vector2(r * 0.28, -r * 0.16)
			draw_arc(left, r * 0.35, PI, TAU, 12, color, icon_stroke, true)
			draw_arc(right, r * 0.35, PI, TAU, 12, color, icon_stroke, true)
			_line(center + Vector2(-r * 0.62, -r * 0.12), center + Vector2(0.0, r * 0.72), color)
			_line(center + Vector2(r * 0.62, -r * 0.12), center + Vector2(0.0, r * 0.72), color)
		"back":
			_line(center + Vector2(r * 0.72, 0.0), center + Vector2(-r * 0.62, 0.0), color)
			_line(center + Vector2(-r * 0.62, 0.0), center + Vector2(-r * 0.06, -r * 0.56), color)
			_line(center + Vector2(-r * 0.62, 0.0), center + Vector2(-r * 0.06, r * 0.56), color)
		_:
			draw_circle(center, r * 0.18, color)
