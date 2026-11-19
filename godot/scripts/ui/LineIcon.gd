class_name LineIcon
extends Control

## 纯绘制的线性图标控件(非按钮):零贴图、随主题色,与 LineIconButton
## 同一套图形定义。用于"只要一个图标"的场合——标题行、标签行、状态行;
## LineIconButton(icon_only=false)也内嵌它做"图标+文字"组合。

@export var icon_id := ""
@export var icon_size := 18.0
@export var icon_stroke := 1.7
@export var tint := Color(0, 0, 0, 0): set = _set_tint

var _explicit_tint := false


func _ready() -> void:
	custom_minimum_size = Vector2(icon_size, icon_size)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _set_tint(value: Color) -> void:
	tint = value
	_explicit_tint = value.a > 0.0
	queue_redraw()


func set_icon(value: String) -> void:
	icon_id = value
	queue_redraw()


func _draw() -> void:
	if icon_id.is_empty():
		return
	var color: Color
	if _explicit_tint:
		color = tint
	else:
		color = Color(str(ThemeMgr.get_current_theme_data().get("secondary", "#A79B90")))
	var center := Vector2(size.x / 2.0, size.y / 2.0)
	var radius := minf(icon_size, minf(size.x, size.y)) * 0.5
	draw_icon(icon_id, center, radius, color, icon_stroke)


## 图形字典:与 LineIconButton 完全同源的定义。新增图标在此登记,
## 两处(LineIcon/LineIconButton)共用。
func draw_icon(id: String, center: Vector2, r: float, color: Color, stroke: float) -> void:
	match id:
		"memory", "graph":
			var points := [
				center + Vector2(-r * 0.8, -r * 0.25),
				center + Vector2(r * 0.6, -r * 0.72),
				center + Vector2(r * 0.75, r * 0.62),
				center + Vector2(-r * 0.65, r * 0.72),
			]
			draw_line(points[0], points[1], color, stroke, true)
			draw_line(points[1], points[2], color, stroke, true)
			draw_line(points[2], points[3], color, stroke, true)
			draw_line(points[3], points[0], color, stroke, true)
			for point in points:
				draw_circle(point, maxf(1.8, r * 0.19), color)
		"archive", "book":
			var left := Rect2(center + Vector2(-r, -r * 0.78), Vector2(r, r * 1.56))
			var right := Rect2(center + Vector2(0.0, -r * 0.78), Vector2(r, r * 1.56))
			draw_arc(left.get_center(), r * 0.86, PI * 0.5, PI * 1.5, 14, color, stroke, true)
			draw_arc(right.get_center(), r * 0.86, -PI * 0.5, PI * 0.5, 14, color, stroke, true)
			draw_line(center + Vector2(0.0, -r * 0.8), center + Vector2(0.0, r * 0.8), color, stroke, true)
		"settings", "sliders":
			for row_value: float in [-0.58, 0.0, 0.58]:
				var y: float = center.y + row_value * r
				draw_line(Vector2(center.x - r, y), Vector2(center.x + r, y), color, stroke, true)
				var offset: float = -0.32 if is_equal_approx(row_value, -0.58) else (0.28 if is_zero_approx(row_value) else -0.05)
				draw_circle(Vector2(center.x + offset * r, y), maxf(1.7, r * 0.16), color)
		"search":
			draw_arc(center + Vector2(-r * 0.18, -r * 0.18), r * 0.53, 0.0, TAU, 20, color, stroke, true)
			draw_line(center + Vector2(r * 0.2, r * 0.2), center + Vector2(r * 0.82, r * 0.82), color, stroke, true)
		"close":
			draw_line(center + Vector2(-r * 0.65, -r * 0.65), center + Vector2(r * 0.65, r * 0.65), color, stroke, true)
			draw_line(center + Vector2(r * 0.65, -r * 0.65), center + Vector2(-r * 0.65, r * 0.65), color, stroke, true)
		"stop":
			draw_rect(Rect2(center - Vector2(r * 0.52, r * 0.52), Vector2(r * 1.04, r * 1.04)), color, false, stroke, true)
		"refresh":
			draw_arc(center, r * 0.68, -PI * 0.15, PI * 1.45, 20, color, stroke, true)
			var tip := center + Vector2(r * 0.72, -r * 0.08)
			draw_line(tip, tip + Vector2(-r * 0.42, -r * 0.05), color, stroke, true)
			draw_line(tip, tip + Vector2(-r * 0.08, r * 0.38), color, stroke, true)
		"home", "reset":
			var roof := PackedVector2Array([
				center + Vector2(-r * 0.9, -r * 0.05),
				center + Vector2(0.0, -r * 0.8),
				center + Vector2(r * 0.9, -r * 0.05),
			])
			draw_polyline(roof, color, stroke, true)
			draw_rect(Rect2(center + Vector2(-r * 0.54, -r * 0.05), Vector2(r * 1.08, r * 0.86)), color, false, stroke, true)
			draw_line(center + Vector2(0.0, r * 0.26), center + Vector2(0.0, r * 0.8), color, stroke, true)
		"microphone", "voice":
			draw_arc(center + Vector2(0.0, -r * 0.18), r * 0.36, PI, TAU, 14, color, stroke, true)
			draw_arc(center + Vector2(0.0, -r * 0.18), r * 0.36, 0.0, PI, 14, color, stroke, true)
			draw_line(center + Vector2(-r * 0.62, r * 0.05), center + Vector2(-r * 0.62, r * 0.28), color, stroke, true)
			draw_arc(center + Vector2(0.0, r * 0.04), r * 0.62, 0.0, PI, 16, color, stroke, true)
			draw_line(center + Vector2(0.0, r * 0.65), center + Vector2(0.0, r * 0.92), color, stroke, true)
		"send":
			var paper := PackedVector2Array([
				center + Vector2(-r * 0.85, -r * 0.58),
				center + Vector2(r * 0.9, 0.0),
				center + Vector2(-r * 0.85, r * 0.58),
				center + Vector2(-r * 0.38, 0.0),
				center + Vector2(-r * 0.85, -r * 0.58),
			])
			draw_polyline(paper, color, stroke, true)
			draw_line(center + Vector2(-r * 0.38, 0.0), center + Vector2(r * 0.38, 0.0), color, stroke, true)
		"theme", "sun":
			draw_arc(center, r * 0.38, 0.0, TAU, 18, color, stroke, true)
			for angle in [0.0, PI * 0.25, PI * 0.5, PI * 0.75, PI, PI * 1.25, PI * 1.5, PI * 1.75]:
				var direction := Vector2.from_angle(angle)
				draw_line(center + direction * r * 0.58, center + direction * r * 0.88, color, stroke, true)
		"moon":
			draw_arc(center, r * 0.64, PI * 0.30, PI * 1.70, 20, color, stroke, true)
			draw_arc(center + Vector2(r * 0.25, -r * 0.06), r * 0.54, PI * 0.44, PI * 1.58, 18, color, stroke, true)
		"leaf", "life":
			var leaf := PackedVector2Array([
				center + Vector2(-r * 0.78, r * 0.62),
				center + Vector2(-r * 0.22, -r * 0.72),
				center + Vector2(r * 0.78, -r * 0.52),
				center + Vector2(r * 0.48, r * 0.55),
				center + Vector2(-r * 0.78, r * 0.62),
			])
			draw_polyline(leaf, color, stroke, true)
			draw_line(center + Vector2(-r * 0.54, r * 0.46), center + Vector2(r * 0.52, -r * 0.38), color, stroke, true)
		"compass", "explore":
			draw_arc(center, r * 0.72, 0.0, TAU, 20, color, stroke, true)
			var needle := PackedVector2Array([
				center + Vector2(0.0, -r * 0.58),
				center + Vector2(r * 0.25, r * 0.24),
				center + Vector2(0.0, r * 0.58),
				center + Vector2(-r * 0.25, -r * 0.24),
				center + Vector2(0.0, -r * 0.58),
			])
			draw_polyline(needle, color, stroke, true)
		"status", "heart":
			var left := center + Vector2(-r * 0.28, -r * 0.16)
			var right := center + Vector2(r * 0.28, -r * 0.16)
			draw_arc(left, r * 0.35, PI, TAU, 12, color, stroke, true)
			draw_arc(right, r * 0.35, PI, TAU, 12, color, stroke, true)
			draw_line(center + Vector2(-r * 0.62, -r * 0.12), center + Vector2(0.0, r * 0.72), color, stroke, true)
			draw_line(center + Vector2(r * 0.62, -r * 0.12), center + Vector2(0.0, r * 0.72), color, stroke, true)
		"back":
			draw_line(center + Vector2(r * 0.72, 0.0), center + Vector2(-r * 0.62, 0.0), color, stroke, true)
			draw_line(center + Vector2(-r * 0.62, 0.0), center + Vector2(-r * 0.06, -r * 0.56), color, stroke, true)
			draw_line(center + Vector2(-r * 0.62, 0.0), center + Vector2(-r * 0.06, r * 0.56), color, stroke, true)
		"spark":
			# 四芒星:AI/魔法感,笔画直线化与全族一致
			var star := PackedVector2Array([
				center + Vector2(0.0, -r * 0.85),
				center + Vector2(r * 0.22, -r * 0.22),
				center + Vector2(r * 0.85, 0.0),
				center + Vector2(r * 0.22, r * 0.22),
				center + Vector2(0.0, r * 0.85),
				center + Vector2(-r * 0.22, r * 0.22),
				center + Vector2(-r * 0.85, 0.0),
				center + Vector2(-r * 0.22, -r * 0.22),
				center + Vector2(0.0, -r * 0.85),
			])
			draw_polyline(star, color, stroke, true)
		"database":
			# 圆柱体:数据/知识库
			draw_arc(center + Vector2(0.0, -r * 0.52), r * 0.55, 0.0, TAU, 16, color, stroke, true)
			draw_line(center + Vector2(-r * 0.55, -r * 0.52), center + Vector2(-r * 0.55, r * 0.52), color, stroke, true)
			draw_line(center + Vector2(r * 0.55, -r * 0.52), center + Vector2(r * 0.55, r * 0.52), color, stroke, true)
			draw_arc(center + Vector2(0.0, r * 0.52), r * 0.55, PI, TAU, 16, color, stroke, true)
			draw_arc(center + Vector2(0.0, 0.0), r * 0.55, PI, TAU, 16, color, stroke, true)
		"copy", "duplicate":
			var front := Rect2(center + Vector2(-r * 0.1, -r * 0.1), Vector2(r * 0.8, r * 0.8))
			draw_rect(front, color, false, stroke, true)
			var back := Rect2(center + Vector2(-r * 0.7, -r * 0.7), Vector2(r * 0.8, r * 0.8))
			draw_rect(back, color, false, stroke, true)
		"download":
			draw_line(center + Vector2(0.0, -r * 0.8), center + Vector2(0.0, r * 0.4), color, stroke, true)
			draw_line(center + Vector2(-r * 0.4, r * 0.1), center + Vector2(0.0, r * 0.55), color, stroke, true)
			draw_line(center + Vector2(r * 0.4, r * 0.1), center + Vector2(0.0, r * 0.55), color, stroke, true)
			draw_line(center + Vector2(-r * 0.75, r * 0.8), center + Vector2(r * 0.75, r * 0.8), color, stroke, true)
		_:
			draw_circle(center, r * 0.18, color)
