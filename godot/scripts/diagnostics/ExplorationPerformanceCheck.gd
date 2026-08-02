extends SceneTree

const EXPLORATION_SCENE := preload("res://scenes/Exploration/ExplorationWorld.tscn")
const LOAD_TIMEOUT_MSEC := 60_000
const WARMUP_FRAMES := 120
const SAMPLE_FRAMES := 300


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1280, 720)
	var world := EXPLORATION_SCENE.instantiate()
	world.call("set_global_state_node", null)
	root.add_child(world)
	var player := world.get_node("Player3D")
	if player.has_method("set_mouse_captured"):
		player.call("set_mouse_captured", false)
	var ling := world.get_node("LingAgent3D")
	var local_room := world.get_node("LocalRoomVisual")
	var started_at := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_at < LOAD_TIMEOUT_MSEC:
		if (
			bool(ling.call("is_local_visual_loaded"))
			and bool(local_room.call("is_model_loaded"))
			and world.get("_navigation_ready") == true
		):
			break
		await process_frame
	if (
		not bool(ling.call("is_local_visual_loaded"))
		or not bool(local_room.call("is_model_loaded"))
		or world.get("_navigation_ready") != true
	):
		printerr("EXPLORATION_PERFORMANCE_CHECK=FAIL resources_not_ready")
		quit(1)
		return

	for _frame in WARMUP_FRAMES:
		await process_frame
	var frame_times: Array[float] = []
	for _frame in SAMPLE_FRAMES:
		var frame_started := Time.get_ticks_usec()
		await process_frame
		frame_times.append((Time.get_ticks_usec() - frame_started) / 1000.0)
	frame_times.sort()
	var total_msec := 0.0
	for frame_msec in frame_times:
		total_msec += frame_msec
	var average_msec := total_msec / float(frame_times.size())
	var p95_index := mini(frame_times.size() - 1, int(ceil(frame_times.size() * 0.95)) - 1)
	var report := {
		"resolution": [root.size.x, root.size.y],
		"sample_frames": SAMPLE_FRAMES,
		"average_frame_msec": snappedf(average_msec, 0.001),
		"average_fps": snappedf(1000.0 / maxf(average_msec, 0.001), 0.1),
		"p95_frame_msec": snappedf(frame_times[p95_index], 0.001),
		"engine_fps": snappedf(float(Performance.get_monitor(Performance.TIME_FPS)), 0.1),
		"process_msec": snappedf(float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0, 0.001),
		"physics_msec": snappedf(float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0, 0.001),
		"objects": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"primitives": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"static_memory_bytes": int(Performance.get_monitor(Performance.MEMORY_STATIC)),
		"baked_lightmap": bool(local_room.call("is_using_baked_lightmap")),
	}
	print("EXPLORATION_PERFORMANCE=" + JSON.stringify(report))
	if report.average_fps < 30.0 or not report.baked_lightmap:
		printerr("EXPLORATION_PERFORMANCE_CHECK=FAIL")
		quit(1)
		return
	print("EXPLORATION_PERFORMANCE_CHECK=PASS")
	quit(0)
