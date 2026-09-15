extends Control
## 背景特效专用子层（#11）：背景底色、柔光晕与飘浮粒子。
##
## 这些绘制原先是 GameWorld 自身 `_draw()` + `_process()` 的工作，导致整块 UI 根节点
## 每帧 `queue_redraw()`。迁到本层后，逐帧重绘成本被隔离在这个小子树内，
## GameWorld 不再逐帧重绘，界面刷新与背景动画解耦。
## 使用约束：必须挂为 GameWorld 的第一个子节点，才能保证绘制在所有 UI 之下。

const PARTICLE_COUNT := 54
const PARTICLE_SPEED_MIN := 4.0
const PARTICLE_SPEED_MAX := 14.0
const PARTICLE_RADIUS_MIN := 0.6
const PARTICLE_RADIUS_MAX := 1.7
const PARTICLE_ALPHA_MIN := 0.06
const PARTICLE_ALPHA_MAX := 0.24
const PARTICLE_WRAP_MARGIN := 6.0
const PARTICLE_X_MARGIN := 8.0
const PARTICLE_SWAY_SPEED := 0.00035
const PARTICLE_SWAY_AMOUNT := 2.0
const PARTICLE_PULSE_SPEED := 0.001
const PARTICLE_PULSE_FLOOR := 0.8
const PARTICLE_PULSE_DEPTH := 0.2
const HALO_CENTER_RATIO := Vector2(0.48, 0.52)
const HALO_RADIUS := 430.0
const HALO_ALPHA := 0.025

var _particles: Array[Dictionary] = []
var _rng := RandomNumberGenerator.new()
var _animating := true


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rng.randomize()
	_initialize_particles()
	set_process(_animating)


## 主题切换后重绘。配色在 `_draw()` 内实时取自 ThemeMgr，本层不缓存颜色。
func refresh_theme() -> void:
	queue_redraw()


## 逐帧动画开关。默认开启以维持粒子常动；置 false 后本层完全停止重绘，
## 是「空闲态零重绘」策略的接线点（#11 目标的后续开关）。
func set_animating(value: bool) -> void:
	if _animating == value:
		return
	_animating = value
	set_process(_animating)
	if _animating:
		queue_redraw()


func _process(delta: float) -> void:
	if _particles.is_empty():
		return
	var viewport_size := get_viewport_rect().size
	for particle in _particles:
		particle.position.y -= float(particle.speed) * delta
		particle.position.x += (
			sin(Time.get_ticks_msec() * PARTICLE_SWAY_SPEED + float(particle.phase))
			* delta
			* PARTICLE_SWAY_AMOUNT
		)
		if particle.position.y < -PARTICLE_WRAP_MARGIN:
			particle.position.y = viewport_size.y + PARTICLE_WRAP_MARGIN
			particle.position.x = _rng.randf_range(0.0, maxf(1.0, viewport_size.x))
		elif particle.position.x < -PARTICLE_X_MARGIN:
			particle.position.x = viewport_size.x + PARTICLE_X_MARGIN
		elif particle.position.x > viewport_size.x + PARTICLE_X_MARGIN:
			particle.position.x = -PARTICLE_X_MARGIN
	queue_redraw()


func _draw() -> void:
	var data := ThemeMgr.get_current_theme_data()
	var viewport_size := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, viewport_size), Color(data.bg))
	draw_circle(viewport_size * HALO_CENTER_RATIO, HALO_RADIUS, Color(data.primary, HALO_ALPHA))
	# 呼吸脉冲的时间基准只取一次，避免在粒子循环里重复调用 get_ticks_msec()。
	var pulse_ms := Time.get_ticks_msec() * PARTICLE_PULSE_SPEED
	for particle in _particles:
		var alpha: float = float(particle.alpha) * (
			PARTICLE_PULSE_FLOOR + sin(pulse_ms + float(particle.phase)) * PARTICLE_PULSE_DEPTH
		)
		draw_circle(particle.position, float(particle.radius), Color(data.primary, alpha))


func _initialize_particles() -> void:
	_particles.clear()
	var viewport_size := get_viewport_rect().size
	for _index in PARTICLE_COUNT:
		_particles.append({
			"position": Vector2(
				_rng.randf_range(0.0, maxf(1.0, viewport_size.x)),
				_rng.randf_range(0.0, maxf(1.0, viewport_size.y))
			),
			"speed": _rng.randf_range(PARTICLE_SPEED_MIN, PARTICLE_SPEED_MAX),
			"radius": _rng.randf_range(PARTICLE_RADIUS_MIN, PARTICLE_RADIUS_MAX),
			"alpha": _rng.randf_range(PARTICLE_ALPHA_MIN, PARTICLE_ALPHA_MAX),
			"phase": _rng.randf_range(0.0, TAU)
		})
