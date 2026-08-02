extends SceneTree

const EXPLORATION_SCENE := preload("res://scenes/Exploration/ExplorationWorld.tscn")
const LOAD_TIMEOUT_MSEC := 120000

var _checks := 0
var _failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var world := EXPLORATION_SCENE.instantiate()
	world.call("set_global_state_node", null)
	var local_room := world.get_node("LocalRoomVisual")
	local_room.set("load_local_room_model", true)
	local_room.set("load_local_room_in_headless", true)
	root.add_child(world)
	var started_at := Time.get_ticks_msec()
	while (
		not bool(local_room.call("is_model_loaded"))
		and Time.get_ticks_msec() - started_at < LOAD_TIMEOUT_MSEC
	):
		await process_frame

	_expect(bool(local_room.call("is_model_loaded")), "正式客餐厅本地视觉未加载")
	_expect(
		str(local_room.call("get_loaded_resource_path"))
		== "res://local_assets/living_dining/living_dining_baked.tscn",
		"运行时没有优先使用预烘焙客餐厅"
	)
	var baked_room := local_room.get_node_or_null("LivingDiningBaked")
	_expect(is_instance_valid(baked_room), "预烘焙客餐厅没有挂到 LocalRoomVisual")
	var lightmap := (
		baked_room.get_node_or_null("LightmapGI") as LightmapGI
		if is_instance_valid(baked_room)
		else null
	)
	_expect(lightmap != null and lightmap.light_data != null, "运行时 LightmapGIData 未绑定")
	_expect(
		not (world.get_node("Sun") as DirectionalLight3D).visible
		and not (world.get_node("LivingWarmLight") as OmniLight3D).visible
		and not (world.get_node("DiningWarmLight") as OmniLight3D).visible,
		"使用预烘焙光照时仍启用了重复实时灯光"
	)
	var graybox := world.get_node("NavigationRegion3D/GrayboxRoom")
	_expect(not bool(graybox.call("are_visuals_visible")), "正式视觉加载后灰盒仍然可见")
	_expect(
		is_instance_valid(graybox.get_node_or_null("Architecture/Floor/Collision")),
		"隐藏灰盒视觉时碰撞代理被删除"
	)
	_expect(world.get("_navigation_ready") == true, "正式视觉加载后导航没有就绪")

	world.queue_free()
	await process_frame
	if _failures.is_empty():
		print("ROOM_VISUAL_INTEGRATION_CHECK passed=", _checks)
		quit(0)
		return
	for failure in _failures:
		printerr("ROOM_VISUAL_INTEGRATION_CHECK failure=", failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
