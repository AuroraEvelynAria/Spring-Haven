extends SceneTree

const MODEL_PATH := "res://local_assets/living_dining/living_dining_optimized.glb"
const RELEVANT_NAME_PARTS := [
	"room", "floor", "wall", "sofa", "table", "dinner", "chair", "kitchen", "island", "tv", "console"
]

var _failures: Array[String] = []


func _initialize() -> void:
	var packed := ResourceLoader.load(MODEL_PATH) as PackedScene
	_check(packed != null, "Godot did not import the room GLB as PackedScene")
	if packed == null:
		_finish({})
		return
	var instance := packed.instantiate()
	root.add_child(instance)
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(instance, meshes)
	var combined := AABB()
	var has_bounds := false
	var triangles := 0
	var gi_modes := {}
	var meshes_with_uv2 := 0
	var surfaces_with_uv2 := 0
	var lightmap_scales := {}
	var relevant: Array[Dictionary] = []
	for mesh_instance in meshes:
		if mesh_instance.mesh == null:
			continue
		var gi_mode_key := str(mesh_instance.gi_mode)
		gi_modes[gi_mode_key] = int(gi_modes.get(gi_mode_key, 0)) + 1
		var lightmap_scale_key := str(mesh_instance.get("gi_lightmap_scale"))
		lightmap_scales[lightmap_scale_key] = int(lightmap_scales.get(lightmap_scale_key, 0)) + 1
		var mesh_has_uv2 := false
		var transform := _relative_transform(mesh_instance, instance)
		var bounds := _transform_aabb(mesh_instance.mesh.get_aabb(), transform)
		combined = combined.merge(bounds) if has_bounds else bounds
		has_bounds = true
		for surface_index in mesh_instance.mesh.get_surface_count():
			var index_count: int = mesh_instance.mesh.surface_get_array_index_len(surface_index)
			var vertex_count: int = mesh_instance.mesh.surface_get_array_len(surface_index)
			var surface_format: int = mesh_instance.mesh.surface_get_format(surface_index)
			if (surface_format & Mesh.ARRAY_FORMAT_TEX_UV2) != 0:
				mesh_has_uv2 = true
				surfaces_with_uv2 += 1
			triangles += index_count / 3 if index_count > 0 else vertex_count / 3
		if mesh_has_uv2:
			meshes_with_uv2 += 1
		var lower_name := mesh_instance.name.to_lower()
		for name_part in RELEVANT_NAME_PARTS:
			if lower_name.contains(name_part):
				relevant.append({
					"name": mesh_instance.name,
					"path": str(instance.get_path_to(mesh_instance)),
					"center": _vec(bounds.get_center()),
					"min": _vec(bounds.position),
					"max": _vec(bounds.end),
					"size": _vec(bounds.size),
				})
				break
	_check(meshes.size() == 120, "expected 120 MeshInstance3D nodes")
	_check(triangles == 533732, "Lightmap UV2 import triangle count changed")
	_check(meshes_with_uv2 == 120, "not every room mesh has UV2 lightmap data")
	_check(surfaces_with_uv2 == 149, "room UV2 surface coverage changed")
	_check(int(gi_modes.get("1", 0)) == 120, "not every room mesh uses static GI mode")
	_check(has_bounds and combined.size.length_squared() > 0.0, "room bounds are empty")
	_finish({
		"resource_path": MODEL_PATH,
		"mesh_instances": meshes.size(),
		"triangles": triangles,
		"gi_modes": gi_modes,
		"meshes_with_uv2": meshes_with_uv2,
		"surfaces_with_uv2": surfaces_with_uv2,
		"lightmap_scales": lightmap_scales,
		"bounds": {
			"min": _vec(combined.position),
			"max": _vec(combined.end),
			"center": _vec(combined.get_center()),
			"size": _vec(combined.size),
		},
		"relevant_nodes": relevant,
	})


func _collect_meshes(node: Node, output: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		output.append(node)
	for child in node.get_children():
		_collect_meshes(child, output)


func _relative_transform(node: Node3D, ancestor: Node) -> Transform3D:
	var result := Transform3D.IDENTITY
	var current: Node = node
	while current != null and current != ancestor:
		if current is Node3D:
			result = (current as Node3D).transform * result
		current = current.get_parent()
	return result


func _transform_aabb(box: AABB, transform: Transform3D) -> AABB:
	var result := AABB(transform * box.get_endpoint(0), Vector3.ZERO)
	for endpoint_index in range(1, 8):
		result = result.expand(transform * box.get_endpoint(endpoint_index))
	return result


func _vec(value: Vector3) -> Array[float]:
	return [snappedf(value.x, 0.001), snappedf(value.y, 0.001), snappedf(value.z, 0.001)]


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish(report: Dictionary) -> void:
	print("LIVING_DINING_GODOT_REPORT=" + JSON.stringify(report))
	if _failures.is_empty():
		print("LIVING_DINING_IMPORT_CHECK=PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("LIVING_DINING_IMPORT_CHECK failure=", failure)
	quit(1)
