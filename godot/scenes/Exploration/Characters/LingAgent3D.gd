class_name LingAgent3D
extends CharacterBody3D

## 可复用于小玲、小奈的安全 3D 导航代理。
##
## 角色原点位于脚底；模型只是临时方块占位，实际移动与碰撞由
## CharacterBody3D、胶囊碰撞体和 NavigationAgent3D 负责。

signal action_state_changed(state: Dictionary)
signal destination_reached(label: String, position: Vector3)
signal movement_failed(reason: String)
signal local_visual_loaded(success: bool, resource_path: String)

const LOCAL_PLACEHOLDER_MODEL_PATH := (
	"res://local_assets/ling_placeholder/ling_placeholder.glb"
)
const LOCAL_PLACEHOLDER_VISUAL_SCALE := 1.0933333

enum ActionMode {
	IDLE,
	MOVE_TO,
	FOLLOW,
}

@export_category("移动")
@export var role_id := "ling"
@export var display_name := "小玲"
@export_range(0.1, 10.0, 0.1) var move_speed: float = 2.8
@export_range(0.1, 30.0, 0.1) var acceleration: float = 10.0
@export_range(0.1, 30.0, 0.1) var deceleration: float = 14.0
@export_range(0.1, 20.0, 0.1) var turn_speed: float = 8.0
@export_range(0.1, 3.0, 0.05) var stopping_distance: float = 0.45
@export_range(0.3, 6.0, 0.1) var follow_distance: float = 1.6
@export_range(0.1, 3.0, 0.05) var follow_repath_distance: float = 0.45
@export_range(0.05, 2.0, 0.05) var follow_repath_interval: float = 0.35
@export var enable_dynamic_avoidance := false
@export_range(0.0, 1.0, 0.05) var avoidance_priority := 0.5

@export_category("安全")
@export_range(0.1, 2.0, 0.05) var edge_probe_distance: float = 0.7
@export_range(0.2, 3.0, 0.05) var edge_probe_depth: float = 1.15
@export var recovery_y: float = -4.0
@export_range(0.5, 10.0, 0.1) var stuck_replan_after: float = 1.6
@export_range(0.01, 0.5, 0.01) var stuck_min_progress: float = 0.08
@export_range(0, 5, 1) var max_replans: int = 2
@export_range(0, 5, 1) var max_safe_recoveries: int = 2

@export_category("本地占位视觉")
@export var load_local_placeholder_model: bool = true
@export var load_local_placeholder_in_headless: bool = false
@export_file("*.glb", "*.gltf") var local_model_path := LOCAL_PLACEHOLDER_MODEL_PATH
@export var local_visual_scale := LOCAL_PLACEHOLDER_VISUAL_SCALE
@export var local_visual_offset := Vector3.ZERO
@export var local_visual_rotation_degrees := Vector3.ZERO

@export_category("角色体积")
@export_range(0.4, 2.4, 0.05) var body_height := 1.62
@export_range(0.15, 0.6, 0.01) var body_radius := 0.29
@export_range(0.5, 3.0, 0.05) var name_label_height := 1.9

@onready var navigation_agent: NavigationAgent3D = $NavigationAgent3D
@onready var visual_pivot: Node3D = $VisualPivot
@onready var ground_probe: RayCast3D = $GroundProbe
@onready var ahead_ground_probe: ShapeCast3D = $AheadGroundProbe
@onready var name_label: Label3D = $NameLabel

## 最近一次被确认“脚下和前方都有地面”的位置。外部只读使用。
var last_safe_transform: Transform3D = Transform3D.IDENTITY

var _mode: ActionMode = ActionMode.IDLE
var _status: String = "idle"
var _target_label: String = ""
var _command_target: Vector3 = Vector3.ZERO
var _follow_target: Node3D
var _navigation_ready: bool = false
var _gravity: float = 9.8

var _follow_repath_elapsed: float = 0.0
var _last_follow_position: Vector3 = Vector3.INF
var _edge_blocked_elapsed: float = 0.0
var _stuck_sample_elapsed: float = 0.0
var _stuck_elapsed: float = 0.0
var _last_progress_position: Vector3 = Vector3.ZERO
var _replan_count: int = 0
var _recovery_count: int = 0
var _local_visual_instance: Node3D
var _local_visual_loading := false
var _safe_horizontal_velocity := Vector3.ZERO
var _avoidance_velocity_ready := false
var _base_move_speed := 2.8


func _ready() -> void:
	_base_move_speed = move_speed
	Settings.runtime_tuning_changed.connect(_apply_runtime_tuning)
	_apply_runtime_tuning(Settings.get_runtime_tuning())
	_configure_character_shape()
	navigation_agent.avoidance_enabled = enable_dynamic_avoidance
	navigation_agent.avoidance_priority = avoidance_priority
	if enable_dynamic_avoidance and not navigation_agent.velocity_computed.is_connected(
		_on_avoidance_velocity_computed
	):
		navigation_agent.velocity_computed.connect(_on_avoidance_velocity_computed)
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	last_safe_transform = global_transform
	_last_progress_position = global_position
	ground_probe.target_position = Vector3(0.0, -edge_probe_depth, 0.0)
	ahead_ground_probe.target_position = Vector3(0.0, -edge_probe_depth, 0.0)
	call_deferred("_enable_navigation_after_map_sync")
	_begin_local_placeholder_load.call_deferred()
	_emit_action_state()

func _apply_runtime_tuning(config: Dictionary) -> void:
	move_speed = _base_move_speed * float(config.get("movement_speed_scale", 1.0))
	follow_distance = float(config.get("follow_distance_m", 1.6))
	max_replans = int(config.get("obstacle_retry_limit", 3))
	max_safe_recoveries = int(config.get("obstacle_retry_limit", 3))


func _physics_process(delta: float) -> void:
	_update_follow_target(delta)

	var has_motion_intent: bool = _has_motion_intent()
	var desired_direction: Vector3 = _get_navigation_direction()
	var edge_blocked: bool = false
	if desired_direction.length_squared() > 0.0001 and is_on_floor():
		edge_blocked = _would_step_into_drop(desired_direction)
		if edge_blocked:
			desired_direction = Vector3.ZERO
			_edge_blocked_elapsed += delta
			_set_status("edge_blocked")
		else:
			_edge_blocked_elapsed = 0.0
	else:
		_edge_blocked_elapsed = 0.0

	_apply_horizontal_velocity(desired_direction, delta)
	if enable_dynamic_avoidance:
		var requested_velocity := Vector3(velocity.x, 0.0, velocity.z)
		navigation_agent.velocity = requested_velocity
		if desired_direction.length_squared() <= 0.0001:
			_safe_horizontal_velocity = Vector3.ZERO
			_avoidance_velocity_ready = false
		elif _avoidance_velocity_ready:
			velocity.x = _safe_horizontal_velocity.x
			velocity.z = _safe_horizontal_velocity.z
	_apply_gravity(delta)
	_turn_visual_toward(desired_direction, delta)

	if global_position.y < recovery_y:
		_recover_or_fail("fell_below_limit")

	# 本脚本的唯一一次实际运动提交。所有状态只修改 velocity。
	move_and_slide()

	_update_last_safe_transform()
	_update_stuck_recovery(delta, has_motion_intent, edge_blocked)


## 命令小玲移动到世界坐标。label 会原样出现在状态字典和到达信号中。
func command_move_to(target: Vector3, label: String = "目标") -> void:
	_mode = ActionMode.MOVE_TO
	_follow_target = null
	_command_target = target
	_target_label = label.strip_edges() if not label.strip_edges().is_empty() else "目标"
	_begin_new_command()
	_set_navigation_target(_command_target)
	_set_status("navigating", true)


## 命令小玲持续跟随一个 Node3D；目标失效时会安全停止并报告失败。
func command_follow(target: Node3D) -> void:
	if not is_instance_valid(target):
		_fail_action("invalid_follow_target")
		return

	_mode = ActionMode.FOLLOW
	_follow_target = target
	_target_label = target.name
	_command_target = target.global_position
	_last_follow_position = _command_target
	_begin_new_command()
	_set_navigation_target(_command_target)
	_set_status("following", true)


## 立即取消当前移动意图。减速仍在物理帧内完成，不会额外调用 move_and_slide。
func command_stop() -> void:
	_mode = ActionMode.IDLE
	_follow_target = null
	_target_label = ""
	_command_target = global_position
	velocity.x = 0.0
	velocity.z = 0.0
	_reset_progress_tracking()
	_set_navigation_target(global_position)
	_set_status("stopped", true)


## 给 HUD、CompanionCore 动作执行器和诊断工具使用的稳定快照。
func get_action_state() -> Dictionary:
	var distance_remaining: float = 0.0
	if _mode != ActionMode.IDLE:
		distance_remaining = _planar_distance(global_position, _command_target)

	return {
		"mode": _mode_name(),
		"status": _status,
		"label": _target_label,
		"target_position": _command_target,
		"distance_remaining": distance_remaining,
		"has_follow_target": _mode == ActionMode.FOLLOW and is_instance_valid(_follow_target),
		"replan_count": _replan_count,
		"recovery_count": _recovery_count,
		"last_safe_position": last_safe_transform.origin,
	}


func is_local_visual_loaded() -> bool:
	return is_instance_valid(_local_visual_instance)


func get_local_visual_path() -> String:
	return local_model_path if is_local_visual_loaded() else ""


func set_local_visual(
	resource_path: String,
	visual_scale := 1.0,
	offset := Vector3.ZERO,
	rotation_degrees_value := Vector3.ZERO
) -> bool:
	var normalized_path := resource_path.strip_edges()
	if not normalized_path.begins_with("res://local_assets/"):
		return false
	if _local_visual_loading:
		return false
	if is_instance_valid(_local_visual_instance):
		_local_visual_instance.queue_free()
		_local_visual_instance = null
	local_model_path = normalized_path
	local_visual_scale = maxf(0.01, visual_scale)
	local_visual_offset = offset
	local_visual_rotation_degrees = rotation_degrees_value
	_set_fallback_visual_visible(true)
	_begin_local_placeholder_load.call_deferred()
	return true


func _begin_local_placeholder_load() -> void:
	if _local_visual_loading or is_local_visual_loaded() or not load_local_placeholder_model:
		return
	if DisplayServer.get_name() == "headless" and not load_local_placeholder_in_headless:
		return
	if (
		not FileAccess.file_exists(local_model_path)
		or not ResourceLoader.exists(local_model_path, "PackedScene")
	):
		return
	var requested_path := local_model_path
	_local_visual_loading = true
	var request_error := ResourceLoader.load_threaded_request(
		requested_path,
		"PackedScene",
		true
	)
	if request_error != OK:
		_local_visual_loading = false
		push_warning("小玲本地占位模型加载请求失败：%s" % error_string(request_error))
		local_visual_loaded.emit(false, requested_path)
		return

	var progress: Array = []
	while is_inside_tree():
		var status := ResourceLoader.load_threaded_get_status(
			requested_path,
			progress
		)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			break
		if status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			_local_visual_loading = false
			push_warning("小玲本地占位模型导入资源无效。")
			local_visual_loaded.emit(false, requested_path)
			return
		await get_tree().process_frame
	if not is_inside_tree():
		return

	var packed := ResourceLoader.load_threaded_get(requested_path) as PackedScene
	if packed == null:
		_local_visual_loading = false
		local_visual_loaded.emit(false, requested_path)
		return
	var instance := packed.instantiate()
	if not instance is Node3D:
		instance.queue_free()
		_local_visual_loading = false
		local_visual_loaded.emit(false, requested_path)
		return
	_local_visual_instance = instance as Node3D
	_local_visual_instance.name = (
		"LocalLingPlaceholder"
		if requested_path == LOCAL_PLACEHOLDER_MODEL_PATH
		else "LocalCharacterVisual"
	)
	_local_visual_instance.scale *= local_visual_scale
	_local_visual_instance.position = local_visual_offset
	_local_visual_instance.rotation_degrees = local_visual_rotation_degrees
	visual_pivot.add_child(_local_visual_instance)
	_set_fallback_visual_visible(false)
	_local_visual_loading = false
	local_visual_loaded.emit(true, requested_path)


func _configure_character_shape() -> void:
	role_id = role_id.strip_edges().left(32)
	display_name = display_name.strip_edges().left(32)
	if display_name.is_empty():
		display_name = "角色"
	if is_instance_valid(name_label):
		name_label.text = display_name
		name_label.position.y = name_label_height
	var collision_shape := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if collision_shape != null and collision_shape.shape is CapsuleShape3D:
		var capsule := (collision_shape.shape as CapsuleShape3D).duplicate() as CapsuleShape3D
		capsule.height = maxf(body_height, body_radius * 2.0)
		capsule.radius = body_radius
		collision_shape.shape = capsule
		collision_shape.position.y = body_height * 0.5
	if is_instance_valid(navigation_agent):
		navigation_agent.height = body_height
		navigation_agent.radius = body_radius + 0.02


func _on_avoidance_velocity_computed(safe_velocity: Vector3) -> void:
	_safe_horizontal_velocity = Vector3(safe_velocity.x, 0.0, safe_velocity.z)
	_avoidance_velocity_ready = true


func _set_fallback_visual_visible(visible: bool) -> void:
	for node_name in ["Torso", "Head", "LeftArm", "RightArm", "LeftLeg", "RightLeg"]:
		var fallback_node := visual_pivot.get_node_or_null(node_name) as Node3D
		if fallback_node != null:
			fallback_node.visible = visible


func _enable_navigation_after_map_sync() -> void:
	# NavigationServer 要到下一个物理帧才保证已同步烘焙地图。
	await get_tree().physics_frame
	if not is_inside_tree():
		return
	_navigation_ready = true
	if _mode != ActionMode.IDLE:
		_set_navigation_target(_command_target)


func _update_follow_target(delta: float) -> void:
	if _mode != ActionMode.FOLLOW:
		return
	if not is_instance_valid(_follow_target):
		_fail_action("follow_target_lost")
		return

	var follow_position: Vector3 = _follow_target.global_position
	var distance_to_target: float = _planar_distance(global_position, follow_position)
	_follow_repath_elapsed += delta

	if distance_to_target <= follow_distance:
		_command_target = follow_position
		_follow_repath_elapsed = 0.0
		_set_status("waiting_for_follow_target")
		return

	var target_moved: bool = _planar_distance(_last_follow_position, follow_position) >= follow_repath_distance
	if target_moved or _follow_repath_elapsed >= follow_repath_interval:
		_command_target = follow_position
		_last_follow_position = follow_position
		_follow_repath_elapsed = 0.0
		_set_navigation_target(_command_target)
		_set_status("following")


func _get_navigation_direction() -> Vector3:
	if not _navigation_ready or _mode == ActionMode.IDLE:
		return Vector3.ZERO

	var distance_to_target: float = _planar_distance(global_position, _command_target)
	var desired_stop_distance: float = follow_distance if _mode == ActionMode.FOLLOW else stopping_distance
	if distance_to_target <= desired_stop_distance:
		if _mode == ActionMode.MOVE_TO:
			_complete_move_command()
		return Vector3.ZERO

	if navigation_agent.is_navigation_finished():
		# “路径结束”不等于“已到目标”：地图尚未同步或目标不可达时也可能为空。
		_set_status("path_pending")
		return Vector3.ZERO

	var next_path_position: Vector3 = navigation_agent.get_next_path_position()
	var direction: Vector3 = next_path_position - global_position
	direction.y = 0.0
	if direction.length_squared() <= 0.0001:
		return Vector3.ZERO
	return direction.normalized()


func _has_motion_intent() -> bool:
	if _mode == ActionMode.IDLE:
		return false
	if _mode == ActionMode.FOLLOW and not is_instance_valid(_follow_target):
		return false
	var desired_stop_distance: float = follow_distance if _mode == ActionMode.FOLLOW else stopping_distance
	return _planar_distance(global_position, _command_target) > desired_stop_distance


func _apply_horizontal_velocity(direction: Vector3, delta: float) -> void:
	var target_velocity: Vector3 = direction * move_speed
	var rate: float = acceleration if direction.length_squared() > 0.0001 else deceleration
	velocity.x = move_toward(velocity.x, target_velocity.x, rate * delta)
	velocity.z = move_toward(velocity.z, target_velocity.z, rate * delta)


func _apply_gravity(delta: float) -> void:
	if is_on_floor():
		if velocity.y < 0.0:
			velocity.y = 0.0
	else:
		velocity.y -= _gravity * delta


func _turn_visual_toward(direction: Vector3, delta: float) -> void:
	if direction.length_squared() <= 0.0001:
		return
	# Godot 模型正面采用 -Z；只旋转视觉节点，不扰动导航与探针坐标系。
	var target_yaw: float = atan2(-direction.x, -direction.z)
	visual_pivot.rotation.y = lerp_angle(
		visual_pivot.rotation.y,
		target_yaw,
		clampf(turn_speed * delta, 0.0, 1.0)
	)


func _would_step_into_drop(direction: Vector3) -> bool:
	var local_ahead: Vector3 = to_local(global_position + direction.normalized() * edge_probe_distance)
	ahead_ground_probe.position = Vector3(local_ahead.x, 0.45, local_ahead.z)
	ahead_ground_probe.target_position = Vector3(0.0, -edge_probe_depth, 0.0)
	ahead_ground_probe.force_shapecast_update()
	return not ahead_ground_probe.is_colliding()


func _update_last_safe_transform() -> void:
	if not is_on_floor():
		return
	ground_probe.force_raycast_update()
	ahead_ground_probe.force_shapecast_update()
	if ground_probe.is_colliding() and ahead_ground_probe.is_colliding():
		last_safe_transform = global_transform


func _update_stuck_recovery(delta: float, has_motion_intent: bool, edge_blocked: bool) -> void:
	if not has_motion_intent or not is_on_floor():
		_reset_stuck_sample()
		return

	_stuck_sample_elapsed += delta
	if _stuck_sample_elapsed < 0.5:
		return

	var sample_duration: float = _stuck_sample_elapsed
	var progress: float = _planar_distance(global_position, _last_progress_position)
	_stuck_sample_elapsed = 0.0
	_last_progress_position = global_position

	if progress < stuck_min_progress:
		_stuck_elapsed += sample_duration
	else:
		_stuck_elapsed = 0.0
		if not edge_blocked:
			_set_status("following" if _mode == ActionMode.FOLLOW else "navigating")

	if _stuck_elapsed < stuck_replan_after:
		return

	_stuck_elapsed = 0.0
	if _replan_count < max_replans:
		_replan_count += 1
		_set_navigation_target(_command_target)
		_set_status("replanning", true)
		return

	_recover_or_fail("stuck_after_replans")


func _recover_or_fail(reason: String) -> void:
	# 即使恢复次数耗尽也先把实体放回安全点，绝不把失败角色留在虚空中。
	var can_retry_command: bool = _mode != ActionMode.IDLE and _recovery_count < max_safe_recoveries
	global_transform = last_safe_transform
	velocity = Vector3.ZERO
	_last_progress_position = global_position
	_stuck_sample_elapsed = 0.0
	_stuck_elapsed = 0.0
	_edge_blocked_elapsed = 0.0

	if can_retry_command:
		_recovery_count += 1
		_replan_count = 0
		_set_navigation_target(_command_target)
		_set_status("recovering_" + reason, true)
	else:
		_fail_action(reason)


func _complete_move_command() -> void:
	var completed_label: String = _target_label
	var completed_position: Vector3 = _command_target
	_mode = ActionMode.IDLE
	_follow_target = null
	velocity.x = 0.0
	velocity.z = 0.0
	_set_status("arrived", true)
	destination_reached.emit(completed_label, completed_position)


func _fail_action(reason: String) -> void:
	_mode = ActionMode.IDLE
	_follow_target = null
	velocity.x = 0.0
	velocity.z = 0.0
	_reset_progress_tracking()
	_set_navigation_target(global_position)
	_set_status("failed_" + reason, true)
	movement_failed.emit(reason)


func _begin_new_command() -> void:
	_follow_repath_elapsed = 0.0
	_edge_blocked_elapsed = 0.0
	_replan_count = 0
	_recovery_count = 0
	_reset_progress_tracking()


func _reset_progress_tracking() -> void:
	_stuck_sample_elapsed = 0.0
	_stuck_elapsed = 0.0
	_last_progress_position = global_position


func _reset_stuck_sample() -> void:
	_stuck_sample_elapsed = 0.0
	_stuck_elapsed = 0.0
	_last_progress_position = global_position


func _set_navigation_target(target: Vector3) -> void:
	if not is_node_ready():
		return
	navigation_agent.target_position = target


func _set_status(new_status: String, force_emit: bool = false) -> void:
	if not force_emit and _status == new_status:
		return
	_status = new_status
	_emit_action_state()


func _emit_action_state() -> void:
	action_state_changed.emit(get_action_state())


func _mode_name() -> String:
	match _mode:
		ActionMode.MOVE_TO:
			return "move_to"
		ActionMode.FOLLOW:
			return "follow"
		_:
			return "idle"


func _planar_distance(from: Vector3, to: Vector3) -> float:
	var offset: Vector3 = to - from
	offset.y = 0.0
	return offset.length()
