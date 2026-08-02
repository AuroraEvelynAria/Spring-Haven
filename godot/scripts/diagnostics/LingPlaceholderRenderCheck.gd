extends SceneTree

const MODEL_PATH := "res://local_assets/ling_placeholder/ling_placeholder.glb"


func _initialize() -> void:
	call_deferred("_render_model")


func _render_model() -> void:
	var packed := ResourceLoader.load(MODEL_PATH) as PackedScene
	if packed == null:
		push_error("LING_PLACEHOLDER_RENDER_CHECK: model could not be loaded")
		quit(1)
		return

	root.size = Vector2i(720, 720)
	var stage := Node3D.new()
	root.add_child(stage)
	stage.add_child(packed.instantiate())

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("d9d3cd")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("fff5ed")
	environment.ambient_light_energy = 0.8
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	stage.add_child(world_environment)

	var key_light := DirectionalLight3D.new()
	key_light.light_color = Color("fff0df")
	key_light.light_energy = 1.35
	key_light.rotation_degrees = Vector3(-42.0, -28.0, 0.0)
	key_light.shadow_enabled = true
	stage.add_child(key_light)

	var fill_light := DirectionalLight3D.new()
	fill_light.light_color = Color("d6e5ff")
	fill_light.light_energy = 0.45
	fill_light.rotation_degrees = Vector3(-20.0, 145.0, 0.0)
	stage.add_child(fill_light)

	var camera := Camera3D.new()
	camera.fov = 34.0
	stage.add_child(camera)
	camera.position = Vector3(0.0, 1.02, -4.15)
	camera.look_at(Vector3(0.0, 1.0, 0.0), Vector3.UP)
	camera.current = true

	for _frame in range(8):
		await process_frame
	RenderingServer.force_draw(false)
	await process_frame

	var output_path := OS.get_environment("LING_RENDER_OUTPUT")
	if output_path.is_empty():
		output_path = ProjectSettings.globalize_path("user://ling_placeholder_godot.png")
	var image := root.get_texture().get_image()
	var save_error := image.save_png(output_path)
	if save_error != OK:
		push_error("LING_PLACEHOLDER_RENDER_CHECK: failed to save screenshot: %s" % error_string(save_error))
		quit(1)
		return
	print("LING_PLACEHOLDER_RENDER=" + output_path)
	print("LING_PLACEHOLDER_RENDER_CHECK=PASS")
	quit(0)
