class_name LineIconButton
extends Button

## 无贴图的线性图标按钮。仍是原生 Button，保留键盘焦点、tooltip、disabled 与 pressed。
## 图形定义全在 LineIcon.gd(单一事实源);图标以子控件形式存在,按钮态换色
## 通过给 LineIcon 设 tint 实现(icon_only)或交给主题 secondary 色(组合模式)。

@export var icon_id := "":
	set(value):
		icon_id = value
		if is_instance_valid(_icon_control):
			_icon_control.set_icon(value)
@export var icon_size := 18.0:
	set(value):
		icon_size = value
		if is_instance_valid(_icon_control):
			_icon_control.icon_size = value
			_icon_control.custom_minimum_size = Vector2(value, value)
@export var icon_stroke := 1.7:
	set(value):
		icon_stroke = value
		if is_instance_valid(_icon_control):
			_icon_control.icon_stroke = value
@export var icon_only := true:
	set(value):
		icon_only = value
		_rebuild_layout()
@export var button_label := "":
	set(value):
		button_label = value
		if is_instance_valid(_label_control):
			_label_control.text = value

var _row: HBoxContainer
var _icon_control: LineIcon
var _label_control: Label


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_entered.connect(_refresh_state_color)
	mouse_exited.connect(_refresh_state_color)
	button_down.connect(_refresh_state_color)
	button_up.connect(_refresh_state_color)
	_rebuild_layout()


## 既有调用点(MemoryNetworkPanel 等)的兼容入口;等价于直接给 icon_id 赋值。
func set_icon(value: String) -> void:
	icon_id = value


## 图标永远以内嵌 LineIcon 子控件存在——同一颗按钮在纯图标/组合两种
## 形态间切换时只重排版,不重建绘制。
func _rebuild_layout() -> void:
	if not is_inside_tree():
		return
	if is_instance_valid(_row):
		_row.queue_free()
	_row = HBoxContainer.new()
	_row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_row.add_theme_constant_override("separation", 8)
	add_child(_row)
	_icon_control = LineIcon.new()
	_icon_control.icon_id = icon_id
	_icon_control.icon_size = icon_size
	_icon_control.icon_stroke = icon_stroke
	_icon_control.custom_minimum_size = Vector2(icon_size, icon_size)
	_row.add_child(_icon_control)
	_refresh_state_color()
	if icon_only:
		_icon_control.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		custom_minimum_size = Vector2(38, 38)
		return
	_label_control = Label.new()
	_label_control.text = button_label
	_label_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row.add_child(_label_control)


func _refresh_state_color() -> void:
	if not is_instance_valid(_icon_control):
		return
	var data := ThemeMgr.get_current_theme_data()
	var base := Color(str(data.get("secondary", "#A79B90")))
	if disabled:
		_icon_control.tint = Color(base, 0.38)
	elif is_pressed():
		_icon_control.tint = Color(str(data.get("accent", data.get("primary", "#C96B2E"))))
	elif is_hovered() or has_focus():
		_icon_control.tint = Color(str(data.get("primary", "#C96B2E")))
	else:
		_icon_control.tint = Color(base, 0.94)
