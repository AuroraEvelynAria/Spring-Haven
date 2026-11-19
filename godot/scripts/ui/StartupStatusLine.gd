class_name StartupStatusLine
extends Control

## 主菜单左下角的启动状态行:把 CompanionCore 的启动过程从"静默黑箱"
## 变成一眼可见的三态指示(准备运行时 → 启动中 → 已连接/未启动)。
## 纯消费方——CompanionCoreClient 的信号与查询接口零改动。

enum State { PREPARING, CONNECTING, CONNECTED, FAILED }

const POLL_INTERVAL_SECONDS := 1.0
const DOT_BASE_ALPHA := 0.9
const DOT_BREATH_ALPHA := 0.35
const DOT_BREATH_SECONDS := 1.1

signal detail_requested

var _state: State = State.PREPARING
var _row: HBoxContainer
var _dot: ColorRect
var _label: Label
var _detail_button: Button
var _pulse_elapsed := 0.0
var _poll_elapsed := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	CompanionCore.health_changed.connect(_on_health_changed)
	CompanionCore.connected.connect(
		func() -> void: _apply_state(State.CONNECTED, "已连接 Companion Core")
	)
	CompanionCore.disconnected.connect(
		func() -> void: _apply_state(State.FAILED, "Companion Core 未连接")
	)
	_apply_state(State.PREPARING, "正在准备本地运行环境…")
	set_process(true)


func _process(delta: float) -> void:
	# 未就绪时圆点呼吸;就绪/失败后停表省电
	if _state == State.PREPARING or _state == State.CONNECTING:
		_pulse_elapsed = fmod(_pulse_elapsed + delta, DOT_BREATH_SECONDS)
		var phase := absf(_pulse_elapsed / DOT_BREATH_SECONDS * 2.0 - 1.0)
		_dot.modulate.a = lerpf(DOT_BREATH_ALPHA, DOT_BASE_ALPHA, 1.0 - phase)
		_poll_elapsed += delta
		if _poll_elapsed >= POLL_INTERVAL_SECONDS:
			_poll_elapsed = 0.0
			_refresh_from_status()
	elif _dot.modulate.a != DOT_BASE_ALPHA:
		_dot.modulate.a = DOT_BASE_ALPHA


func _build() -> void:
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 6)
	_row.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_row.offset_left = 18.0
	_row.offset_bottom = -18.0
	_row.offset_top = -42.0
	_row.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_row)
	_dot = ColorRect.new()
	_dot.custom_minimum_size = Vector2(8, 8)
	# HBox 子项默认垂直拉伸,8x8 会被拉成竖条;收成居中收缩才是圆点。
	_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row.add_child(_dot)
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 12)
	_row.add_child(_label)
	# 失败态才出现的小按钮:由宿主(MainMenu)接去弹错误详情对话框
	_detail_button = Button.new()
	_detail_button.text = "详情"
	_detail_button.flat = true
	_detail_button.add_theme_font_size_override("font_size", 12)
	_detail_button.visible = false
	_detail_button.pressed.connect(func() -> void: detail_requested.emit())
	_row.add_child(_detail_button)


func _on_health_changed(_active: bool, message: String) -> void:
	if _active:
		_apply_state(State.CONNECTED, "已连接 Companion Core")
		return
	# 启动期的消息分两类:"正在启动/重新连接"是过程,其余是可重试的失败。
	if message.contains("正在启动") or message.contains("重新连接"):
		_apply_state(State.CONNECTING, message)
	elif message.is_empty():
		_apply_state(State.CONNECTING, "正在连接 Companion Core…")
	else:
		_apply_state(State.FAILED, "Companion Core 未连接")


func _refresh_from_status() -> void:
	# 细粒度补充:managed 状态能分辨"模板复制中"与"进程已拉起"
	if CompanionCore.is_active():
		_apply_state(State.CONNECTED, "已连接 Companion Core")
		return
	var managed: Dictionary = CompanionCore.get_managed_core_status()
	if bool(managed.get("running", false)):
		_apply_state(State.CONNECTING, "正在启动对话核心…")
	elif _state != State.FAILED:
		_apply_state(State.PREPARING, "正在准备本地运行环境…")


func _apply_state(state: State, message: String) -> void:
	if state == _state and message == _label.text:
		return
	_state = state
	_label.text = message
	match state:
		State.PREPARING, State.CONNECTING:
			_dot.color = ThemeMgr.semantic("info")
			_label.add_theme_color_override(
				"font_color", Color(ThemeMgr.get_current_theme_data().secondary, 0.9)
			)
		State.CONNECTED:
			_dot.color = ThemeMgr.semantic("success")
			_label.add_theme_color_override("font_color", ThemeMgr.semantic("success"))
		State.FAILED:
			_dot.color = ThemeMgr.semantic("danger")
			_label.add_theme_color_override("font_color", ThemeMgr.semantic("danger"))
	_detail_button.visible = state == State.FAILED
