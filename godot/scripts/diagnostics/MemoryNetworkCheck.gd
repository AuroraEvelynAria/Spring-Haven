extends Node

const PANEL_SCENE := preload("res://scenes/MemoryNetwork/MemoryNetworkPanel.tscn")


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var panel := PANEL_SCENE.instantiate()
	get_tree().root.add_child(panel)
	panel.show()
	await get_tree().process_frame
	var canvas := panel.find_child("MemoryGraphCanvas", true, false) as MemoryGraphCanvas
	if not is_instance_valid(canvas):
		_finish(2, "找不到记忆网络画布")
		return
	var detail_panel := panel.get("_detail_panel") as Control
	if not is_instance_valid(detail_panel) or detail_panel.visible:
		_finish(10, "心织详情卡默认不应显示")
		return
	var opacity_failure := _expect_observation_opacity(panel)
	if not opacity_failure.is_empty():
		_finish(12, opacity_failure)
		return
	var focus_failure := await _expect_narrow_detail_focus()
	if not focus_failure.is_empty():
		_finish(13, focus_failure)
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
	await get_tree().process_frame
	if not detail_panel.visible:
		_finish(11, "选择心织节点后没有显示详情卡")
		return
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
	var screenshot_path := "user://memory-network-check.png"
	if DisplayServer.get_name() == "headless":
		print("MEMORY_NETWORK_CHECK headless: 截图跳过")
	else:
		var screenshot := get_viewport().get_texture().get_image()
		if screenshot == null or screenshot.is_empty():
			_finish(5, "记忆网络画面输出为空")
			return
		if screenshot.get_width() < 640 or screenshot.get_height() < 360:
			_finish(5, "记忆网络画面尺寸异常")
			return
		if screenshot.save_png(screenshot_path) != OK:
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


# 观测台形态:外框可以保留庭院氛围(遮罩半透),但图内容区与详情卡必须实心,
# 否则节点、标签与连线会跟底下的 GameWorld 糊在一起——这正是改坏时截图的样子。
func _expect_observation_opacity(panel: Node) -> String:
	var scrim := panel.get("_background") as ColorRect
	var sheet := panel.get("_sheet") as Control
	var plate := panel.get("_canvas_plate") as Control
	var detail := panel.get("_detail_panel") as Control
	if (
		not is_instance_valid(scrim)
		or not is_instance_valid(sheet)
		or not is_instance_valid(plate)
		or not is_instance_valid(detail)
	):
		return "心织观测台缺少图层结构"
	var plate_alpha := _style_alpha(plate)
	var detail_alpha := _style_alpha(detail)
	var sheet_alpha := _style_alpha(sheet)
	if plate_alpha < 0.95:
		return "图内容区衬底不够实心：%s" % plate_alpha
	if detail_alpha < 0.92:
		return "详情卡衬底不够实心：%s" % detail_alpha
	if sheet_alpha < 0.82:
		return "观测台外框仍然过透：%s" % sheet_alpha
	if scrim.color.a < 0.45 or scrim.color.a > 0.78:
		return "最外层遮罩不再保留庭院氛围：%s" % scrim.color.a
	print("MEMORY_NETWORK_CHECK 观测台不透明度: 遮罩=%s 外框=%s 图衬底=%s 详情卡=%s" % [
		scrim.color.a, sheet_alpha, plate_alpha, detail_alpha
	])
	return ""


func _style_alpha(control: Control) -> float:
	var style := control.get_theme_stylebox("panel")
	if style is StyleBoxFlat:
		return (style as StyleBoxFlat).bg_color.a
	return -1.0


# 窄屏不能在"图谱"和"详情"之间上下堆叠——两块都残缺。必须是二选一聚焦,
# 并且详情聚焦时有一个返回图谱的入口能切回去。
func _expect_narrow_detail_focus() -> String:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(700, 620)
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	get_tree().root.add_child(viewport)
	var panel := PANEL_SCENE.instantiate()
	viewport.add_child(panel)
	panel.show()
	await get_tree().process_frame
	await get_tree().process_frame
	panel.call("_apply_responsive_layout")
	await get_tree().process_frame
	var plate := panel.get("_canvas_plate") as Control
	var detail := panel.get("_detail_panel") as Control
	var back := panel.get("_detail_back_button") as Button
	var canvas := panel.find_child("MemoryGraphCanvas", true, false) as MemoryGraphCanvas
	var message := ""
	if not is_instance_valid(plate) or not plate.visible:
		message = "窄屏未选中节点时应聚焦画布"
	elif is_instance_valid(detail) and detail.visible:
		message = "窄屏未选中节点时不应显示详情卡"
	elif is_instance_valid(back) and back.visible:
		message = "窄屏未选中节点时不应显示返回图谱入口"
	if message.is_empty() and is_instance_valid(canvas):
		canvas.set_graph({
			"nodes": [_node("memory-narrow", "窄屏里的记忆", "ling", 0.7, ["窄屏"])],
			"edges": [],
		})
		canvas.select_node_by_id("memory-narrow", false)
		await get_tree().process_frame
		if is_instance_valid(plate) and plate.visible:
			message = "窄屏选中节点后画布应让位给详情卡"
		elif not is_instance_valid(detail) or not detail.visible:
			message = "窄屏选中节点后没有切到详情聚焦"
		elif not is_instance_valid(back) or not back.visible:
			message = "窄屏详情聚焦缺少返回图谱入口"
		elif not (panel.get("_selected_node_id") as String).is_empty():
			back.pressed.emit()
			await get_tree().process_frame
			if not plate.visible or (is_instance_valid(detail) and detail.visible):
				message = "窄屏返回图谱没有切回画布聚焦"
	panel.free()
	viewport.free()
	if message.is_empty():
		print("MEMORY_NETWORK_CHECK 窄屏聚焦切换: 画布→详情→画布 通过")
	return message


func _finish(code: int, message: String) -> void:
	if not message.is_empty():
		printerr("MEMORY_NETWORK_CHECK failure=", message)
	get_tree().quit(code)
