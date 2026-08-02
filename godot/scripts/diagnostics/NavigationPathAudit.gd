extends SceneTree

const EXPLORATION_SCENE := preload("res://scenes/Exploration/ExplorationWorld.tscn")
const POINTS := {
	"player_spawn": Vector3(-2.5, 0.0, 2.7),
	"ling_spawn": Vector3(-1.1, 0.0, 2.6),
	"dining": Vector3(-0.68, 0.0, -2.48),
	"sofa": Vector3(-0.85, 0.0, 1.3),
	"room_center": Vector3(0.0, 0.0, 0.0),
}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var world := EXPLORATION_SCENE.instantiate()
	world.call("set_global_state_node", null)
	root.add_child(world)
	for _frame in 900:
		if world.get("_navigation_ready") == true:
			break
		await physics_frame
	var region := world.get_node("NavigationRegion3D") as NavigationRegion3D
	var map := region.get_navigation_map()
	var navigation_mesh := region.navigation_mesh
	var report := {
		"points": {},
		"paths": {},
		"map_valid": map.is_valid(),
		"map_active": NavigationServer3D.map_is_active(map),
		"map_iteration": NavigationServer3D.map_get_iteration_id(map),
		"map_regions": NavigationServer3D.map_get_regions(map).size(),
		"nav_vertices": navigation_mesh.get_vertices().size() if navigation_mesh else -1,
	}
	for point_name in POINTS:
		var source: Vector3 = POINTS[point_name]
		var closest := NavigationServer3D.map_get_closest_point(map, source)
		report.points[point_name] = {
			"requested": _vec(source),
			"closest": _vec(closest),
			"offset": _planar_distance(source, closest),
		}
	for pair in [
		["ling_spawn", "dining"],
		["ling_spawn", "sofa"],
		["sofa", "dining"],
		["dining", "player_spawn"],
		["room_center", "dining"],
	]:
		var from_name: String = pair[0]
		var to_name: String = pair[1]
		var path := NavigationServer3D.map_get_path(
			map,
			POINTS[from_name],
			POINTS[to_name],
			true
		)
		var path_points: Array[Array] = []
		for point in path:
			path_points.append(_vec(point))
		report.paths["%s_to_%s" % [from_name, to_name]] = path_points
	print("NAVIGATION_PATH_AUDIT=" + JSON.stringify(report))
	world.queue_free()
	await process_frame
	quit(0)


func _vec(value: Vector3) -> Array[float]:
	return [snappedf(value.x, 0.001), snappedf(value.y, 0.001), snappedf(value.z, 0.001)]


func _planar_distance(from: Vector3, to: Vector3) -> float:
	var offset := to - from
	offset.y = 0.0
	return snappedf(offset.length(), 0.001)
