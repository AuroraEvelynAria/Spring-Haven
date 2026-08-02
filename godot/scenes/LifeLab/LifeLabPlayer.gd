extends CharacterBody3D

@export var move_speed := 4.2
@export var enabled := true

var last_safe_transform := Transform3D.IDENTITY


func _ready() -> void:
	last_safe_transform = global_transform
	_build_visual()


func _physics_process(delta: float) -> void:
	var input := Vector2.ZERO
	if enabled:
		input.x = float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A))
		input.y = float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W))
	var direction := Vector3(input.x, 0, input.y).normalized()
	velocity.x = move_toward(velocity.x, direction.x * move_speed, 14.0 * delta)
	velocity.z = move_toward(velocity.z, direction.z * move_speed, 14.0 * delta)
	velocity.y = 0.0 if is_on_floor() else velocity.y - 9.8 * delta
	move_and_slide()
	if is_on_floor():
		last_safe_transform = global_transform
	if global_position.y < -4.0:
		global_transform = last_safe_transform
		velocity = Vector3.ZERO


func _build_visual() -> void:
	var collision := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.24
	shape.height = 0.82
	collision.shape = shape
	collision.position.y = 0.41
	add_child(collision)
	var mesh_node := MeshInstance3D.new()
	mesh_node.position.y = 0.41
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.24
	mesh.height = 0.82
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("f2d16b")
	material.roughness = 0.72
	mesh.material = material
	mesh_node.mesh = mesh
	add_child(mesh_node)
	var label := Label3D.new()
	label.position.y = 1.1
	label.text = "主人位置"
	label.font_size = 22
	label.outline_size = 5
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.layers = 2
	add_child(label)
