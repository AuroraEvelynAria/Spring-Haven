class_name MemoryDecayCurve
extends Control

## ADR-014 消费侧:选中记忆的艾宾浩斯遗忘曲线 R(t) = 0.5^(年龄 / 有效半衰期),
## 有效半衰期 = half_life_days × intrinsic(与召回打分同一公式,后端字段直供)。
## 曲线画到「预计再淡忘一段」的投射区间;「现在」点标出当下可提取性。

const SAMPLES := 64

var _params: Dictionary = {}
var _primary := Color("#C96B2E")
var _muted := Color("#A79B90")
var _text := Color("#F2E9DF")

func set_series(params: Dictionary) -> void:
	_params = params.duplicate(true)
	queue_redraw()

func set_palette(theme_data: Dictionary) -> void:
	_primary = Color(str(theme_data.get("primary", "#C96B2E")))
	_muted = Color(str(theme_data.get("secondary", "#A79B90")))
	_text = Color(str(theme_data.get("text", "#F2E9DF")))
	queue_redraw()

func _draw() -> void:
	if _params.is_empty():
		return
	var half_life := float(_params.get("half_life_days", 0.0))
	var intrinsic := maxf(0.05, float(_params.get("intrinsic", 1.0)))
	var updated := float(_params.get("world_updated_at", 0.0))
	var now := maxf(float(_params.get("world_now", updated)), updated)
	var pad_left := 8.0
	var pad_right := 52.0
	var pad_top := 8.0
	var pad_bottom := 13.0
	var plot := Rect2(
		Vector2(pad_left, pad_top),
		Vector2(maxf(40.0, size.x - pad_left - pad_right), maxf(16.0, size.y - pad_top - pad_bottom))
	)
	var font := get_theme_default_font()
	# 极简坐标:左轴 + 底轴 + R=0.5 半衰参考线
	draw_line(
		Vector2(plot.position.x, plot.end.y), Vector2(plot.end.x, plot.end.y),
		Color(_muted, 0.35), 1.0
	)
	draw_line(
		Vector2(plot.position.x, plot.position.y), Vector2(plot.position.x, plot.end.y),
		Color(_muted, 0.35), 1.0
	)
	var half_y := plot.end.y - 0.5 * plot.size.y
	draw_line(
		Vector2(plot.position.x, half_y), Vector2(plot.end.x, half_y),
		Color(_muted, 0.2), 1.0
	)
	if half_life <= 0.0:
		# half_life = 0:常驻记忆,不随时间衰减(ADR-001 语义)
		draw_line(
			Vector2(plot.position.x, plot.position.y), Vector2(plot.end.x, plot.position.y),
			Color(_primary, 0.9), 1.6
		)
		draw_string(
			font, Vector2(plot.position.x + 6.0, plot.position.y + 12.0),
			"常驻记忆 · 不随时间衰减",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(_text, 0.85)
		)
		return
	var effective := half_life * intrinsic
	# 横轴投射到「现在」与两倍半衰的较远者:既能看到过去,也能看到将淡忘成什么样
	var span := maxf(maxf(effective * 2.2, now - updated), 1.0)
	var points := PackedVector2Array()
	var half_cross_x := -1.0
	for index in SAMPLES + 1:
		var t := float(index) / float(SAMPLES) * span
		var r := pow(0.5, t / effective)
		points.append(Vector2(
			plot.position.x + (t / span) * plot.size.x,
			plot.end.y - r * plot.size.y
		))
		if half_cross_x < 0.0 and r <= 0.5:
			half_cross_x = plot.position.x + (t / span) * plot.size.x
	draw_polyline(points, Color(_primary, 0.92), 1.6, true)
	if half_cross_x > 0.0 and half_cross_x < plot.end.x:
		draw_line(
			Vector2(half_cross_x, half_y - 3.0), Vector2(half_cross_x, half_y + 3.0),
			Color(_primary, 0.8), 1.2
		)
		draw_string(
			font, Vector2(half_cross_x + 4.0, half_y + 3.5),
			"半衰",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(_muted, 0.9)
		)
	# 「现在」点:当下可提取性
	var age := maxf(0.0, now - updated)
	var r_now := pow(0.5, age / effective)
	var now_x := plot.position.x + (minf(age, span) / span) * plot.size.x
	var now_y := plot.end.y - r_now * plot.size.y
	draw_circle(Vector2(now_x, now_y), 3.0, Color(_primary, 1.0))
	var label_position := Vector2(minf(now_x + 6.0, plot.end.x - 52.0), clampf(now_y + 4.0, pad_top + 11.0, plot.end.y))
	draw_string(
		font, label_position,
		"现在 R=%d%%" % roundi(r_now * 100.0),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(_text, 0.92)
	)
