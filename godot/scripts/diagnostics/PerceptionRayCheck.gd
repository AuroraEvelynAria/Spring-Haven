extends SceneTree

const RAY_SCRIPT := preload("res://scenes/Exploration/Perception/PerceptionRay3D.gd")
const PERCEIVABLE_SCRIPT := preload("res://scenes/Exploration/Perception/Perceivable3D.gd")

var _failures: Array[String] = []
var _checks := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var ray := RAY_SCRIPT.new()
	ray.position = Vector3(0, 1.0, 0)
	ray.max_distance = 5.0
	ray.max_hits = 4
	ray.observer_role_id = "ling"
	world.add_child(ray)
	_add_body(world, Vector3(0, 1.0, -1.0), Vector3(0.4, 0.5, 0.08), {
		"entity_id": "glass_cup",
		"name": "玻璃杯",
		"description": "透明玻璃杯放在前方。",
		"transparent": true,
		"actions": ["observe", "drink"],
		"content_type": "饮用水",
		"fill_ratio": 0.62,
	})
	_add_body(world, Vector3(0, 1.0, -2.0), Vector3(1.2, 0.8, 0.18), {
		"entity_id": "dining_table",
		"name": "餐桌",
		"description": "玻璃杯后方的木餐桌。",
		"transparent": false,
		"actions": ["observe", "eat"],
	})
	await physics_frame
	await physics_frame
	var result: Dictionary = ray.scan()
	_expect(str(result.get("protocol", "")) == "spring_heaven.perception.v1", "感知协议错误")
	_expect(str(result.get("role_id", "")) == "ling", "感知角色绑定错误")
	var observations = result.get("observations", [])
	_expect(observations is Array and observations.size() == 2, "透明物体没有继续穿透识别后方物体")
	if observations is Array and observations.size() == 2:
		var glass: Dictionary = observations[0]
		var table: Dictionary = observations[1]
		_expect(str(glass.get("entity_id", "")) == "glass_cup", "首个感知物体不是玻璃杯")
		_expect(bool(glass.get("transparent", false)), "玻璃杯未标记为可穿透")
		var contents = glass.get("contents", {})
		_expect(contents is Dictionary and str(contents.get("level", "")) == "大半", "杯中水量文字状态错误")
		_expect(str(table.get("entity_id", "")) == "dining_table", "后方物体不是餐桌")
		_expect(not bool(table.get("transparent", true)), "餐桌不应继续穿透")

	world.queue_free()
	if _failures.is_empty():
		print("PERCEPTION_RAY_CHECK passed=", _checks)
		quit(0)
		return
	for failure in _failures:
		printerr("PERCEPTION_RAY_CHECK failure=", failure)
	quit(1)

func _add_body(parent: Node3D, position_value: Vector3, size: Vector3, data: Dictionary) -> void:
	var body := StaticBody3D.new()
	body.position = position_value
	body.collision_layer = 1
	body.collision_mask = 0
	parent.add_child(body)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	var perceivable := PERCEIVABLE_SCRIPT.new()
	perceivable.entity_id = str(data.entity_id)
	perceivable.display_name = str(data.name)
	perceivable.description = str(data.description)
	perceivable.perception_transparent = bool(data.transparent)
	var actions: Array[String] = []
	for action_variant in data.get("actions", []):
		actions.append(str(action_variant))
	perceivable.available_actions = actions
	perceivable.content_type = str(data.get("content_type", ""))
	perceivable.fill_ratio = float(data.get("fill_ratio", 0.0))
	body.add_child(perceivable)

func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
