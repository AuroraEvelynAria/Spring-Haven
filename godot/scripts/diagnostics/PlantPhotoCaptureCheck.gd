extends Node

const EXPLORATION_SCENE := preload("res://scenes/Exploration/ExplorationWorld.tscn")

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	Global.save_id = "diagnostic-plant-photo"
	Global.current_character = "ling"
	Global.stats_by_role = Global.call("_normalize_stats_by_role", {})
	Global.conversation_history = []
	Global.applied_local_effect_ids = []
	Global.full_stat_milestones = {}
	Global.life_runtime = Global.call("_normalize_life_runtime", {})
	Global.state_loaded = true
	var world := EXPLORATION_SCENE.instantiate()
	get_tree().root.add_child(world)
	for _frame in 8:
		await get_tree().process_frame
	await world.call("_capture_and_share_plant_photo")
	var album_path := Photos.album_path_for_current_save().path_join("ling")
	var absolute_album := ProjectSettings.globalize_path(album_path)
	var files := DirAccess.get_files_at(absolute_album)
	var photo_path := ""
	for file_name in files:
		if "house_plant" in file_name and file_name.get_extension().to_lower() == "png":
			photo_path = album_path.path_join(file_name)
			break
	if photo_path.is_empty():
		printerr("PLANT_PHOTO_CAPTURE_CHECK failure=没有生成绿植照片")
		await _finish(world, 1)
		return
	var image := Image.load_from_file(photo_path)
	if image == null or image.is_empty() or image.get_width() != 640 or image.get_height() != 360:
		printerr("PLANT_PHOTO_CAPTURE_CHECK failure=照片尺寸或像素无效")
		await _finish(world, 2)
		return
	print("PLANT_PHOTO_CAPTURE_CHECK passed size=640x360 file=", photo_path.get_file())
	await _finish(world, 0)

func _finish(world: Node, exit_code: int) -> void:
	if is_instance_valid(world):
		world.free()
		for _frame in 6:
			await get_tree().process_frame
	get_tree().quit(exit_code)
