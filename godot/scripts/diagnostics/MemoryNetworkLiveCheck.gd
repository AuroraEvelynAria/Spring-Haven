extends Node

const PANEL_SCENE := preload("res://scenes/MemoryNetwork/MemoryNetworkPanel.tscn")


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	CompanionCore.set_save_id(Global.get_active_save_id())
	CompanionCore.connect_to_core()
	var connection_deadline := Time.get_ticks_msec() + 15000
	while not CompanionCore.is_active() and Time.get_ticks_msec() < connection_deadline:
		await get_tree().create_timer(0.05).timeout
	if not CompanionCore.is_active():
		_finish(2, "Companion Core 连接超时")
		return
	var panel := PANEL_SCENE.instantiate()
	add_child(panel)
	panel.show_panel()
	var load_deadline := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < load_deadline:
		var status := panel.get("_status") as Label
		if is_instance_valid(status) and not status.text.begins_with("正在") and status.text != "等待加载":
			break
		await get_tree().create_timer(0.05).timeout
	var graph_variant = panel.get("_graph")
	if not graph_variant is Dictionary:
		_finish(3, "实时记忆网络没有返回字典")
		return
	var graph: Dictionary = graph_variant
	if graph.is_empty():
		var status := panel.get("_status") as Label
		_finish(4, "实时记忆网络加载失败：%s" % (status.text if is_instance_valid(status) else "未知错误"))
		return
	var nodes_variant = graph.get("nodes", [])
	var canvas := panel.find_child("MemoryGraphCanvas", true, false) as MemoryGraphCanvas
	if nodes_variant is Array and not nodes_variant.is_empty() and is_instance_valid(canvas):
		var nodes: Array = nodes_variant
		nodes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return int(a.get("connection_count", 0)) > int(b.get("connection_count", 0))
		)
		canvas.select_node_by_id(str((nodes[0] as Dictionary).get("id", "")), false)
	for _index in 220:
		await get_tree().process_frame
	var summary_variant = graph.get("summary", {})
	var summary: Dictionary = summary_variant if summary_variant is Dictionary else {}
	var screenshot := get_viewport().get_texture().get_image()
	if screenshot == null or screenshot.is_empty():
		_finish(5, "实时记忆网络截图为空")
		return
	var screenshot_path := "user://memory-network-live-check.png"
	if screenshot.save_png(screenshot_path) != OK:
		_finish(6, "实时记忆网络截图保存失败")
		return
	print("MEMORY_NETWORK_LIVE_CHECK=PASS nodes=%d edges=%d isolated=%d screenshot=%s" % [
		int(summary.get("node_count", 0)),
		int(summary.get("edge_count", 0)),
		int(summary.get("isolated_node_count", 0)),
		ProjectSettings.globalize_path(screenshot_path),
	])
	_finish(0, "")


func _finish(code: int, message: String) -> void:
	if not message.is_empty():
		printerr("MEMORY_NETWORK_LIVE_CHECK failure=", message)
	CompanionCore.disconnect_from_core()
	get_tree().quit(code)
