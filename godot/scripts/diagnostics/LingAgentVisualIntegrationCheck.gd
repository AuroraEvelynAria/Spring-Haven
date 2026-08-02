extends SceneTree

const LING_AGENT_SCENE := preload(
	"res://scenes/Exploration/Characters/LingAgent3D.tscn"
)
const LOAD_TIMEOUT_MSEC := 30000

var _checks := 0
var _failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var ling := LING_AGENT_SCENE.instantiate()
	ling.set("load_local_placeholder_model", true)
	ling.set("load_local_placeholder_in_headless", true)
	root.add_child(ling)
	var started_at := Time.get_ticks_msec()
	while (
		not bool(ling.call("is_local_visual_loaded"))
		and Time.get_ticks_msec() - started_at < LOAD_TIMEOUT_MSEC
	):
		await process_frame

	_expect(bool(ling.call("is_local_visual_loaded")), "本地占位模型未被小玲代理加载")
	_expect(
		str(ling.call("get_local_visual_path"))
		== "res://local_assets/ling_placeholder/ling_placeholder.glb",
		"小玲代理报告的本地视觉路径错误"
	)
	var local_visual := ling.get_node_or_null("VisualPivot/LocalLingPlaceholder")
	_expect(is_instance_valid(local_visual), "本地占位模型没有挂到 VisualPivot")
	if local_visual is Node3D:
		var world_scale := (local_visual as Node3D).global_transform.basis.get_scale()
		_expect(
			absf(world_scale.y - 0.82) <= 0.02,
			"小玲本地模型没有缩放到约 1.59 米"
		)
	var fallback_torso := ling.get_node("VisualPivot/Torso") as MeshInstance3D
	_expect(not fallback_torso.visible, "本地模型加载后方块占位仍然可见")
	_expect(is_instance_valid(ling.get_node_or_null("CollisionShape3D")), "加载视觉模型破坏了碰撞体")
	_expect(
		is_instance_valid(ling.get_node_or_null("NavigationAgent3D")),
		"加载视觉模型破坏了导航代理"
	)

	ling.queue_free()
	await process_frame
	if _failures.is_empty():
		print("LING_AGENT_VISUAL_INTEGRATION_CHECK passed=", _checks)
		quit(0)
		return
	for failure in _failures:
		printerr("LING_AGENT_VISUAL_INTEGRATION_CHECK failure=", failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
