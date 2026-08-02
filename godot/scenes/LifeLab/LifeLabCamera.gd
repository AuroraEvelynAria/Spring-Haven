extends Camera3D

@export var focus := Vector3.ZERO
@export_range(5.0, 24.0, 0.5) var distance := 11.0
@export_range(-80.0, -30.0, 1.0) var pitch_degrees := -60.0
@export var yaw_degrees := 0.0
@export var horizontal_composition_offset := -1.8

var _dragging_pan := false
var _dragging_rotate := false


func _ready() -> void:
	current = true
	h_offset = horizontal_composition_offset
	_update_camera()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			_dragging_pan = event.pressed
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_dragging_rotate = event.pressed
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = maxf(5.0, distance - 1.0)
			_update_camera()
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = minf(24.0, distance + 1.0)
			_update_camera()
	elif event is InputEventMouseMotion:
		if _dragging_pan:
			var right := global_transform.basis.x
			var forward := -global_transform.basis.z
			right.y = 0.0
			forward.y = 0.0
			focus += (-right.normalized() * event.relative.x + forward.normalized() * event.relative.y) * distance * 0.0018
			focus.x = clampf(focus.x, -6.0, 6.0)
			focus.z = clampf(focus.z, -4.0, 4.0)
			_update_camera()
		elif _dragging_rotate:
			yaw_degrees -= event.relative.x * 0.25
			pitch_degrees = clampf(pitch_degrees - event.relative.y * 0.18, -78.0, -35.0)
			_update_camera()


func _update_camera() -> void:
	var pitch := deg_to_rad(pitch_degrees)
	var yaw := deg_to_rad(yaw_degrees)
	var horizontal := cos(pitch) * distance
	position = focus + Vector3(sin(yaw) * horizontal, -sin(pitch) * distance, cos(yaw) * horizontal)
	look_at(focus, Vector3.UP)
