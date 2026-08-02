extends Node3D

## 与正式客餐厅资产对齐的轻量碰撞代理。
## 正式 GLB 只负责显示；导航与物理由这些简单静态形状负责，避免把约 60 万面装饰网格送入物理服务器。

const NAVIGATION_COLLISION_LAYER := 1
const PERCEIVABLE_SCRIPT := preload("res://scenes/Exploration/Perception/Perceivable3D.gd")

var _materials: Dictionary = {}
var _visuals_visible := true


func _ready() -> void:
	if has_node("Architecture"):
		return
	_create_materials()
	_build_architecture()
	_build_kitchen_area()
	_build_living_area()
	_build_dining_area()
	_build_anchor_markers()


func set_visuals_visible(visible: bool) -> void:
	_visuals_visible = visible
	_set_geometry_visibility_recursive(self, visible)


func are_visuals_visible() -> bool:
	return _visuals_visible


func _set_geometry_visibility_recursive(node: Node, visible: bool) -> void:
	for child in node.get_children():
		if child is GeometryInstance3D:
			(child as GeometryInstance3D).visible = visible
		_set_geometry_visibility_recursive(child, visible)


func _create_materials() -> void:
	_materials = {
		"floor": _make_material(Color("b89b72"), 0.88),
		"wall": _make_material(Color("d9dde2"), 0.94),
		"wood": _make_material(Color("8b6244"), 0.78),
		"dark_wood": _make_material(Color("4b3b35"), 0.72),
		"sofa": _make_material(Color("a9b3bf"), 0.96),
		"sofa_accent": _make_material(Color("b98372"), 0.92),
		"rug": _make_material(Color("c4b8aa"), 1.0),
		"metal": _make_material(Color("373a3e"), 0.36, 0.32),
		"plant": _make_material(Color("61775e"), 0.95),
		"glass": _make_glass_material(),
		"anchor_dining": _make_material(Color("e5b85c"), 0.72, 0.08),
		"anchor_sofa": _make_material(Color("71b8a4"), 0.72, 0.08),
	}


func _make_material(color: Color, roughness: float, metallic: float = 0.0) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = metallic
	return material


func _make_glass_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.72, 0.88, 0.96, 0.24)
	material.roughness = 0.08
	material.metallic = 0.0
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


func _build_architecture() -> void:
	var architecture := Node3D.new()
	architecture.name = "Architecture"
	add_child(architecture)
	_add_box_body(
		architecture,
		"Floor",
		Vector3(7.558835, 0.10, 12.223166),
		Vector3(0.000001, -0.05, 0.0),
		_materials.floor
	)
	_add_box_body(
		architecture,
		"WestWall",
		Vector3(0.20, 2.818, 12.223166),
		Vector3(-3.679417, 1.409, 0.0),
		_materials.wall
	)
	_add_box_body(
		architecture,
		"EastWall",
		Vector3(0.20, 2.818, 12.223166),
		Vector3(3.779418, 1.409, 0.0),
		_materials.wall
	)
	_add_box_body(
		architecture,
		"NorthWall",
		Vector3(7.658835, 2.818, 0.20),
		Vector3(0.05, 1.409, -6.011583),
		_materials.wall
	)
	_add_box_body(
		architecture,
		"SouthWall",
		Vector3(7.658835, 2.818, 0.20),
		Vector3(0.05, 1.409, 6.011583),
		_materials.wall
	)
	_add_box_visual(
		architecture,
		"NorthSkirting",
		Vector3(7.45, 0.10, 0.05),
		Vector3(0.05, 0.05, -5.88),
		_materials.dark_wood
	)
	_add_box_visual(
		architecture,
		"SouthSkirting",
		Vector3(7.45, 0.10, 0.05),
		Vector3(0.05, 0.05, 5.88),
		_materials.dark_wood
	)


func _build_kitchen_area() -> void:
	var kitchen := Node3D.new()
	kitchen.name = "KitchenArea"
	add_child(kitchen)
	_add_box_body(
		kitchen,
		"BackCabinets",
		Vector3(0.62, 2.80, 5.043322),
		Vector3(-3.269417, 1.418, -1.189922),
		_materials.dark_wood
	)
	_add_box_body(
		kitchen,
		"Island",
		Vector3(2.154603, 1.420289, 3.608044),
		Vector3(-2.317527, 0.728145, -1.093831),
		_materials.wood
	)


func _build_living_area() -> void:
	var living := Node3D.new()
	living.name = "LivingArea"
	add_child(living)
	# L 形沙发拆成主座与贵妃位，避免整块 AABB 封死中间活动区。
	var sofa_main := _add_box_body(
		living,
		"SofaMain",
		Vector3(3.590808, 1.040414, 1.42),
		Vector3(1.429948, 0.539839, -0.259549),
		_materials.sofa
	)
	_add_perception(
		sofa_main, "sofa", "沙发", "客厅里的浅色布艺沙发，可以坐下或休息。", false,
		["observe", "sit", "rest"]
	)
	_add_box_body(
		living,
		"SofaChaise",
		Vector3(1.13, 0.72, 1.82),
		Vector3(2.660, 0.38, 1.215),
		_materials.sofa
	)
	_add_box_visual(
		living,
		"LivingRug",
		Vector3(3.50, 0.025, 2.7588),
		Vector3(0.986737, 0.014, 0.911079),
		_materials.rug
	)
	var coffee_table := _add_box_body(
		living,
		"CoffeeTable",
		Vector3(1.0, 0.22, 1.0),
		Vector3(0.833182, 0.128, 1.295128),
		_materials.wood
	)
	_add_perception(
		coffee_table, "coffee_table", "茶几", "沙发前的木质茶几。", false,
		["observe", "place_item"]
	)
	_add_box_body(
		living,
		"Sideboard",
		Vector3(3.50, 0.29, 0.420002),
		Vector3(0.986737, 0.268, 3.055378),
		_materials.dark_wood
	)
	_add_box_visual(
		living,
		"Television",
		Vector3(1.205674, 0.765755, 0.025),
		Vector3(0.874441, 1.530172, 3.032814),
		_materials.metal
	)


func _build_dining_area() -> void:
	var dining := Node3D.new()
	dining.name = "DiningArea"
	add_child(dining)
	var dining_table := _add_cylinder_body(
		dining,
		"DiningTable",
		0.705766,
		0.867582,
		Vector3(1.290139, 0.451791, -2.395984),
		_materials.wood
	)
	_add_perception(
		dining_table, "dining_table", "餐桌", "客餐厅里的圆形木餐桌，可以一起用餐。", false,
		["observe", "eat", "place_item"]
	)
	_add_box_body(
		dining,
		"ChairEast",
		Vector3(0.712646, 0.963305, 0.726748),
		Vector3(2.220696, 0.499653, -2.373196),
		_materials.sofa
	)
	_add_box_body(
		dining,
		"ChairWest",
		Vector3(0.883762, 0.963305, 0.895379),
		Vector3(0.285298, 0.499653, -2.486020),
		_materials.sofa
	)
	_add_box_body(
		dining,
		"ChairSouth",
		Vector3(0.726748, 0.963305, 0.712646),
		Vector3(1.336990, 0.499653, -3.262635),
		_materials.sofa
	)
	_add_box_body(
		dining,
		"ChairNorth",
		Vector3(0.915178, 0.963305, 0.904665),
		Vector3(1.325746, 0.499653, -1.460726),
		_materials.sofa
	)
	var plant_pot := _add_box_body(
		dining,
		"PlantPot",
		Vector3(0.76, 0.68, 0.76),
		Vector3(2.971570, 0.34, -3.240572),
		_materials.wood
	)
	_add_perception(
		plant_pot, "house_plant", "绿植", "小玲照料的室内绿植，叶片状态良好，盆土略干。", false,
		["observe", "photograph", "water"]
	)
	_add_box_visual(
		dining,
		"PlantLeaves",
		Vector3(1.02, 1.10, 1.01),
		Vector3(2.971570, 1.15, -3.240572),
		_materials.plant
	)
	var glass_cup := _add_cylinder_body(
		dining,
		"GlassCup",
		0.065,
		0.20,
		Vector3(1.290139, 0.98, -2.395984),
		_materials.glass
	)
	_add_perception(
		glass_cup, "glass_cup", "玻璃杯", "透明玻璃杯放在餐桌上。", true,
		["observe", "drink", "refill"],
		{"type": "饮用水", "fill_ratio": 0.62, "temperature": "常温"}
	)


func _build_anchor_markers() -> void:
	var dining_anchor := get_node_or_null("DiningSeatLing") as Node3D
	var sofa_anchor := get_node_or_null("SofaSpot") as Node3D
	if dining_anchor:
		_add_anchor_marker(dining_anchor, "DiningAnchorMarker", _materials.anchor_dining)
	if sofa_anchor:
		_add_anchor_marker(sofa_anchor, "SofaAnchorMarker", _materials.anchor_sofa)


func _add_anchor_marker(parent: Node3D, marker_name: String, material: Material) -> void:
	var marker := MeshInstance3D.new()
	marker.name = marker_name
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.20
	cylinder.bottom_radius = 0.20
	cylinder.height = 0.025
	cylinder.radial_segments = 24
	cylinder.material = material
	marker.mesh = cylinder
	marker.position.y = 0.014
	parent.add_child(marker)


func _add_box_body(
	parent: Node3D,
	body_name: String,
	size: Vector3,
	position_value: Vector3,
	material: Material
) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = body_name
	body.position = position_value
	body.collision_layer = NAVIGATION_COLLISION_LAYER
	body.collision_mask = 0
	parent.add_child(body)
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Visual"
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	box_mesh.material = material
	mesh_instance.mesh = box_mesh
	body.add_child(mesh_instance)
	var collision_shape := CollisionShape3D.new()
	collision_shape.name = "Collision"
	var box_shape := BoxShape3D.new()
	box_shape.size = size
	collision_shape.shape = box_shape
	body.add_child(collision_shape)
	return body


func _add_cylinder_body(
	parent: Node3D,
	body_name: String,
	radius: float,
	height: float,
	position_value: Vector3,
	material: Material
) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = body_name
	body.position = position_value
	body.collision_layer = NAVIGATION_COLLISION_LAYER
	body.collision_mask = 0
	parent.add_child(body)
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Visual"
	var cylinder_mesh := CylinderMesh.new()
	cylinder_mesh.top_radius = radius
	cylinder_mesh.bottom_radius = radius
	cylinder_mesh.height = height
	cylinder_mesh.radial_segments = 32
	cylinder_mesh.material = material
	mesh_instance.mesh = cylinder_mesh
	body.add_child(mesh_instance)
	var collision_shape := CollisionShape3D.new()
	collision_shape.name = "Collision"
	var cylinder_shape := CylinderShape3D.new()
	cylinder_shape.radius = radius
	cylinder_shape.height = height
	collision_shape.shape = cylinder_shape
	body.add_child(collision_shape)
	return body


func _add_box_visual(
	parent: Node3D,
	visual_name: String,
	size: Vector3,
	position_value: Vector3,
	material: Material
) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = visual_name
	mesh_instance.position = position_value
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	box_mesh.material = material
	mesh_instance.mesh = box_mesh
	parent.add_child(mesh_instance)
	return mesh_instance


func _add_perception(
	body: Node,
	entity_id: String,
	display_name: String,
	description: String,
	transparent: bool,
	actions: Array[String],
	contents: Dictionary = {}
) -> void:
	var perceivable := PERCEIVABLE_SCRIPT.new()
	perceivable.name = "Perceivable3D"
	perceivable.entity_id = entity_id
	perceivable.display_name = display_name
	perceivable.description = description
	perceivable.perception_transparent = transparent
	perceivable.available_actions = actions.duplicate()
	if not contents.is_empty():
		perceivable.content_type = str(contents.get("type", ""))
		perceivable.fill_ratio = clampf(float(contents.get("fill_ratio", 0.0)), 0.0, 1.0)
		perceivable.temperature = str(contents.get("temperature", "常温"))
	body.add_child(perceivable)
