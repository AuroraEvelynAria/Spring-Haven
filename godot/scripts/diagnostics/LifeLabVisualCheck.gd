extends Node

const LIFE_LAB_SCENE := preload("res://scenes/LifeLab/LifeLabWorld.tscn")


func _ready() -> void:
	var world := LIFE_LAB_SCENE.instantiate()
	add_child(world)
	var controller: LifeLabTaskController = world.get_task_controller()
	controller.set_autonomous_enabled(false)
	var deadline := Time.get_ticks_msec() + 40000
	while Time.get_ticks_msec() < deadline:
		var ling = world.get_agent("ling")
		var nai = world.get_agent("nai")
		if (
			world.is_navigation_ready()
			and ling.call("is_local_visual_loaded")
			and nai.call("is_local_visual_loaded")
		):
			break
		await get_tree().process_frame
	var ling_loaded: bool = world.get_agent("ling").call("is_local_visual_loaded")
	var nai_loaded: bool = world.get_agent("nai").call("is_local_visual_loaded")
	if not world.is_navigation_ready() or not ling_loaded or not nai_loaded:
		push_error("生活实验室画面准备超时 nav=%s ling=%s nai=%s" % [
			world.is_navigation_ready(), ling_loaded, nai_loaded,
		])
		get_tree().quit(1)
		return
	var eye_image: Image = await world.capture_role_view("ling")
	if eye_image == null or eye_image.is_empty() or eye_image.get_width() != 512 or eye_image.get_height() != 320:
		push_error("小玲角色视角截图无效")
		get_tree().quit(1)
		return
	controller.request_action("ling", "plant")
	controller.request_action("nai", "drink")
	for _index in 150:
		await get_tree().process_frame
	var image := get_viewport().get_texture().get_image()
	var output_path := OS.get_environment("SPRING_HEAVEN_VISUAL_OUTPUT").strip_edges()
	if output_path.is_empty():
		output_path = ProjectSettings.globalize_path("user://life_lab_visual_check.png")
	var error := image.save_png(output_path)
	if error != OK:
		push_error("无法保存生活实验室截图：%s" % error_string(error))
		get_tree().quit(1)
		return
	var minimum := 1.0
	var maximum := 0.0
	var colored_samples := 0
	var total_samples := 0
	for y in range(0, image.get_height(), 12):
		for x in range(0, image.get_width(), 12):
			var pixel := image.get_pixel(x, y)
			var luminance := pixel.get_luminance()
			minimum = minf(minimum, luminance)
			maximum = maxf(maximum, luminance)
			if maxf(pixel.r, maxf(pixel.g, pixel.b)) - minf(pixel.r, minf(pixel.g, pixel.b)) > 0.08:
				colored_samples += 1
			total_samples += 1
	var valid := (
		image.get_width() >= 640
		and image.get_height() >= 360
		and maximum - minimum > 0.25
		and colored_samples > total_samples / 40
	)
	print("LIFE_LAB_VISUAL_CHECK: %s path=%s size=%dx%d luma=%.3f..%.3f colored=%d/%d models=%s,%s" % [
		"PASS" if valid else "FAIL", output_path, image.get_width(), image.get_height(),
		minimum, maximum, colored_samples, total_samples, ling_loaded, nai_loaded,
	])
	get_tree().quit(0 if valid else 1)
