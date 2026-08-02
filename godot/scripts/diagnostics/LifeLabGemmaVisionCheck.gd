extends Node

const LIFE_LAB_SCENE := preload("res://scenes/LifeLab/LifeLabWorld.tscn")


func _ready() -> void:
	var preparation: Dictionary = await Vision.prepare_backend()
	if not bool(preparation.get("ok", false)):
		printerr("LIFE_LAB_VISION_CHECK failure=vision_not_configured detail=", preparation.get("message", "unknown"))
		get_tree().quit(5)
		return
	var world := LIFE_LAB_SCENE.instantiate()
	add_child(world)
	world.get_task_controller().set_autonomous_enabled(false)
	var deadline := Time.get_ticks_msec() + 40000
	while Time.get_ticks_msec() < deadline:
		if (
			world.is_navigation_ready()
			and world.get_agent("ling").call("is_local_visual_loaded")
		):
			break
		await get_tree().process_frame
	if not world.is_navigation_ready():
		printerr("LIFE_LAB_VISION_CHECK failure=scene_not_ready")
		get_tree().quit(2)
		return
	world.set("_selected_role", "ling")
	world.call("_observe_selected_roles")
	var vision_deadline := Time.get_ticks_msec() + 60000
	while bool(world.get("_vision_busy")) and Time.get_ticks_msec() < vision_deadline:
		await get_tree().process_frame
	var cached: Dictionary = world.get_task_controller().get_visual_context("ling")
	var description := str(cached.get("description", "")).strip_edges()
	if bool(world.get("_vision_busy")):
		printerr("LIFE_LAB_VISION_CHECK failure=button_path_timeout")
		get_tree().quit(3)
		return
	if description.is_empty():
		printerr("LIFE_LAB_VISION_CHECK failure=empty_or_uncached")
		get_tree().quit(4)
		return
	print(
		"LIFE_LAB_VISION_CHECK passed backend=", preparation.get("mode", "unknown"),
		" provider=", cached.get("provider", preparation.get("provider", "unknown")),
		" model=", preparation.get("model", ""),
		" description=", description.replace("\n", " ").left(1400)
	)
	get_tree().quit(0)
