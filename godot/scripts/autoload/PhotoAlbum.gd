extends Node

signal photo_saved(metadata: Dictionary)

const ROOT_PATH := "user://SpringHaven/photos"

func save_image(image: Image, role: String, label := "photo") -> Dictionary:
	if image == null or image.is_empty():
		return {"ok": false, "message": "照片图像为空"}
	var safe_role := role if role in ["ling", "nai", "player"] else "shared"
	var safe_label := _safe_file_part(label, "photo")
	var save_id := Global.get_active_save_id()
	var directory := ROOT_PATH.path_join(save_id).path_join(safe_role)
	var absolute_directory := ProjectSettings.globalize_path(directory)
	var make_error := DirAccess.make_dir_recursive_absolute(absolute_directory)
	if make_error != OK and make_error != ERR_ALREADY_EXISTS:
		return {"ok": false, "message": error_string(make_error)}
	var timestamp := _timestamp_text()
	var file_name := "%s_%s_%d.png" % [timestamp, safe_label, Time.get_ticks_msec() % 1000]
	var path := directory.path_join(file_name)
	var error := image.save_png(path)
	if error != OK:
		return {"ok": false, "message": error_string(error)}
	var metadata := {
		"ok": true,
		"path": path,
		"absolute_path": ProjectSettings.globalize_path(path),
		"role_id": safe_role,
		"save_id": save_id,
		"captured_at_unix": int(Time.get_unix_time_from_system()),
		"label": safe_label,
	}
	photo_saved.emit(metadata.duplicate(true))
	return metadata

func capture_viewport(viewport: Viewport, role: String, label := "photo") -> Dictionary:
	if not is_instance_valid(viewport) or viewport.get_texture() == null:
		return {"ok": false, "message": "拍照视口不可用"}
	return save_image(viewport.get_texture().get_image(), role, label)

func album_path_for_current_save() -> String:
	return ROOT_PATH.path_join(Global.get_active_save_id())

func _timestamp_text() -> String:
	var value := Time.get_datetime_dict_from_system()
	return "%04d-%02d-%02d_%02d-%02d-%02d" % [
		int(value.year), int(value.month), int(value.day),
		int(value.hour), int(value.minute), int(value.second),
	]

func _safe_file_part(value: String, fallback: String) -> String:
	var result := value.strip_edges().validate_filename().replace(" ", "_").left(48)
	return fallback if result.is_empty() else result
