class_name GardenSceneBackdrop
extends Control

## 无外部美术资产的庭院场景底板：窗、光束、地面、叶影与低频微尘。
## 必须作为页面的第一个子节点，且始终忽略鼠标输入。

const PARTICLE_COUNT := 32
const WINDOW_RATIO := Vector2(0.23, 0.10)
const FLOOR_START := 0.80

var _particles: Array[Dictionary] = []
var _rng := RandomNumberGenerator.new()
var _animating := true
var _parallax := Vector2.ZERO


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rng.randomize()
	_initialize_particles()
	_animating = not bool(Settings.settings.ui.get("reduced_motion", false))
	set_process(_animating)
	Settings.visual_accessibility_changed.connect(set_animating)
	queue_redraw()


func refresh_theme() -> void:
	queue_redraw()


func set_animating(value: bool) -> void:
	if _animating == value:
		return
	_animating = value
	set_process(value)
	queue_redraw()


func _process(delta: float) -> void:
	var viewport_size := size.max(Vector2(1.0, 1.0))
	var mouse_target := (get_local_mouse_position() - viewport_size * 0.5) / viewport_size
	_parallax = _parallax.lerp(mouse_target * 8.0, clampf(delta * 2.2, 0.0, 1.0))
	for particle in _particles:
		particle.position.y += float(particle.speed) * delta
		particle.position.x += sin(Time.get_ticks_msec() * 0.00055 + float(particle.phase)) * delta * 12.0
		if particle.position.y > viewport_size.y + 10.0:
			particle.position = Vector2(_rng.randf_range(0.0, viewport_size.x), -10.0)
	queue_redraw()


func _draw() -> void:
	var data := ThemeMgr.get_current_theme_data()
	var viewport_size := size.max(Vector2(1.0, 1.0))
	var background := Color(str(data.get("bg", "#F6F1E7")))
	var text := Color(str(data.get("text", "#33291F")))
	var primary := Color(str(data.get("primary", "#C96B2E")))
	var dark := bool(data.get("is_dark", false))
	# 底板配色一律走 ThemeManager 的场景 token。以前这里自己重算一套(公式还和
	# token 不一样),结果是那些 token 没有任何消费者、改主题也调不到底板。
	var pane_top: Color = data.get("scene_pane_a", background.lightened(0.10))
	var pane_bottom: Color = data.get(
		"scene_pane_b", Color(primary, 0.16).lerp(background, 0.62)
	)
	var wood: Color = data.get("wood", primary.darkened(0.18))
	var leaf: Color = data.get("leaf", primary.darkened(0.40))
	var line: Color = data.get("line", Color(text, 0.10))

	draw_rect(Rect2(Vector2.ZERO, viewport_size), background)
	# 柔和的天光与舞台焦点。
	draw_circle(viewport_size * Vector2(0.74, 0.38), minf(viewport_size.x, viewport_size.y) * 0.48, Color(primary, 0.055 if not dark else 0.08))
	draw_circle(viewport_size * Vector2(0.18, 0.08), minf(viewport_size.x, viewport_size.y) * 0.34, Color(pane_top, 0.52))

	# 左上庭院窗：纯几何，不依赖任何背景图。
	var window_size := Vector2(minf(310.0, viewport_size.x * 0.28), minf(350.0, viewport_size.y * 0.53))
	var window_pos := viewport_size * WINDOW_RATIO + _parallax * 0.22
	var outer := Rect2(window_pos, window_size)
	draw_rect(outer.grow(7.0), Color(wood, 0.82), true)
	draw_rect(outer, pane_bottom, true)
	draw_rect(outer, Color(wood, 0.85), false, 2.0)
	var middle_x := outer.position.x + outer.size.x * 0.5
	var middle_y := outer.position.y + outer.size.y * 0.5
	draw_line(Vector2(middle_x, outer.position.y), Vector2(middle_x, outer.end.y), Color(wood, 0.74), 4.0)
	draw_line(Vector2(outer.position.x, middle_y), Vector2(outer.end.x, middle_y), Color(wood, 0.74), 4.0)
	for index in 4:
		var pane := Rect2(
			outer.position + Vector2((index % 2) * outer.size.x * 0.5, (index / 2) * outer.size.y * 0.5),
			outer.size * 0.5
		).grow(-5.0)
		draw_rect(pane, Color(Color.WHITE, 0.09 if not dark else 0.035), true)

	# 斜射光束与地面。
	var shaft := PackedVector2Array([
		window_pos + Vector2(window_size.x * 0.42, window_size.y * 0.16),
		window_pos + Vector2(window_size.x * 1.10, window_size.y * 0.08),
		viewport_size * Vector2(0.69, FLOOR_START),
		viewport_size * Vector2(0.36, FLOOR_START),
	])
	draw_colored_polygon(shaft, Color(pane_top, 0.14 if not dark else 0.055))
	var floor_y := viewport_size.y * FLOOR_START
	draw_rect(Rect2(0.0, floor_y, viewport_size.x, viewport_size.y - floor_y), Color(wood, 0.07 if not dark else 0.14), true)
	draw_line(Vector2(0.0, floor_y), Vector2(viewport_size.x, floor_y), line, 1.0)

	# 前景枝叶：深度来自剪影和轻微视差，而不是贴图。
	_draw_leaf_cluster(Vector2(-24.0, viewport_size.y + 10.0) + _parallax, 1.0, leaf, dark)
	_draw_leaf_cluster(Vector2(viewport_size.x + 54.0, -4.0) + _parallax * 0.42, -0.78, leaf, dark)

	for particle in _particles:
		var alpha := float(particle.alpha) * (0.75 + sin(Time.get_ticks_msec() * 0.001 + float(particle.phase)) * 0.25)
		draw_circle(particle.position + _parallax * 0.12, float(particle.radius), Color(pane_top, alpha))


func _draw_leaf_cluster(origin: Vector2, direction: float, color: Color, dark: bool) -> void:
	for index in 11:
		var t := float(index) / 10.0
		var stem := origin + Vector2(direction * (30.0 + t * 170.0), -t * 128.0)
		var leaf_size := 16.0 + float(index % 3) * 5.0
		var points := PackedVector2Array([
			stem,
			stem + Vector2(direction * leaf_size, -leaf_size * 0.42),
			stem + Vector2(direction * leaf_size * 1.28, leaf_size * 0.24),
			stem + Vector2(direction * leaf_size * 0.22, leaf_size * 0.54),
			stem,
		])
		draw_colored_polygon(points, Color(color, 0.24 if not dark else 0.19))


func _initialize_particles() -> void:
	_particles.clear()
	var viewport_size := size.max(Vector2(1280.0, 720.0))
	for _index in PARTICLE_COUNT:
		_particles.append({
			"position": Vector2(
				_rng.randf_range(0.0, viewport_size.x),
				_rng.randf_range(0.0, viewport_size.y)
			),
			"speed": _rng.randf_range(4.0, 13.0),
			"radius": _rng.randf_range(0.7, 1.9),
			"alpha": _rng.randf_range(0.06, 0.20),
			"phase": _rng.randf_range(0.0, TAU),
		})
