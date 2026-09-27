extends Node3D

## 轻奢原木风客餐厅 —— 程序化精修版(探索阶段②场景重建)。
## 比例基准:真实厘米级 —— 层高 2.818m,角色胶囊 1.66m,
## 座高 0.42~0.45m,餐桌 0.75m,岛台 0.88m,门/背板 ≤2.4m。
## 家具用多几何体拼装(无贴图):坐垫/扶手/桌腿/台面/灯具/窗框独立建模。
## 感知物件(Perceivable3D)挂隐形全高碰撞体:准星任意高度可命中。
## 正式 GLB 若存在只负责显示;导航与物理由静态形状负责。

const NAVIGATION_COLLISION_LAYER := 1
const PERCEIVABLE_SCRIPT := preload("res://scenes/Exploration/Perception/Perceivable3D.gd")

const ROOM_HALF_X := 3.679418
const ROOM_HALF_Z := 6.011583
const WALL_HEIGHT := 2.818

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
		"ceiling": _make_material(Color("efeae2"), 0.95),
		"wood": _make_material(Color("8b6244"), 0.78),
		"wood_light": _make_material(Color("c9a878"), 0.82),
		"dark_wood": _make_material(Color("4b3b35"), 0.72),
		"frame_wood": _make_material(Color("5c4632"), 0.70),
		"countertop": _make_material(Color("e8e2d6"), 0.42),
		"sofa": _make_material(Color("a9b3bf"), 0.96),
		"sofa_cushion": _make_material(Color("c3cbd4"), 0.97),
		"sofa_accent": _make_material(Color("b98372"), 0.92),
		"rug": _make_material(Color("c4b8aa"), 1.0),
		"metal": _make_material(Color("373a3e"), 0.36, 0.32),
		"brass": _make_material(Color("b08d57"), 0.35, 0.65),
		"plant": _make_material(Color("61775e"), 0.95),
		"plant_dark": _make_material(Color("4e6b4a"), 0.95),
		"trunk": _make_material(Color("6b4f3a"), 0.85),
		"soil": _make_material(Color("4a3a2c"), 0.98),
		"ceramic": _make_material(Color("eadfd3"), 0.55),
		"screen": _make_material(Color("1a1c20"), 0.28, 0.15),
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
	_add_box_visual(
		architecture,
		"Ceiling",
		Vector3(7.558835, 0.08, 12.223166),
		Vector3(0.0, WALL_HEIGHT + 0.04, 0.0),
		_materials.ceiling
	)
	_add_box_body(
		architecture,
		"WestWall",
		Vector3(0.20, WALL_HEIGHT, 12.223166),
		Vector3(-ROOM_HALF_X, WALL_HEIGHT * 0.5, 0.0),
		_materials.wall
	)
	_add_box_body(
		architecture,
		"EastWall",
		Vector3(0.20, WALL_HEIGHT, 12.223166),
		Vector3(ROOM_HALF_X + 0.1, WALL_HEIGHT * 0.5, 0.0),
		_materials.wall
	)
	_add_box_body(
		architecture,
		"NorthWall",
		Vector3(7.658835, WALL_HEIGHT, 0.20),
		Vector3(0.05, WALL_HEIGHT * 0.5, -ROOM_HALF_Z),
		_materials.wall
	)
	_add_box_body(
		architecture,
		"SouthWall",
		Vector3(7.658835, WALL_HEIGHT, 0.20),
		Vector3(0.05, WALL_HEIGHT * 0.5, ROOM_HALF_Z),
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
	_build_window(architecture)
	_build_wall_art(architecture)


## 东墙窗户:木框 + 双层玻璃 + 十字棂 + 窗台(装饰,无碰撞)
func _build_window(parent: Node3D) -> void:
	var window := Node3D.new()
	window.name = "Window"
	add_child(window)
	var inner_x := ROOM_HALF_X - 0.005
	var center_z := 0.6
	var center_y := 1.70
	var width := 1.50
	var height := 1.30
	var frame_t := 0.07
	var depth := 0.12
	# 上下框
	_add_box_visual(window, "WindowFrameTop", Vector3(depth, frame_t, width),
		Vector3(inner_x, center_y + height * 0.5 - frame_t * 0.5, center_z), _materials.frame_wood)
	_add_box_visual(window, "WindowFrameBottom", Vector3(depth, frame_t, width),
		Vector3(inner_x, center_y - height * 0.5 + frame_t * 0.5, center_z), _materials.frame_wood)
	# 左右框
	_add_box_visual(window, "WindowFrameLeft", Vector3(depth, height, frame_t),
		Vector3(inner_x, center_y, center_z - width * 0.5 + frame_t * 0.5), _materials.frame_wood)
	_add_box_visual(window, "WindowFrameRight", Vector3(depth, height, frame_t),
		Vector3(inner_x, center_y, center_z + width * 0.5 - frame_t * 0.5), _materials.frame_wood)
	# 十字棂
	_add_box_visual(window, "WindowMullionH", Vector3(depth * 0.6, 0.04, width - frame_t * 2.0),
		Vector3(inner_x, center_y, center_z), _materials.frame_wood)
	_add_box_visual(window, "WindowMullionV", Vector3(depth * 0.6, height - frame_t * 2.0, 0.04),
		Vector3(inner_x, center_y, center_z), _materials.frame_wood)
	# 玻璃
	_add_box_visual(window, "WindowGlass", Vector3(0.02, height - frame_t, width - frame_t),
		Vector3(inner_x - 0.02, center_y, center_z), _materials.glass)
	# 窗台
	_add_box_visual(window, "WindowSill", Vector3(0.22, 0.035, width + 0.12),
		Vector3(inner_x - 0.08, center_y - height * 0.5 - 0.02, center_z), _materials.wood_light)


## 北墙装饰画:画框 + 内衬画布
func _build_wall_art(parent: Node3D) -> void:
	var art := Node3D.new()
	art.name = "WallArt"
	add_child(art)
	var wall_z := -ROOM_HALF_Z + 0.115
	_add_box_visual(art, "ArtFrame", Vector3(0.94, 0.64, 0.035),
		Vector3(-0.6, 1.52, wall_z), _materials.frame_wood)
	_add_box_visual(art, "ArtCanvas", Vector3(0.82, 0.52, 0.02),
		Vector3(-0.6, 1.52, wall_z - 0.012), _materials.ceramic)


func _build_kitchen_area() -> void:
	var kitchen := Node3D.new()
	kitchen.name = "KitchenArea"
	add_child(kitchen)
	# 靠墙整体柜(保持原碰撞体)
	_add_box_body(
		kitchen,
		"BackCabinets",
		Vector3(0.62, 2.80, 5.043322),
		Vector3(-3.269417, 1.418, -1.189922),
		_materials.dark_wood
	)
	# 台面(石感浅色)
	_add_box_visual(kitchen, "BackCountertop", Vector3(0.70, 0.04, 5.04),
		Vector3(-2.93, 0.92, -1.19), _materials.countertop)
	# 吊柜(装饰)
	_add_box_visual(kitchen, "UpperCabinets", Vector3(0.35, 0.80, 4.60),
		Vector3(-3.44, 1.95, -1.19), _materials.wood_light)
	for index in 4:
		_add_box_visual(
			kitchen,
			"CabinetHandle%d" % index,
			Vector3(0.025, 0.025, 0.30),
			Vector3(-2.95, 0.80, -3.1 + float(index) * 1.15),
			_materials.brass
		)
	# 水龙头(竖管 + 弯臂)
	_add_cylinder_visual(kitchen, "FaucetBase", 0.028, 0.06, Vector3(-2.93, 0.97, -2.2), _materials.brass)
	_add_cylinder_visual(kitchen, "FaucetColumn", 0.02, 0.26, Vector3(-2.93, 1.10, -2.2), _materials.brass)
	_add_box_visual(kitchen, "FaucetArm", Vector3(0.025, 0.025, 0.24),
		Vector3(-2.93, 1.23, -2.09), _materials.brass)
	# 岛台:缩到真实尺寸(2.4×0.9,台面高 0.88),台面出沿
	_add_box_body(
		kitchen,
		"Island",
		Vector3(2.40, 0.84, 0.90),
		Vector3(-2.32, 0.42, -1.09),
		_materials.wood
	)
	_add_box_visual(kitchen, "IslandCountertop", Vector3(2.52, 0.045, 1.00),
		Vector3(-2.32, 0.865, -1.09), _materials.countertop)
	_add_box_visual(kitchen, "IslandHandleA", Vector3(0.9, 0.02, 0.02),
		Vector3(-2.32, 0.76, -0.635), _materials.brass)
	# 吧凳 ×2(凳腿 + 软垫)
	for stool_index in 2:
		var stool_z := -1.45 + float(stool_index) * 0.62
		_add_cylinder_visual(kitchen, "StoolLegs%d" % stool_index, 0.15, 0.44,
			Vector3(-1.02, 0.22, stool_z), _materials.dark_wood)
		_add_cylinder_visual(kitchen, "StoolCushion%d" % stool_index, 0.17, 0.07,
			Vector3(-1.02, 0.475, stool_z), _materials.sofa_accent)


func _build_living_area() -> void:
	var living := Node3D.new()
	living.name = "LivingArea"
	add_child(living)
	# L 形布艺沙发:隐形全高碰撞 + 坐垫/靠垫/扶手/沙发腿拼装
	# (主座 2.3m,座高 0.42,靠背顶 0.88;面向 +z 的电视)
	var sofa_body := _add_invisible_body(
		living, "SofaMain", Vector3(2.30, 0.85, 0.95), Vector3(1.43, 0.425, -0.26)
	)
	_add_box_visual(sofa_body, "SofaBase", Vector3(2.30, 0.30, 0.95),
		Vector3(0.0, -0.275, 0.0), _materials.sofa)
	for seat_index in 2:
		_add_box_visual(sofa_body, "SofaSeatCushion%d" % seat_index, Vector3(1.06, 0.16, 0.80),
			Vector3(-0.55 + float(seat_index) * 1.10, 0.075, 0.045), _materials.sofa_cushion)
	_add_box_visual(sofa_body, "SofaBackPanel", Vector3(2.30, 0.46, 0.20),
		Vector3(0.0, 0.225, -0.375), _materials.sofa)
	for back_index in 2:
		_add_box_visual(sofa_body, "SofaBackCushion%d" % back_index, Vector3(1.04, 0.38, 0.14),
			Vector3(-0.55 + float(back_index) * 1.10, 0.205, -0.305), _materials.sofa_cushion)
	for arm_index in 2:
		_add_box_visual(sofa_body, "SofaArmrest%d" % arm_index, Vector3(0.24, 0.56, 0.95),
			Vector3(-1.27 + float(arm_index) * 2.54, -0.025, 0.0), _materials.sofa)
	for leg_index in 4:
		_add_box_visual(sofa_body, "SofaLeg%d" % leg_index, Vector3(0.06, 0.12, 0.06),
			Vector3(-1.05 + float(leg_index % 2) * 2.10, -0.365, -0.35 + float(int(leg_index / 2.0)) * 0.70),
			_materials.frame_wood)
	_add_perception(
		sofa_body, "sofa", "沙发", "客厅里的浅色布艺沙发，可以坐下或休息。", false,
		["observe", "sit", "rest"]
	)
	# 贵妃位(隐形碰撞 + 坐垫)
	var chaise_body := _add_invisible_body(
		living, "SofaChaise", Vector3(0.85, 0.72, 1.80), Vector3(2.66, 0.36, 1.215)
	)
	_add_box_visual(chaise_body, "ChaiseBase", Vector3(0.85, 0.30, 1.80),
		Vector3(0.0, -0.275, 0.0), _materials.sofa)
	_add_box_visual(chaise_body, "ChaiseCushion", Vector3(0.78, 0.16, 1.72),
		Vector3(0.0, 0.075, 0.0), _materials.sofa_cushion)
	_add_box_visual(chaise_body, "ChaiseArm", Vector3(0.85, 0.30, 0.22),
		Vector3(0.0, 0.16, -0.79), _materials.sofa)
	# 地毯(保持原位)
	_add_box_visual(
		living,
		"LivingRug",
		Vector3(3.50, 0.025, 2.7588),
		Vector3(0.986737, 0.014, 0.911079),
		_materials.rug
	)
	# 茶几:桌面 0.45 高 + 四腿 + 置物层(隐形全高碰撞供准星命中)
	var table_body := _add_invisible_body(
		living, "CoffeeTable", Vector3(1.10, 0.45, 0.60), Vector3(0.833182, 0.225, 1.295128)
	)
	_add_box_visual(table_body, "CoffeeTableTop", Vector3(1.10, 0.05, 0.60),
		Vector3(0.0, 0.20, 0.0), _materials.wood)
	for leg_index in 4:
		_add_box_visual(table_body, "CoffeeTableLeg%d" % leg_index, Vector3(0.05, 0.40, 0.05),
			Vector3(-0.49 + float(leg_index % 2) * 0.98, -0.025, -0.24 + float(int(leg_index / 2.0)) * 0.48),
			_materials.frame_wood)
	_add_box_visual(table_body, "CoffeeTableShelf", Vector3(1.00, 0.03, 0.50),
		Vector3(0.0, -0.145, 0.0), _materials.wood_light)
	# 桌面小物:书 + 陶碗
	_add_box_visual(table_body, "CoffeeBook", Vector3(0.22, 0.035, 0.16),
		Vector3(-0.24, 0.243, 0.06), _materials.sofa_accent)
	_add_cylinder_visual(table_body, "CoffeeBowl", 0.09, 0.07,
		Vector3(0.22, 0.26, -0.05), _materials.ceramic)
	_add_perception(
		table_body, "coffee_table", "茶几", "沙发前的原木茶几，桌上有书和陶碗。", false,
		["observe", "place_item"]
	)
	# 电视柜:柜体 + 两门 + 把手 + 四短腿
	_add_box_body(
		living,
		"Sideboard",
		Vector3(2.00, 0.50, 0.40),
		Vector3(0.986737, 0.50, 3.055378),
		_materials.dark_wood
	)
	_add_box_visual(living, "SideboardDoorLeft", Vector3(0.94, 0.42, 0.02),
		Vector3(0.50, 0.50, 2.845), _materials.wood_light)
	_add_box_visual(living, "SideboardDoorRight", Vector3(0.94, 0.42, 0.02),
		Vector3(1.47, 0.50, 2.845), _materials.wood_light)
	_add_box_visual(living, "SideboardHandleLeft", Vector3(0.02, 0.24, 0.02),
		Vector3(0.99, 0.50, 2.83), _materials.brass)
	_add_box_visual(living, "SideboardHandleRight", Vector3(0.02, 0.24, 0.02),
		Vector3(0.98, 0.50, 2.83), _materials.brass)
	# 电视:面板 + 屏幕内衬 + 底座
	_add_box_visual(
		living,
		"Television",
		Vector3(1.205674, 0.765755, 0.045),
		Vector3(0.874441, 1.530172, 3.032814),
		_materials.screen
	)
	_add_box_visual(living, "TelevisionStand", Vector3(0.30, 0.05, 0.20),
		Vector3(0.874441, 1.115, 3.032814), _materials.metal)
	# 电视柜上的陶瓶
	_add_cylinder_visual(living, "SideboardVase", 0.06, 0.24,
		Vector3(1.70, 0.875, 3.055), _materials.ceramic)


func _build_dining_area() -> void:
	var dining := Node3D.new()
	dining.name = "DiningArea"
	add_child(dining)
	var table_center := Vector3(1.290139, 0.0, -2.395984)
	# 圆餐桌:桌面板 0.75 高 + 中柱 + 底盘(隐形全高碰撞供准星命中)
	var dining_body := _add_invisible_body(
		dining, "DiningTable", Vector3(1.40, 0.78, 1.40),
		Vector3(table_center.x, 0.39, table_center.z)
	)
	_add_cylinder_visual(dining_body, "DiningTableTop", 0.70, 0.045,
		Vector3(0.0, 0.75, 0.0), _materials.wood)
	_add_cylinder_visual(dining_body, "DiningTablePedestal", 0.09, 0.70,
		Vector3(0.0, 0.375, 0.0), _materials.frame_wood)
	_add_cylinder_visual(dining_body, "DiningTableBase", 0.32, 0.04,
		Vector3(0.0, 0.02, 0.0), _materials.frame_wood)
	_add_perception(
		dining_body, "dining_table", "餐桌", "客餐厅里的圆形原木餐桌，可以一起用餐。", false,
		["observe", "eat", "place_item"]
	)
	# 餐椅 ×4:座面 0.44 高、四腿、靠背朝外侧(非感知物件,保留整块碰撞)
	var chair_offsets := [
		Vector3(0.93, 0.0, 0.02),
		Vector3(-1.005, 0.0, -0.09),
		Vector3(0.047, 0.0, -0.867),
		Vector3(0.036, 0.0, 0.935),
	]
	for chair_index in chair_offsets.size():
		var chair_position := table_center + (chair_offsets[chair_index] as Vector3)
		_add_chair(
			dining,
			"Chair%d" % chair_index,
			chair_position,
			table_center
		)
	# 绿植:陶盆(收口) + 土面 + 主干 + 三团圆叶冠(隐形全高碰撞)
	var plant_center := Vector3(2.971570, 0.0, -3.240572)
	var plant_body := _add_invisible_body(
		dining, "PlantPot", Vector3(0.55, 1.45, 0.55),
		Vector3(plant_center.x, 0.725, plant_center.z)
	)
	_add_cylinder_visual(plant_body, "PlantPotBody", 0.17, 0.36,
		Vector3(0.0, 0.18, 0.0), _materials.ceramic)
	_add_cylinder_visual(plant_body, "PlantPotRim", 0.19, 0.05,
		Vector3(0.0, 0.385, 0.0), _materials.ceramic)
	_add_cylinder_visual(plant_body, "PlantSoil", 0.16, 0.02,
		Vector3(0.0, 0.40, 0.0), _materials.soil)
	_add_cylinder_visual(plant_body, "PlantTrunk", 0.03, 0.46,
		Vector3(0.0, 0.64, 0.0), _materials.trunk)
	_add_sphere_visual(plant_body, "PlantCrownLow", 0.26,
		Vector3(-0.10, 1.02, 0.06), _materials.plant)
	_add_sphere_visual(plant_body, "PlantCrownTop", 0.22,
		Vector3(0.08, 1.24, -0.05), _materials.plant_dark)
	_add_sphere_visual(plant_body, "PlantCrownSide", 0.19,
		Vector3(0.14, 0.96, -0.10), _materials.plant)
	_add_perception(
		plant_body, "house_plant", "绿植", "小玲照料的室内绿植，叶片状态良好，盆土略干。", false,
		["observe", "photograph", "water"]
	)
	# 玻璃杯:放在 0.7725 的真实桌面上
	var glass_cup := _add_cylinder_body(
		dining,
		"GlassCup",
		0.065,
		0.20,
		Vector3(1.290139, 0.8725, -2.395984),
		_materials.glass
	)
	_add_perception(
		glass_cup, "glass_cup", "玻璃杯", "透明玻璃杯放在餐桌上。", true,
		["observe", "drink", "refill"],
		{"type": "饮用水", "fill_ratio": 0.62, "temperature": "常温"}
	)
	# 餐桌吊灯:吊杆 + 灯罩 + 灯泡
	var lamp_x := table_center.x
	var lamp_z := table_center.z
	_add_cylinder_visual(dining, "PendantCord", 0.008, 1.00,
		Vector3(lamp_x, 2.32, lamp_z), _materials.dark_wood)
	_add_cylinder_visual(dining, "PendantShade", 0.24, 0.20,
		Vector3(lamp_x, 1.74, lamp_z), _materials.brass)
	_add_sphere_visual(dining, "PendantBulb", 0.045,
		Vector3(lamp_x, 1.63, lamp_z), _materials.ceramic)


## 餐椅:座面 0.44 + 四腿 + 靠背朝背离桌方向
func _add_chair(parent: Node3D, chair_name: String, position_value: Vector3, table_center: Vector3) -> void:
	var chair := StaticBody3D.new()
	chair.name = chair_name
	chair.position = Vector3(position_value.x, 0.0, position_value.z)
	chair.collision_layer = NAVIGATION_COLLISION_LAYER
	chair.collision_mask = 0
	var to_table := table_center - chair.position
	chair.rotation.y = atan2(-to_table.x, -to_table.z)
	parent.add_child(chair)
	var collision_shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(0.46, 0.88, 0.50)
	collision_shape.shape = box_shape
	collision_shape.position = Vector3(0.0, 0.44, 0.0)
	chair.add_child(collision_shape)
	# 座面
	_add_box_visual(chair, "Seat", Vector3(0.42, 0.045, 0.42),
		Vector3(0.0, 0.44, 0.0), _materials.wood_light)
	# 四腿
	for leg_index in 4:
		_add_box_visual(chair, "Leg%d" % leg_index, Vector3(0.035, 0.42, 0.035),
			Vector3(-0.18 + float(leg_index % 2) * 0.36, 0.21, -0.18 + float(int(leg_index / 2.0)) * 0.36),
			_materials.frame_wood)
	# 靠背:两立柱 + 背板(在 -z 即背离餐桌一侧)
	_add_box_visual(chair, "BackPostLeft", Vector3(0.035, 0.44, 0.035),
		Vector3(-0.17, 0.66, -0.19), _materials.frame_wood)
	_add_box_visual(chair, "BackPostRight", Vector3(0.035, 0.44, 0.035),
		Vector3(0.17, 0.66, -0.19), _materials.frame_wood)
	_add_box_visual(chair, "BackPanel", Vector3(0.42, 0.30, 0.03),
		Vector3(0.0, 0.80, -0.19), _materials.wood_light)


func _build_anchor_markers() -> void:
	var layout := _load_house_layout()
	if not layout.is_empty():
		# 自定义布局：动态创建锚点 Marker3D + 可视化标记
		var raw_anchors = layout.get("anchors", [])
		if raw_anchors is Array:
			var palette: Array[Material] = [
				_materials.anchor_dining, _materials.anchor_sofa,
				_materials.anchor_dining, _materials.anchor_sofa,
			]
			var index := 0
			for raw in raw_anchors:
				if not raw is Dictionary:
					continue
				var anchor: Dictionary = raw
				var marker := Marker3D.new()
				marker.name = str(anchor.get("id", "anchor%d" % index))
				marker.position = Vector3(
					float(anchor.get("x", 0.0)), 0.04, float(anchor.get("z", 0.0))
				)
				add_child(marker)
				_add_anchor_marker(
					marker,
					"AnchorMarker%d" % index,
					palette[index % palette.size()],
				)
				index += 1
		return
	# 回退：场景内手写锚点
	var dining_anchor := get_node_or_null("DiningSeatLing") as Node3D
	var sofa_anchor := get_node_or_null("SofaSpot") as Node3D
	if dining_anchor:
		_add_anchor_marker(dining_anchor, "DiningAnchorMarker", _materials.anchor_dining)
	if sofa_anchor:
		_add_anchor_marker(sofa_anchor, "SofaAnchorMarker", _materials.anchor_sofa)


func _load_house_layout() -> Dictionary:
	#Load user house layout JSON, or {} when absent.
	const LAYOUT_PATH := "user://house_layout.json"
	if not FileAccess.file_exists(LAYOUT_PATH):
		return {}
	var file := FileAccess.open(LAYOUT_PATH, FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}


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


## 隐形碰撞体:只建 CollisionShape,可视化细节由调用方逐件拼装。
## 感知物件的准星射线在任何高度都能命中。
func _add_invisible_body(
	parent: Node3D,
	body_name: String,
	size: Vector3,
	position_value: Vector3
) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = body_name
	body.position = position_value
	body.collision_layer = NAVIGATION_COLLISION_LAYER
	body.collision_mask = 0
	parent.add_child(body)
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


func _add_cylinder_visual(
	parent: Node3D,
	visual_name: String,
	radius: float,
	height: float,
	position_value: Vector3,
	material: Material
) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = visual_name
	mesh_instance.position = position_value
	var cylinder_mesh := CylinderMesh.new()
	cylinder_mesh.top_radius = radius
	cylinder_mesh.bottom_radius = radius
	cylinder_mesh.height = height
	cylinder_mesh.radial_segments = 32
	cylinder_mesh.material = material
	mesh_instance.mesh = cylinder_mesh
	parent.add_child(mesh_instance)
	return mesh_instance


func _add_sphere_visual(
	parent: Node3D,
	visual_name: String,
	radius: float,
	position_value: Vector3,
	material: Material
) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = visual_name
	mesh_instance.position = position_value
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = radius
	sphere_mesh.height = radius * 2.0
	sphere_mesh.radial_segments = 24
	sphere_mesh.rings = 12
	sphere_mesh.material = material
	mesh_instance.mesh = sphere_mesh
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
