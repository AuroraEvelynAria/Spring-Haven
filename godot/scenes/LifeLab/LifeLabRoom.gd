extends Node3D

const STATION_POSITIONS := {
	"water": Vector3(-5.25, 0.04, -3.35),
	"food": Vector3(-2.35, 0.04, -3.65),
	"dining": Vector3(0.15, 0.04, -3.55),
	"rest": Vector3(4.75, 0.04, -2.75),
	"toilet": Vector3(5.45, 0.04, -0.35),
	"plant": Vector3(5.85, 0.04, 4.05),
	"dance": Vector3(-3.65, 0.04, 2.75),
	"social": Vector3(0.1, 0.04, 3.9),
}

const STATION_LABELS := {
	"water": "饮水台",
	"food": "料理台",
	"dining": "餐桌",
	"rest": "休息角",
	"toilet": "卫生间",
	"plant": "绿植角",
	"dance": "排练垫",
	"social": "聊天区",
}

var _materials: Dictionary = {}


func _ready() -> void:
	if has_node("Architecture"):
		return
	_create_materials()
	_build_floor_with_recovery_pit()
	_build_walls()
	_build_life_stations()
	_build_navigation_obstacles()


func get_station(station_id: String) -> Marker3D:
	return get_node_or_null("Stations/%s" % station_id) as Marker3D


func get_station_target(station_id: String, role: String) -> Vector3:
	var station := get_station(station_id)
	if not is_instance_valid(station):
		return Vector3.INF
	var offsets := {
		"rest": {"ling": Vector3(-0.7, 0, -0.1), "nai": Vector3(0.45, 0, 0.55)},
		"toilet": {"ling": Vector3(-0.65, 0, -0.6), "nai": Vector3(0.0, 0, 0.7)},
		"plant": {"ling": Vector3(-0.7, 0, -0.2), "nai": Vector3(0.45, 0, -0.65)},
	}
	var role_offsets: Dictionary = offsets.get(station_id, {
		"ling": Vector3(-0.65, 0, 0),
		"nai": Vector3(0.65, 0, 0),
	})
	return station.global_position + role_offsets.get(role, Vector3.ZERO)


func get_station_ids() -> Array[String]:
	var result: Array[String] = []
	for station_id in STATION_POSITIONS:
		result.append(str(station_id))
	return result


func _create_materials() -> void:
	_materials = {
		"floor": _material(Color("7f8785"), 0.92),
		"wall": _material(Color("edf0ec"), 0.96),
		"wood": _material(Color("a97553"), 0.76),
		"charcoal": _material(Color("44494e"), 0.64),
		"mint": _material(Color("6fae91"), 0.82),
		"coral": _material(Color("cf786d"), 0.86),
		"gold": _material(Color("d9b25f"), 0.68),
		"blue": _material(Color("668fb2"), 0.78),
		"pit": _material(Color("24272b"), 1.0),
	}


func _material(color: Color, roughness: float) -> StandardMaterial3D:
	var value := StandardMaterial3D.new()
	value.albedo_color = color
	value.roughness = roughness
	return value


func _build_floor_with_recovery_pit() -> void:
	var architecture := Node3D.new()
	architecture.name = "Architecture"
	add_child(architecture)
	# The four slabs leave a real 1.6 x 1.6 m hole at the east side.
	_add_box(architecture, "FloorWest", Vector3(11.0, 0.2, 10.0), Vector3(-1.5, -0.1, 0), _materials.floor)
	_add_box(architecture, "FloorEast", Vector3(1.4, 0.2, 10.0), Vector3(6.3, -0.1, 0), _materials.floor)
	_add_box(architecture, "FloorPitNorth", Vector3(1.6, 0.2, 7.0), Vector3(4.8, -0.1, -1.5), _materials.floor)
	_add_box(architecture, "FloorPitSouth", Vector3(1.6, 0.2, 1.4), Vector3(4.8, -0.1, 4.3), _materials.floor)
	_add_box_visual(architecture, "PitDepth", Vector3(1.5, 0.05, 1.5), Vector3(4.8, -2.7, 2.7), _materials.pit)
	var pit_label := Label3D.new()
	pit_label.name = "RecoveryPitLabel"
	pit_label.position = Vector3(4.8, 0.12, 1.75)
	pit_label.text = "跌落恢复区"
	pit_label.font_size = 22
	pit_label.outline_size = 5
	pit_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	pit_label.layers = 2
	architecture.add_child(pit_label)


func _build_walls() -> void:
	var architecture := get_node("Architecture") as Node3D
	_add_box(architecture, "NorthWall", Vector3(14.2, 1.4, 0.2), Vector3(0, 0.7, -5.1), _materials.wall)
	_add_box(architecture, "SouthWall", Vector3(14.2, 1.4, 0.2), Vector3(0, 0.7, 5.1), _materials.wall)
	_add_box(architecture, "WestWall", Vector3(0.2, 1.4, 10.0), Vector3(-7.1, 0.7, 0), _materials.wall)
	_add_box(architecture, "EastWall", Vector3(0.2, 1.4, 10.0), Vector3(7.1, 0.7, 0), _materials.wall)


func _build_life_stations() -> void:
	var stations := Node3D.new()
	stations.name = "Stations"
	add_child(stations)
	var colors := ["blue", "coral", "gold", "mint"]
	var index := 0
	for station_id_variant in STATION_POSITIONS:
		var station_id := str(station_id_variant)
		var marker := Marker3D.new()
		marker.name = station_id
		marker.position = STATION_POSITIONS[station_id]
		stations.add_child(marker)
		var disc := MeshInstance3D.new()
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = 0.34
		cylinder.bottom_radius = 0.34
		cylinder.height = 0.035
		cylinder.radial_segments = 24
		cylinder.material = _materials[colors[index % colors.size()]]
		disc.mesh = cylinder
		marker.add_child(disc)
		var label := Label3D.new()
		label.position = Vector3(0, 0.48, 0)
		label.text = str(STATION_LABELS[station_id])
		label.font_size = 20
		label.outline_size = 5
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.layers = 2
		marker.add_child(label)
		index += 1
	# Furniture sits beside its interaction marker, leaving a stable stopping area.
	_add_box(self, "WaterCounter", Vector3(1.25, 0.8, 0.55), Vector3(-5.25, 0.4, -4.25), _materials.blue)
	_add_box(self, "KitchenCounter", Vector3(2.0, 0.82, 0.6), Vector3(-2.35, 0.41, -4.25), _materials.wood)
	_add_box(self, "DiningTable", Vector3(1.5, 0.72, 0.9), Vector3(0.15, 0.36, -4.25), _materials.wood)
	_add_box(self, "Sofa", Vector3(2.2, 0.68, 0.8), Vector3(4.75, 0.34, -3.85), _materials.mint)
	_add_box(self, "BathroomDivider", Vector3(0.15, 1.2, 2.1), Vector3(6.1, 0.6, -0.35), _materials.wall)
	_add_box(self, "PlantPot", Vector3(0.55, 0.6, 0.55), Vector3(6.45, 0.3, 4.05), _materials.coral)
	_add_box_visual(self, "DanceMat", Vector3(2.2, 0.025, 1.45), Vector3(-3.65, 0.015, 2.75), _materials.coral)
	_add_box_visual(self, "SocialRug", Vector3(2.4, 0.025, 1.15), Vector3(0.1, 0.015, 3.9), _materials.mint)


func _build_navigation_obstacles() -> void:
	var obstacles := Node3D.new()
	obstacles.name = "ObstacleCourse"
	add_child(obstacles)
	_add_box(obstacles, "CentralIsland", Vector3(2.6, 0.85, 1.15), Vector3(-0.8, 0.425, 0.0), _materials.charcoal)
	_add_box(obstacles, "MazeA", Vector3(0.35, 0.75, 2.8), Vector3(1.65, 0.375, -0.25), _materials.blue)
	_add_box(obstacles, "MazeB", Vector3(2.4, 0.75, 0.35), Vector3(2.65, 0.375, 1.35), _materials.coral)
	_add_box(obstacles, "MazeC", Vector3(0.35, 0.75, 2.1), Vector3(-2.8, 0.375, 1.0), _materials.gold)
	var label := Label3D.new()
	label.position = Vector3(0.2, 1.15, 0.0)
	label.text = "绕障与窄通道"
	label.font_size = 24
	label.outline_size = 6
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.layers = 2
	obstacles.add_child(label)


func _add_box(parent: Node3D, node_name: String, size: Vector3, position: Vector3, material: Material) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	body.position = position
	body.collision_layer = 1
	body.collision_mask = 0
	parent.add_child(body)
	var shape_node := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	shape_node.shape = shape
	body.add_child(shape_node)
	var mesh_node := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = material
	mesh_node.mesh = mesh
	body.add_child(mesh_node)
	return body


func _add_box_visual(parent: Node3D, node_name: String, size: Vector3, position: Vector3, material: Material) -> MeshInstance3D:
	var mesh_node := MeshInstance3D.new()
	mesh_node.name = node_name
	mesh_node.position = position
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = material
	mesh_node.mesh = mesh
	parent.add_child(mesh_node)
	return mesh_node
