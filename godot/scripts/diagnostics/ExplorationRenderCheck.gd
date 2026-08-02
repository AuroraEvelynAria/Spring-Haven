extends SceneTree

const EXPLORATION_SCENE := preload("res://scenes/Exploration/ExplorationWorld.tscn")


func _initialize() -> void:
	_render.call_deferred()


func _render() -> void:
	root.size = Vector2i(1280, 720)
	var world := EXPLORATION_SCENE.instantiate()
	world.call("set_global_state_node", null)
	root.add_child(world)
	var player := world.get_node("Player3D")
	if player.has_method("set_mouse_captured"):
		player.call("set_mouse_captured", false)
	var ling := world.get_node("LingAgent3D")
	var local_room := world.get_node("LocalRoomVisual")
	for _frame in 600:
		if (
			bool(ling.call("is_local_visual_loaded"))
			and bool(local_room.call("is_model_loaded"))
			and world.get("_navigation_ready") == true
		):
			break
		await process_frame
	for _frame in 12:
		await process_frame
	RenderingServer.force_draw(false)
	await process_frame

	var output_path := OS.get_environment("EXPLORATION_RENDER_OUTPUT")
	if output_path.is_empty():
		output_path = ProjectSettings.globalize_path("user://exploration_world.png")
	var save_error := root.get_texture().get_image().save_png(output_path)
	if save_error != OK:
		push_error("EXPLORATION_RENDER_CHECK failed to save: %s" % error_string(save_error))
		quit(1)
		return
	print("EXPLORATION_RENDER=", output_path)
	print("EXPLORATION_RENDER_LOCAL_MODEL=", bool(ling.call("is_local_visual_loaded")))
	print("EXPLORATION_RENDER_LOCAL_ROOM=", bool(local_room.call("is_model_loaded")))
	print("EXPLORATION_RENDER_CHECK=PASS")
	quit(0)
