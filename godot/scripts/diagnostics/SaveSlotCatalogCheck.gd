extends SceneTree

const GLOBAL_SCRIPT := preload("res://scripts/autoload/Global.gd")

var _failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var stamp := str(Time.get_ticks_usec())
	var test_root := "user://SpringHaven/diagnostics/save-slot-check-%s" % stamp
	var model := GLOBAL_SCRIPT.new()
	model.set("game_data_path", test_root)
	model.set("_save_root_override", test_root.path_join("saves"))
	root.add_child(model)
	await process_frame

	var initial_slots: Array = model.call("list_save_slots", false)
	_expect(initial_slots.size() == 1, "首次启动没有创建独立旅程槽位")
	var first_id := str(model.get("save_id"))
	_expect(FileAccess.file_exists(test_root.path_join("saves").path_join("%s.json" % first_id)), "首个旅程文件不存在")
	_expect(FileAccess.file_exists(test_root.path_join("saves").path_join("index.json")), "存档索引不存在")

	model.set("current_character", "nai")
	var first_stats: Dictionary = model.call("get_role_stats", "ling").duplicate(true)
	first_stats["mood"] = 23.0
	(model.get("stats_by_role") as Dictionary)["ling"] = first_stats
	var first_history: Array[Dictionary] = [{
		"id": "slot-check-message",
		"sender": "user",
		"text": "第一段旅程的消息",
		"status": "sent",
		"created_at": int(Time.get_unix_time_from_system()),
	}]
	model.set("conversation_history", first_history)
	_expect(bool(model.call("save_default_state")), "首个旅程保存失败")

	var create_result: Dictionary = model.call("reset_default_state", "第二段旅程")
	_expect(bool(create_result.get("ok", false)), "第二个旅程创建失败")
	var second_id := str(model.get("save_id"))
	_expect(second_id != first_id, "新旅程复用了旧 save_id")
	_expect(FileAccess.file_exists(test_root.path_join("saves").path_join("%s.json" % first_id)), "新旅程覆盖了旧旅程文件")
	var two_slots: Array = model.call("list_save_slots", false)
	_expect(two_slots.size() == 2, "存档索引没有保留两个旅程")
	_expect(_slot_name(two_slots, second_id) == "第二段旅程", "新旅程名称没有写入索引")

	var load_first: Dictionary = model.call("load_save_slot", first_id)
	_expect(bool(load_first.get("ok", false)), "旧旅程无法重新载入")
	_expect(str(model.get("current_character")) == "nai", "旧旅程当前角色没有恢复")
	_expect(is_equal_approx(float(model.call("get_role_stats", "ling").get("mood", 0.0)), 23.0), "旧旅程属性没有恢复")
	var restored_message_count := (model.get("conversation_history") as Array).size()
	_expect(restored_message_count == 1, "旧旅程即时对话没有恢复，实际 %d 条" % restored_message_count)

	var rename_result: Dictionary = model.call("rename_save_slot", first_id, "第一次相遇")
	_expect(bool(rename_result.get("ok", false)), "旅程重命名失败")
	_expect(_slot_name(model.call("list_save_slots", true), first_id) == "第一次相遇", "重命名没有持久化")
	var archive_result: Dictionary = model.call("set_save_slot_archived", second_id, true)
	_expect(bool(archive_result.get("ok", false)), "非当前旅程无法归档")
	_expect((model.call("list_save_slots", false) as Array).size() == 1, "归档旅程仍出现在默认列表")
	_expect((model.call("list_save_slots", true) as Array).size() == 2, "归档旅程文件或索引被删除")
	_expect(bool(model.call("set_save_slot_archived", second_id, false).get("ok", false)), "归档旅程无法恢复")

	var migration_root := test_root + "-migration"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(migration_root.path_join("saves")))
	var legacy_payload := {
		"version": model.SAVE_VERSION,
		"balance_version": model.BALANCE_VERSION,
		"save_id": "legacy-save-check",
		"created_at": 1700000000,
		"current_role": "ling",
		"stats_by_role": model.get("stats_by_role"),
		"conversation_history": [],
		"applied_local_effect_ids": [],
		"full_stat_milestones": {},
		"life_runtime": {},
		"updated_at": 1700000001,
	}
	var legacy_path := migration_root.path_join("saves/default.json")
	var legacy_file := FileAccess.open(legacy_path, FileAccess.WRITE)
	legacy_file.store_string(JSON.stringify(legacy_payload, "\t"))
	legacy_file.close()
	var migrated_model := GLOBAL_SCRIPT.new()
	migrated_model.set("game_data_path", migration_root)
	migrated_model.set("_save_root_override", migration_root.path_join("saves"))
	root.add_child(migrated_model)
	await process_frame
	_expect(str(migrated_model.get("save_id")) == "legacy-save-check", "旧单槽迁移改变了 save_id")
	_expect(FileAccess.file_exists(legacy_path), "旧 default.json 在迁移时被删除")
	_expect(FileAccess.file_exists(migration_root.path_join("saves/legacy-save-check.json")), "旧单槽没有迁移为独立文件")
	_expect((migrated_model.call("list_save_slots", false) as Array).size() == 1, "旧单槽没有登记到索引")

	migrated_model.free()
	model.free()
	if _failures.is_empty():
		_cleanup_diagnostic_tree(test_root)
		_cleanup_diagnostic_tree(migration_root)
		print("SAVE_SLOT_CATALOG_CHECK=PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("SAVE_SLOT_CATALOG_CHECK failure=", failure)
	printerr("SAVE_SLOT_CATALOG_CHECK artifacts=", ProjectSettings.globalize_path(test_root))
	quit(1)


func _slot_name(slots: Array, target_id: String) -> String:
	for slot in slots:
		if slot is Dictionary and str((slot as Dictionary).get("save_id", "")) == target_id:
			return str((slot as Dictionary).get("display_name", ""))
	return ""


func _cleanup_diagnostic_tree(path: String) -> void:
	var absolute := ProjectSettings.globalize_path(path).simplify_path()
	var diagnostic_root := ProjectSettings.globalize_path("user://SpringHaven/diagnostics").simplify_path()
	if not absolute.begins_with(diagnostic_root.path_join("save-slot-check-")):
		push_error("拒绝清理非存档诊断目录：%s" % absolute)
		return
	_remove_directory_contents(absolute)
	DirAccess.remove_absolute(absolute)


func _remove_directory_contents(absolute: String) -> void:
	var directory := DirAccess.open(absolute)
	if directory == null:
		return
	for subdirectory in directory.get_directories():
		var child := absolute.path_join(subdirectory)
		_remove_directory_contents(child)
		DirAccess.remove_absolute(child)
	for file_name in directory.get_files():
		DirAccess.remove_absolute(absolute.path_join(file_name))


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
