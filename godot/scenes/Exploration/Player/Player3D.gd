extends CharacterBody3D

signal mouse_capture_changed(captured: bool)

@export_category("Movement")
@export var input_enabled: bool = true
@export_range(0.1, 20.0, 0.1) var walk_speed: float = 4.2
@export_range(0.1, 30.0, 0.1) var sprint_speed: float = 7.0
@export_range(0.1, 80.0, 0.1) var ground_acceleration: float = 24.0
@export_range(0.1, 80.0, 0.1) var air_acceleration: float = 7.0
@export_range(0.1, 20.0, 0.1) var jump_velocity: float = 5.6
@export_range(0.1, 30.0, 0.1) var turn_speed: float = 12.0

@export_category("Camera")
@export var capture_mouse_on_ready: bool = true
@export_range(0.0005, 0.02, 0.0005) var mouse_sensitivity: float = 0.0025
@export_range(-89.0, -1.0, 1.0) var minimum_pitch_degrees: float = -65.0
@export_range(1.0, 89.0, 1.0) var maximum_pitch_degrees: float = 45.0

@export_category("Block Character Animation")
@export_range(0.0, 1.4, 0.05) var maximum_limb_swing: float = 0.7
@export_range(0.1, 5.0, 0.1) var stride_frequency: float = 2.25
@export_range(0.0, 0.15, 0.005) var body_bob_height: float = 0.025

@onready var _camera_rig: Node3D = $CameraRig
@onready var _pitch_pivot: Node3D = $CameraRig/Pitch
@onready var _spring_arm: SpringArm3D = $CameraRig/Pitch/SpringArm3D
@onready var _visual_root: Node3D = $VisualRoot
@onready var _left_arm: Node3D = $VisualRoot/LeftArm
@onready var _right_arm: Node3D = $VisualRoot/RightArm
@onready var _left_leg: Node3D = $VisualRoot/LeftLeg
@onready var _right_leg: Node3D = $VisualRoot/RightLeg

var _gravity: float = 9.8
var _camera_pitch: float = 0.0
var _jump_requested: bool = false
var _stride_phase: float = 0.0


func _ready() -> void:
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	_camera_pitch = _pitch_pivot.rotation.x
	_spring_arm.add_excluded_object(get_rid())
	set_mouse_captured(capture_mouse_on_ready)


func _exit_tree() -> void:
	# 鼠标捕获属于全局窗口状态，离开 3D 场景时必须归还给 2D UI。
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo:
			if _event_matches_key(key_event, KEY_ESCAPE):
				set_mouse_captured(Input.mouse_mode != Input.MOUSE_MODE_CAPTURED)
				return
			if (
				input_enabled
				and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
				and _event_matches_key(key_event, KEY_SPACE)
			):
				_jump_requested = true

	if not input_enabled:
		return

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var mouse_motion := event as InputEventMouseMotion
		_camera_rig.rotate_y(-mouse_motion.relative.x * mouse_sensitivity)
		_camera_pitch = clampf(
			_camera_pitch - mouse_motion.relative.y * mouse_sensitivity,
			deg_to_rad(minimum_pitch_degrees),
			deg_to_rad(maximum_pitch_degrees)
		)
		_pitch_pivot.rotation.x = _camera_pitch


func _physics_process(delta: float) -> void:
	var gameplay_input_active := input_enabled and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	var movement_input := _read_movement_input() if gameplay_input_active else Vector2.ZERO
	var movement_direction := _camera_relative_direction(movement_input)
	var is_sprinting := gameplay_input_active and Input.is_physical_key_pressed(KEY_SHIFT)
	var requested_speed := sprint_speed if is_sprinting else walk_speed
	var target_velocity := movement_direction * requested_speed
	var acceleration := ground_acceleration if is_on_floor() else air_acceleration

	velocity.x = move_toward(velocity.x, target_velocity.x, acceleration * delta)
	velocity.z = move_toward(velocity.z, target_velocity.z, acceleration * delta)

	var wants_to_jump := _jump_requested and gameplay_input_active
	_jump_requested = false
	if is_on_floor():
		if wants_to_jump:
			velocity.y = jump_velocity
		elif velocity.y < 0.0:
			velocity.y = 0.0
	else:
		velocity.y -= _gravity * delta

	if movement_direction.length_squared() > 0.001:
		var desired_yaw := atan2(-movement_direction.x, -movement_direction.z)
		_visual_root.rotation.y = lerp_angle(
			_visual_root.rotation.y,
			desired_yaw,
			minf(turn_speed * delta, 1.0)
		)

	move_and_slide()
	_animate_block_character(delta)


func set_input_enabled(enabled: bool) -> void:
	input_enabled = enabled
	if not enabled:
		_jump_requested = false


func set_mouse_captured(captured: bool) -> void:
	var requested_mode := Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE
	if Input.mouse_mode == requested_mode:
		return
	Input.mouse_mode = requested_mode
	mouse_capture_changed.emit(captured)


func is_mouse_captured() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func _read_movement_input() -> Vector2:
	var right_axis := (
		float(Input.is_physical_key_pressed(KEY_D))
		- float(Input.is_physical_key_pressed(KEY_A))
	)
	var forward_axis := (
		float(Input.is_physical_key_pressed(KEY_W))
		- float(Input.is_physical_key_pressed(KEY_S))
	)
	return Vector2(right_axis, forward_axis).limit_length(1.0)


func _camera_relative_direction(movement_input: Vector2) -> Vector3:
	if movement_input.is_zero_approx():
		return Vector3.ZERO

	var camera_basis := _camera_rig.global_transform.basis
	var camera_right := camera_basis.x
	var camera_forward := -camera_basis.z
	camera_right.y = 0.0
	camera_forward.y = 0.0
	camera_right = camera_right.normalized()
	camera_forward = camera_forward.normalized()
	return (camera_right * movement_input.x + camera_forward * movement_input.y).normalized()


func _animate_block_character(delta: float) -> void:
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	var animation_amount := clampf(horizontal_speed / maxf(walk_speed, 0.001), 0.0, 1.25)
	var swing_target := 0.0
	var bob_target := 0.0

	if is_on_floor() and horizontal_speed > 0.1:
		_stride_phase = fmod(_stride_phase + horizontal_speed * stride_frequency * delta, TAU)
		swing_target = sin(_stride_phase) * maximum_limb_swing * animation_amount
		bob_target = sin(_stride_phase * 2.0) * body_bob_height * animation_amount

	var animation_blend := minf(delta * 14.0, 1.0)
	_left_arm.rotation.x = lerp_angle(_left_arm.rotation.x, -swing_target, animation_blend)
	_right_arm.rotation.x = lerp_angle(_right_arm.rotation.x, swing_target, animation_blend)
	_left_leg.rotation.x = lerp_angle(_left_leg.rotation.x, swing_target, animation_blend)
	_right_leg.rotation.x = lerp_angle(_right_leg.rotation.x, -swing_target, animation_blend)
	_visual_root.position.y = lerpf(_visual_root.position.y, bob_target, animation_blend)


func _event_matches_key(event: InputEventKey, key: int) -> bool:
	return event.physical_keycode == key or event.keycode == key
