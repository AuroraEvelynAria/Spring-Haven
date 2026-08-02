extends SceneTree


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var global := root.get_node_or_null("Global")
	if global == null:
		printerr("RECOVER_LEGACY_JOURNEY_CHECK=FAIL Global autoload unavailable")
		quit(2)
		return
	var target_save_id := OS.get_environment("SPRING_HAVEN_RECOVERY_SAVE_ID").strip_edges()
	if target_save_id.is_empty():
		printerr("RECOVER_LEGACY_JOURNEY_CHECK=FAIL missing SPRING_HAVEN_RECOVERY_SAVE_ID")
		quit(2)
		return
	if not bool(global.call("is_valid_save_id", target_save_id)):
		printerr("RECOVER_LEGACY_JOURNEY_CHECK=FAIL invalid save_id")
		quit(2)
		return

	var active_before := str(global.call("get_active_save_id"))
	var global_save_before := str(global.get("save_id"))
	var existing := _find_slot(global, target_save_id)
	if existing.is_empty():
		var result: Dictionary = global.call("recover_archived_journey", target_save_id)
		if not bool(result.get("ok", false)):
			printerr("RECOVER_LEGACY_JOURNEY_CHECK=FAIL ", str(result.get("message", "恢复失败")))
			quit(1)
			return
		existing = _find_slot(global, target_save_id)

	var failures: Array[String] = []
	if str(global.call("get_active_save_id")) != active_before or str(global.get("save_id")) != global_save_before:
		failures.append("恢复旧旅程时意外切换了当前旅程")
	if existing.is_empty():
		failures.append("恢复后存档索引中没有旧旅程")
	else:
		if str(existing.get("recovery_kind", "")) != "conversation_only":
			failures.append("旧旅程没有标记为部分恢复")
		if int(existing.get("message_count", 0)) <= 0:
			failures.append("旧旅程没有接回聊天归档")
		if not bool(existing.get("file_available", false)):
			failures.append("旧旅程槽位文件不可用")
	if not failures.is_empty():
		for failure in failures:
			printerr("RECOVER_LEGACY_JOURNEY_CHECK failure=", failure)
		quit(1)
		return
	print(
		"RECOVER_LEGACY_JOURNEY_CHECK=PASS save_id=", target_save_id,
		" messages=", int(existing.get("message_count", 0)),
		" active_unchanged=", active_before
	)
	quit(0)


func _find_slot(global: Node, target_save_id: String) -> Dictionary:
	for slot_variant in global.call("list_save_slots", true):
		if (
			slot_variant is Dictionary
			and str((slot_variant as Dictionary).get("save_id", "")) == target_save_id
		):
			return (slot_variant as Dictionary).duplicate(true)
	return {}
