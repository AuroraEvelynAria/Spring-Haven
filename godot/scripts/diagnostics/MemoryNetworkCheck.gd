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
	var label_failure := _expect_entity_labels(canvas)
	if not label_failure.is_empty():
		_finish(14, label_failure)
		return
	var rollback_failure := await _expect_cursor_rollback_clears_details(canvas, panel)
	if not rollback_failure.is_empty():
		_finish(15, rollback_failure)
		return
	var pin_failure := await _expect_pin_cursor_keeps_its_day(canvas, panel)
	if not pin_failure.is_empty():
		_finish(16, pin_failure)
		return
	var pan_failure := await _expect_blank_press_releases_pan()
	if not pan_failure.is_empty():
		_finish(17, pan_failure)
		return
	var hover_failure := await _expect_hover_clears_on_mouse_exit()
	if not hover_failure.is_empty():
		_finish(18, hover_failure)
		return
	var contract_failure := await _expect_edge_contract_mapping()
	if not contract_failure.is_empty():
		_finish(19, contract_failure)
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


# 实体节点必须也有标签。标签块曾经被多缩进一层落进记忆分支,实体整类不再
# 绘制名字,而"不画了"只能靠人眼看截图发现。
func _expect_entity_labels(canvas: MemoryGraphCanvas) -> String:
	var entity := {
		"id": "entity-master",
		"node_type": "entity",
		"name": "主人",
		"kind": "person",
		"claim_count": 2,
		"world_created_at": 1.0,
	}
	var entity_label := canvas.label_text_for(entity)
	if entity_label.is_empty():
		return "实体节点没有标签文案"
	if entity_label != "主人":
		return "实体标签没有使用实体名：%s" % entity_label
	var memory := _node("memory-label", "餐桌边的栀子花", "ling", 0.7, ["栀子花"])
	var memory_label := canvas.label_text_for(memory)
	if memory_label != "餐桌边的栀子花":
		return "记忆标签文案异常：%s" % memory_label
	print("MEMORY_NETWORK_CHECK 标签: 实体=%s 记忆=%s" % [entity_label, memory_label])
	return ""


# 游标拨回过去之后,详情卡必须跟着失效 —— 画布只是把它淡成幽灵,
# 详情卡归面板管,不发信号的话它会继续展示未来节点的标题与正文。
func _expect_cursor_rollback_clears_details(
	canvas: MemoryGraphCanvas, panel: Node
) -> String:
	var node := _node("memory-rollback", "会被拨回过去的记忆", "ling", 0.7, ["回拨"])
	node["world_created_at"] = 9.0
	canvas.set_graph({"nodes": [node], "edges": []})
	canvas.set_time_cursor(-1.0)
	canvas.select_node_by_id("memory-rollback", false)
	await get_tree().process_frame
	var detail := panel.get("_detail_panel") as Control
	if not is_instance_valid(detail) or not detail.visible:
		return "选中记忆后详情卡没有显示"
	canvas.set_time_cursor(4.0)
	await get_tree().process_frame
	if not (panel.get("_selected_node_id") as String).is_empty():
		return "游标拨回后仍记录着未来节点"
	if detail.visible:
		return "游标拨回后详情卡仍显示未来节点的内容"
	print("MEMORY_NETWORK_CHECK 游标回拨: 详情卡已清空")
	return ""


# 点章节钉必须把游标拨到"那一天结束",而不是当天 0 点 —— 幽灵判据是
# created >= cursor,拨到 0 点会把这一整天(包括这根钉自己)全变成幽灵。
func _expect_pin_cursor_keeps_its_day(canvas: MemoryGraphCanvas, panel: Node) -> String:
	var slider := panel.get("_time_slider") as HSlider
	if not is_instance_valid(slider):
		return "章节钉检查缺少时间滑杆"
	slider.min_value = 0.0
	slider.max_value = 20.0
	var pin_node := _node("memory-pin", "夜织出来的章节", "ling", 0.6, ["夜织"])
	pin_node["source"] = "consolidation_nightly"
	pin_node["world_created_at"] = 5.6
	canvas.set_graph({"nodes": [pin_node], "edges": []})
	canvas.set_time_cursor(-1.0)
	# 章节钉读的是面板自己那份图,不是画布那份 —— 两边都要给。
	panel.set("_graph", {"nodes": [pin_node], "edges": [], "summary": {}})
	var pins: Array = panel.call("_collect_chapter_pins")
	if pins.is_empty():
		return "夜织记忆没有生成章节钉"
	var time_pins := panel.get("_time_pins") as MemoryTimePins
	if not is_instance_valid(time_pins):
		return "章节钉检查缺少时间钉条"
	time_pins.set_range(0.0, 20.0)
	time_pins.set_pins(pins)
	panel.call("_on_pin_selected", float((pins[0] as Dictionary).get("cursor", 0.0)))
	await get_tree().process_frame
	if not canvas.is_node_selectable("memory-pin"):
		return "点击章节钉把它自己那一天的事件变成了幽灵"
	print("MEMORY_NETWORK_CHECK 章节钉: 落点游标=%s 事件=%s" % [
		slider.value, canvas.is_node_selectable("memory-pin")
	])
	return ""


# API 发的是 src/dst，画布读的是 source/target。这层映射一旦错位，图会安静地
# 一条线都不画（不是报错，是"看起来没有关系"）—— 属于最该被断言钉住的契约。
func _expect_edge_contract_mapping() -> String:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(900, 640)
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	get_tree().root.add_child(viewport)
	var panel := PANEL_SCENE.instantiate()
	viewport.add_child(panel)
	panel.show()
	await get_tree().process_frame
	await get_tree().process_frame
	panel.call("_apply_graph_payload", {
		"nodes": [
			{
				"node_id": "memory-a", "memory_id": "memory-a", "node_type": "memory",
				"title": "契约甲", "summary": "甲", "scope_role_id": "ling",
				"kind": "episodic", "importance": 0.6, "world_created_at": 1.0,
			},
			{
				"node_id": "memory-b", "memory_id": "memory-b", "node_type": "memory",
				"title": "契约乙", "summary": "乙", "scope_role_id": "ling",
				"kind": "episodic", "importance": 0.6, "world_created_at": 2.0,
			},
		],
		"edges": [{
			"link_id": "contract-edge",
			"src": "memory-a",
			"dst": "memory-b",
			"link_type": "association",
			"link_strength": 0.8,
			"reason": "契约",
		}],
		"world_now": 10.0,
		"world_range": {"earliest": 0.0, "latest": 10.0},
		"memory_node_count": 2,
	})
	await get_tree().process_frame
	var canvas := panel.find_child("MemoryGraphCanvas", true, false) as MemoryGraphCanvas
	var message := ""
	if not is_instance_valid(canvas):
		message = "契约检查找不到画布"
	else:
		var edges: Array = canvas.get("_edges")
		if edges.is_empty():
			message = "src/dst 没有映射成 source/target：画布一条边都没有"
		else:
			var edge: Dictionary = edges[0]
			if str(edge.get("source", "")) != "memory-a" or str(edge.get("target", "")) != "memory-b":
				message = "src/dst 映射结果不对：source=%s target=%s" % [
					edge.get("source", ""), edge.get("target", "")
				]
			elif not is_equal_approx(float(edge.get("strength", 0.0)), 0.8):
				message = "link_strength 没有映射成 strength：%s" % edge.get("strength")
			elif not (edge.get("reasons") as Array).has("契约"):
				message = "reason 没有映射成 reasons 列表"
	panel.free()
	viewport.free()
	if message.is_empty():
		print("MEMORY_NETWORK_CHECK 契约映射: src/dst→source/target、link_strength→strength、reason→reasons 通过")
	return message


func _finish(code: int, message: String) -> void:
	if not message.is_empty():
		printerr("MEMORY_NETWORK_CHECK failure=", message)
	get_tree().quit(code)


func _mouse_button(position: Vector2, pressed: bool) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = position
	event.global_position = position
	return event


func _mouse_motion(position: Vector2, relative: Vector2) -> InputEventMouseMotion:
	var event := InputEventMouseMotion.new()
	event.position = position
	event.global_position = position
	event.relative = relative
	return event


# 在画布**局部**坐标里扫出第一个命中结果等于 want（空串 = 要空白）的位置。
# 命中测试 `_hit_test` 吃的是局部坐标，而 `push_input` 要视口全局坐标 ——
# 两者混用会让合成事件"看着打中了其实没打中"，务必分开算。
func _find_local_spot(canvas: MemoryGraphCanvas, want: String, step := 8.0) -> Vector2:
	var y := step
	while y < canvas.size.y:
		var x := step
		while x < canvas.size.x:
			if str(canvas.call("_hit_test", Vector2(x, y))) == want:
				return Vector2(x, y)
			x += step
		y += step
	return Vector2(-1.0, -1.0)


# 在图的空白处按下再松手，必须结束平移态。
#
# 旧代码把 `_panning = false` 写在 `if _dragged_id != "":` 里面，而"空白处按下"
# 这条路径只设 `_panning = true`、不会设 `_dragged_id` —— 于是松手时那个 if 不成立，
# `_panning` 永远停在 true。此后每帧按鼠标位移平移画布，用户看到的是"鼠标一进图里
# 就甩不掉，图永远跟着走"。4ea1028 / 6d473e8 / 场景式分支三版都有此缺陷。
func _expect_blank_press_releases_pan() -> String:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(900, 640)
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	get_tree().root.add_child(viewport)
	var panel := PANEL_SCENE.instantiate()
	viewport.add_child(panel)
	panel.show()
	await get_tree().process_frame
	await get_tree().process_frame
	var canvas := panel.find_child("MemoryGraphCanvas", true, false) as MemoryGraphCanvas
	if not is_instance_valid(canvas):
		panel.free()
		viewport.free()
		return "空白处平移检查找不到画布"
	canvas.set_graph({
		"nodes": [_node("memory-pan", "空白处平移测试", "ling", 0.6, ["平移"])],
		"edges": [],
	})
	canvas.set_time_cursor(-1.0)
	await get_tree().process_frame
	await get_tree().process_frame
	# 画布右下角离唯一节点足够远，必定是空白（局部坐标，推送时再加画布原点）
	var local_blank := Vector2(canvas.size.x - 6.0, canvas.size.y - 6.0)
	if not str(canvas.call("_hit_test", local_blank)).is_empty():
		return "空白处平移检查选到的位置其实命中了节点"
	var global_blank := canvas.get_global_rect().position + local_blank
	viewport.push_input(_mouse_button(global_blank, true), true)
	viewport.push_input(_mouse_button(global_blank, false), true)
	var panning_after_release := bool(canvas.get("_panning"))
	var pan_before: Vector2 = canvas.get("_pan")
	viewport.push_input(
		_mouse_motion(global_blank + Vector2(48.0, 32.0), Vector2(48.0, 32.0)), true
	)
	var pan_after: Vector2 = canvas.get("_pan")
	panel.free()
	viewport.free()
	if panning_after_release:
		return "空白处松手后仍停留在平移状态（_panning 没有复位）"
	if not pan_after.is_equal_approx(pan_before):
		return "空白处松手后画面仍被鼠标拖动：%s → %s" % [pan_before, pan_after]
	print("MEMORY_NETWORK_CHECK 空白处平移: 松手后 _panning=%s 位移=%s" % [
		panning_after_release, pan_after - pan_before
	])
	return ""


# 鼠标离开画布后悬停与聚焦必须清掉。聚焦态会让整图"除邻域外全部变暗"，
# 不清的话鼠标早就离开图了，图却一直维持那个样子 —— 和"平移甩不掉"是同一种
# "卡住了"的体感。
func _expect_hover_clears_on_mouse_exit() -> String:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(900, 640)
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	get_tree().root.add_child(viewport)
	var panel := PANEL_SCENE.instantiate()
	viewport.add_child(panel)
	panel.show()
	await get_tree().process_frame
	await get_tree().process_frame
	var canvas := panel.find_child("MemoryGraphCanvas", true, false) as MemoryGraphCanvas
	if not is_instance_valid(canvas):
		panel.free()
		viewport.free()
		return "悬停清理检查找不到画布"
	canvas.set_graph({
		"nodes": [_node("memory-hover", "悬停测试", "ling", 0.8, ["悬停"])],
		"edges": [],
	})
	canvas.set_time_cursor(-1.0)
	await get_tree().process_frame
	await get_tree().process_frame
	var positions: Dictionary = canvas.get("_positions")
	if not positions.has("memory-hover"):
		panel.free()
		viewport.free()
		return "悬停清理检查找不到节点坐标"
	# 不靠"算出来的屏幕坐标一定命中"这种假设，直接扫出真正能命中节点的局部位置。
	# 位移事件随后用局部坐标直接调用 _gui_input：悬停路径不会走到 accept_event()
	# （既没拖节点也没平移），直接调用是安全的；而经 push_input 转发时目标控件由
	# GUI 命中决定，实测会因坐标语义差异打空。本断言验的是"处理函数在鼠标离开后
	# 是否清态"，直接调用正是它的契约。
	var hit_position := _find_local_spot(canvas, "memory-hover")
	if hit_position.x < 0.0:
		panel.free()
		viewport.free()
		return "整张画布里找不到能命中节点的位置（节点可能被布局挤到视口外）"
	canvas.call("_gui_input", _mouse_motion(hit_position, Vector2(1.0, 0.0)))
	var hovered_after_move := str(canvas.get("_hovered_id"))
	var focus_after_move := str(canvas.get("_focus_id"))
	canvas.notification(Control.NOTIFICATION_MOUSE_EXIT)
	var hovered_after_exit := str(canvas.get("_hovered_id"))
	var focus_after_exit := str(canvas.get("_focus_id"))
	panel.free()
	viewport.free()
	if hovered_after_move != "memory-hover":
		return "鼠标移到节点上没有被识别为悬停：%s @ %s" % [
			hovered_after_move, hit_position
		]
	if focus_after_move != "memory-hover":
		return "悬停没有聚焦到该节点：%s" % focus_after_move
	if hovered_after_exit != "" or focus_after_exit != "":
		return "鼠标离开画布后悬停/聚焦没有清掉：hovered=%s focus=%s" % [
			hovered_after_exit, focus_after_exit
		]
	print("MEMORY_NETWORK_CHECK 离开画布: 悬停与聚焦已清空（命中点 %s）" % hit_position)
	return ""
