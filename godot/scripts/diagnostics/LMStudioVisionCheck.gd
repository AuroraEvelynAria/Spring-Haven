extends Node

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var image_result := _resolve_test_image()
	if not bool(image_result.get("ok", false)):
		printerr("VISION_PROVIDER_CHECK failure=", image_result.get("message", "test_image_failed"))
		get_tree().quit(2)
		return
	var image_path := str(image_result.get("path", ""))
	var preferred_mode := OS.get_environment("SPRING_HEAVEN_VISION_BACKEND").strip_edges().to_lower()
	if preferred_mode.is_empty():
		preferred_mode = "auto"
	var preparation: Dictionary = await Vision.prepare_backend(preferred_mode)
	if not bool(preparation.get("ok", false)):
		_cleanup_test_image(image_result)
		printerr("VISION_PROVIDER_CHECK failure=vision_not_configured detail=", preparation.get("message", "unknown"))
		get_tree().quit(3)
		return
	var result: Dictionary = await Vision.describe_image(image_path, {
		"scene": "living_dining_room",
		"subject": "house_plant",
		"trusted_objects": ["dining_table", "house_plant", "window"],
	}, preferred_mode)
	_cleanup_test_image(image_result)
	if not bool(result.get("ok", false)):
		printerr("VISION_PROVIDER_CHECK failure=", result.get("message", "unknown"))
		get_tree().quit(4)
		return
	var description := str(result.get("text", "")).strip_edges()
	if description.is_empty():
		printerr("VISION_PROVIDER_CHECK failure=empty_description")
		get_tree().quit(5)
		return
	var backend_mode := str(result.get("backend_mode", preparation.get("mode", "unknown")))
	var provider := str(result.get("provider", preparation.get("provider", "unknown")))
	print(
		"VISION_PROVIDER_CHECK passed backend=", backend_mode,
		" provider=", provider,
		" model=", preparation.get("model", ""),
		" description=", description.replace("\n", " ").left(1000)
	)
	get_tree().quit(0)

func _resolve_test_image() -> Dictionary:
	var configured_path := OS.get_environment("SPRING_HEAVEN_TEST_IMAGE").strip_edges()
	if not configured_path.is_empty():
		if not FileAccess.file_exists(configured_path):
			return {"ok": false, "message": "configured_test_image_missing"}
		return {"ok": true, "path": configured_path, "generated": false}
	var directory := "user://SpringHaven/diagnostics"
	var absolute_directory := ProjectSettings.globalize_path(directory)
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute_directory)
	if directory_error not in [OK, ERR_ALREADY_EXISTS]:
		return {"ok": false, "message": error_string(directory_error)}
	var image := Image.create(320, 200, false, Image.FORMAT_RGBA8)
	image.fill(Color("d9e6ef"))
	image.fill_rect(Rect2i(0, 135, 320, 65), Color("9a6d4b"))
	image.fill_rect(Rect2i(36, 30, 96, 78), Color("78a9d1"))
	image.fill_rect(Rect2i(208, 82, 34, 54), Color("6f4a36"))
	image.fill_rect(Rect2i(188, 48, 74, 42), Color("5f9f63"))
	var path := directory.path_join("vision_provider_test.png")
	var save_error := image.save_png(path)
	if save_error != OK:
		return {"ok": false, "message": error_string(save_error)}
	return {"ok": true, "path": path, "generated": true}

func _cleanup_test_image(image_result: Dictionary) -> void:
	if not bool(image_result.get("generated", false)):
		return
	DirAccess.remove_absolute(ProjectSettings.globalize_path(str(image_result.get("path", ""))))
