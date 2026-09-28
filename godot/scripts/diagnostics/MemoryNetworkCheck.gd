extends Node

const PANEL_SCENE := preload("res://scenes/MemoryNetwork/MemoryNetworkPanel.tscn")


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var panel := PANEL_SCENE.instantiate()
	add_child(panel)
	panel.show()
	await get_tree().process_frame
	var canvas := panel.find_child("MemoryGraphCanvas", true, false) as MemoryGraphCanvas
	if not is_instance_valid(canvas):
		_finish(2, "找不到记忆网络画布")
		return
	var graph := {
		"nodes": [
			_node("memory-tea", "雨天的桂花茶", "ling", 0.88, ["桂花热茶", "雨天"]),
			_node("memory-promise", "一起泡茶的约定", "nai", 0.76, ["桂花热茶", "约定"]),
			_node("memory-flower", "餐桌边的栀子花", "*", 0.67, ["栀子花", "餐桌"]),
		],
		"edges": [
			{
				"link_id": "fixture-tea-promise",
				"source": "memory-tea",
				"target": "memory-promise",
				"strength": 0.82,
				"shared_terms": ["桂花热茶"],
				"reasons": ["共享主题：桂花热茶", "来自同一次经历"],
			},
		],
		"summary": {"node_count": 3, "edge_count": 1, "isolated_node_count": 1},
	}
	canvas.set_graph(graph)
	(panel.get("_empty_state") as Label).hide()
	var selected: Array[Dictionary] = []
	canvas.node_selected.connect(func(node: Dictionary): selected.append(node))
	canvas.select_node_by_id("memory-tea", false)
	# 严格历史快照:未来节点不可被程序选择或鼠标命中。
	canvas.set_time_cursor(-1.0)
	var future_node := _node("memory-future", "未来的约定", "ling", 0.6, ["未来"])
	future_node["world_created_at"] = 8.0
	var now_node := _node("memory-now", "此刻的约定", "ling", 0.6, ["此刻"])
	now_node["world_created_at"] = 1.0
	canvas.set_graph({"nodes": [now_node, future_node], "edges": []})
	canvas.set_time_cursor(2.0)
	canvas.select_node_by_id("memory-future", false)
	if canvas.get("_selected_id") == "memory-future":
		_finish(7, "历史快照仍可选择未来节点")
		return
	if canvas.call("is_node_selectable", "memory-future"):
		_finish(8, "历史快照把未来节点标为可交互")
		return
	canvas.set_time_cursor(-1.0)
	canvas.set_graph(graph)
	canvas.select_node_by_id("memory-tea", false)
	for _index in 120:
		await get_tree().process_frame
	if selected.size() < 2 or str(selected.back().get("id", "")) != "memory-tea":
		_finish(3, "节点选择没有产生正确详情事件")
		return
	if canvas.size.x < 300.0 or canvas.size.y < 260.0:
		_finish(4, "记忆网络画布尺寸异常：%s" % canvas.size)
		return
	var screenshot := get_viewport().get_texture().get_image()
	var screenshot_path := "user://memory-network-check.png"
	if screenshot == null or screenshot.is_empty():
		if DisplayServer.get_name() != "headless":
			_finish(5, "记忆网络画面输出为空")
			return
		print("MEMORY_NETWORK_CHECK headless: 截图跳过")
	elif screenshot.get_width() < 640 or screenshot.get_height() < 360:
		_finish(5, "记忆网络画面尺寸异常")
		return
	elif screenshot.save_png(screenshot_path) != OK:
		_finish(6, "无法保存记忆网络诊断截图")
		return
	print("MEMORY_NETWORK_CHECK=PASS nodes=3 edges=1 screenshot=%s" % ProjectSettings.globalize_path(screenshot_path))
	_finish(0, "")


func _node(
	id: String,
	title: String,
	scope: String,
	importance: float,
	keywords: Array[String]
) -> Dictionary:
	return {
		"id": id,
		"memory_id": id,
		"title": title,
		"content": "%s的完整记忆内容。" % title,
		"scope_role_id": scope,
		"kind": "episodic",
		"importance": importance,
		"confidence": 1.0,
		"valence": 0.4,
		"keywords": keywords,
		"recall_count": 2,
		"created_at": int(Time.get_unix_time_from_system()),
		"updated_at": int(Time.get_unix_time_from_system()),
		"enabled": true,
	}


func _finish(code: int, message: String) -> void:
	if not message.is_empty():
		printerr("MEMORY_NETWORK_CHECK failure=", message)
	get_tree().quit(code)
