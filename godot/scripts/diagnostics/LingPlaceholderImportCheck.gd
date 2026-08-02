extends SceneTree

const MODEL_PATH := "res://local_assets/ling_placeholder/ling_placeholder.glb"

var _failures: Array[String] = []


func _initialize() -> void:
	if not FileAccess.file_exists(MODEL_PATH):
		_fail("local placeholder GLB is missing")
		_finish({})
		return

	var resource := ResourceLoader.load(MODEL_PATH)
	_check(resource is PackedScene, "Godot did not import the GLB as PackedScene")
	if not resource is PackedScene:
		_finish({})
		return

	var instance := (resource as PackedScene).instantiate()
	root.add_child(instance)
	var meshes: Array[MeshInstance3D] = []
	var skeletons: Array[Skeleton3D] = []
	_collect_nodes(instance, meshes, skeletons)
	_check(meshes.size() == 1, "expected one MeshInstance3D")
	_check(skeletons.size() == 1, "expected one Skeleton3D")

	var report := {
		"resource_path": MODEL_PATH,
		"file_bytes": _file_length(MODEL_PATH),
		"mesh_instances": meshes.size(),
		"skeletons": skeletons.size(),
		"surfaces": 0,
		"vertices_after_primitive_split": 0,
		"triangles": 0,
		"materials": 0,
		"albedo_textures": 0,
		"bones": 0,
		"bounds": {},
	}

	if not skeletons.is_empty():
		report.bones = skeletons[0].get_bone_count()
		_check(report.bones >= 700, "armature lost most of its bones")

	var material_ids := {}
	var texture_ids := {}
	var combined_aabb := AABB()
	var has_aabb := false
	for mesh_instance in meshes:
		var mesh := mesh_instance.mesh
		_check(mesh != null, "MeshInstance3D has no mesh")
		if mesh == null:
			continue
		report.surfaces += mesh.get_surface_count()
		for surface_index in range(mesh.get_surface_count()):
			var arrays := mesh.surface_get_arrays(surface_index)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			report.vertices_after_primitive_split += vertices.size()
			report.triangles += indices.size() / 3 if not indices.is_empty() else vertices.size() / 3
			var material := mesh.surface_get_material(surface_index)
			if material != null:
				material_ids[material.get_instance_id()] = true
				if material is BaseMaterial3D and material.albedo_texture != null:
					texture_ids[material.albedo_texture.get_instance_id()] = true
		var mesh_aabb := _transform_aabb(mesh.get_aabb(), _relative_transform(mesh_instance, instance))
		if has_aabb:
			combined_aabb = combined_aabb.merge(mesh_aabb)
		else:
			combined_aabb = mesh_aabb
			has_aabb = true

	report.materials = material_ids.size()
	report.albedo_textures = texture_ids.size()
	_check(report.surfaces == 33, "expected 33 material surfaces")
	_check(report.triangles == 126960, "triangle count changed during Godot import")
	_check(report.materials == 33, "expected 33 imported materials")
	_check(report.albedo_textures >= 16, "base textures were not preserved")
	if has_aabb:
		report.bounds = {
			"min_xyz": _vector_to_array(combined_aabb.position),
			"max_xyz": _vector_to_array(combined_aabb.end),
			"extent_xyz": _vector_to_array(combined_aabb.size),
		}
		_check(absf(combined_aabb.size.y - 1.94108) < 0.03, "model height is not approximately 1.94 m")
		_check(combined_aabb.position.y > -0.03, "model feet are substantially below the origin")
	else:
		_fail("no mesh bounds were available")

	_finish(report)


func _collect_nodes(node: Node, meshes: Array[MeshInstance3D], skeletons: Array[Skeleton3D]) -> void:
	if node is MeshInstance3D:
		meshes.append(node)
	elif node is Skeleton3D:
		skeletons.append(node)
	for child in node.get_children():
		_collect_nodes(child, meshes, skeletons)


func _transform_aabb(box: AABB, transform: Transform3D) -> AABB:
	var first := transform * box.get_endpoint(0)
	var result := AABB(first, Vector3.ZERO)
	for endpoint_index in range(1, 8):
		result = result.expand(transform * box.get_endpoint(endpoint_index))
	return result


func _relative_transform(node: Node3D, ancestor: Node) -> Transform3D:
	var result := Transform3D.IDENTITY
	var current: Node = node
	while current != null and current != ancestor:
		if current is Node3D:
			result = (current as Node3D).transform * result
		current = current.get_parent()
	return result


func _file_length(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return -1
	return file.get_length()


func _vector_to_array(value: Vector3) -> Array[float]:
	return [value.x, value.y, value.z]


func _check(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failures.append(message)
	push_error("LING_PLACEHOLDER_CHECK: " + message)


func _finish(report: Dictionary) -> void:
	print("LING_PLACEHOLDER_GODOT_REPORT=" + JSON.stringify(report))
	if _failures.is_empty():
		print("LING_PLACEHOLDER_IMPORT_CHECK=PASS")
		quit(0)
	else:
		print("LING_PLACEHOLDER_IMPORT_CHECK=FAIL failures=%d" % _failures.size())
		quit(1)
