extends SceneTree

const BAKED_SCENE_PATH := (
	"res://local_assets/living_dining/living_dining_baked.tscn"
)
const LIGHTMAP_DATA_PATH := (
	"res://local_assets/living_dining/living_dining_baked_v9.lmbake"
)
const STARTUP_FRAMES := 180
const SELECTION_FRAMES := 60
const BAKE_TIMEOUT_MSEC := 30 * 60 * 1000


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for _frame in STARTUP_FRAMES:
		await process_frame
	EditorInterface.open_scene_from_path(BAKED_SCENE_PATH)
	for _frame in STARTUP_FRAMES:
		await process_frame

	var scene_root := EditorInterface.get_edited_scene_root()
	if not is_instance_valid(scene_root):
		_fail("无法打开 Lightmap 本地场景")
		return
	var lightmap := scene_root.get_node_or_null("LightmapGI") as LightmapGI
	if not is_instance_valid(lightmap):
		_fail("场景缺少 LightmapGI")
		return

	var selection := EditorInterface.get_selection()
	selection.clear()
	selection.add_node(lightmap)
	for _frame in SELECTION_FRAMES:
		await process_frame

	var bake_button := _find_bake_button(EditorInterface.get_base_control())
	if bake_button == null:
		_fail("找不到 Godot 的烘焙光照贴图按钮")
		return
	if bake_button.disabled:
		_fail("当前渲染设备不支持 Lightmap 烘焙：%s" % bake_button.tooltip_text)
		return

	print("LIGHTMAP_BAKE_AUTOMATION started data=%s" % LIGHTMAP_DATA_PATH)
	var initial_modified_time := (
		FileAccess.get_modified_time(LIGHTMAP_DATA_PATH)
		if FileAccess.file_exists(LIGHTMAP_DATA_PATH)
		else 0
	)
	var existing_data := lightmap.light_data
	var path_submitted := (
		existing_data != null
		and existing_data.resource_path == LIGHTMAP_DATA_PATH
	)
	bake_button.pressed.emit()
	var started_at := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_at < BAKE_TIMEOUT_MSEC:
		await process_frame
		if not path_submitted:
			var file_dialog := _find_visible_file_dialog(EditorInterface.get_base_control())
			if file_dialog != null:
				file_dialog.file_selected.emit(LIGHTMAP_DATA_PATH)
				file_dialog.hide()
				path_submitted = true
		if path_submitted:
			var confirmation := _find_visible_confirmation_dialog(
				EditorInterface.get_base_control()
			)
			if confirmation != null:
				confirmation.confirmed.emit()
				confirmation.hide()
		var current_data := lightmap.light_data
		if (
			path_submitted
			and current_data != null
			and current_data.get_user_count() > 0
			and current_data.get_lightmap_textures() != null
			and FileAccess.file_exists(LIGHTMAP_DATA_PATH)
			and (
				initial_modified_time == 0
				or FileAccess.get_modified_time(LIGHTMAP_DATA_PATH) > initial_modified_time
			)
		):
			for _frame in 120:
				await process_frame
			var data_save_error := ResourceSaver.save(current_data, LIGHTMAP_DATA_PATH)
			if data_save_error != OK:
				_fail("LightmapGIData 保存失败：%s" % error_string(data_save_error))
				return
			EditorInterface.save_scene()
			print(
				"LIGHTMAP_BAKE_AUTOMATION=PASS users=%d bytes=%d"
				% [
					current_data.get_user_count(),
					FileAccess.get_file_as_bytes(LIGHTMAP_DATA_PATH).size(),
				]
			)
			quit(0)
			return

	_fail("Lightmap 烘焙超过 30 分钟")


func _find_bake_button(root_node: Node) -> Button:
	if root_node == null:
		return null
	var pending: Array[Node] = [root_node]
	while not pending.is_empty():
		var current: Node = pending.pop_front()
		if current is Button:
			var button := current as Button
			var label := (button.text + " " + button.tooltip_text).to_lower()
			if label.contains("bake lightmaps") or label.contains("烘焙光照贴图"):
				return button
		for child_value in current.get_children():
			if child_value is Node:
				pending.append(child_value)
	return null


func _find_visible_file_dialog(root_node: Node) -> FileDialog:
	if root_node == null:
		return null
	var pending: Array[Node] = [root_node]
	while not pending.is_empty():
		var current: Node = pending.pop_front()
		if current is FileDialog and (current as FileDialog).visible:
			return current as FileDialog
		for child_value in current.get_children():
			if child_value is Node:
				pending.append(child_value)
	return null


func _find_visible_confirmation_dialog(root_node: Node) -> ConfirmationDialog:
	if root_node == null:
		return null
	var pending: Array[Node] = [root_node]
	while not pending.is_empty():
		var current: Node = pending.pop_front()
		if (
			current is ConfirmationDialog
			and not current is FileDialog
			and (current as ConfirmationDialog).visible
		):
			return current as ConfirmationDialog
		for child_value in current.get_children():
			if child_value is Node:
				pending.append(child_value)
	return null


func _fail(message: String) -> void:
	printerr("LIGHTMAP_BAKE_AUTOMATION=FAIL " + message)
	quit(1)
