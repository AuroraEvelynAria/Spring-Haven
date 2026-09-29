extends SceneTree

## 心织图谱外观探针。
##
## 用接近真实存档规模的合成图（53 主题 / 9 实体 / 79 联系）走**面板的真实落图路径**
## （_apply_graph_payload），渲染一张实拍图并打印可量化的形态指标：
##   * 包围盒比例应接近画布长宽比，而不是被压成一条；
##   * on_edge_ratio（落在包围盒四边窄带内的节点比例）偏高即"贴墙排成矩形"；
##   * 填充率（节点云占画布的比例）两个方向都应接近 0.8。
##
## 用法:
##   godot --path godot --script res://scripts/diagnostics/GraphLayoutProbe.gd

const PANEL_SCENE_PATH := "res://scenes/MemoryNetwork/MemoryNetworkPanel.tscn"
const MEMORY_COUNT := 53
const ENTITY_COUNT := 9
const VIEWPORT_SIZE := Vector2i(1280, 720)
const SETTLE_FRAMES := 1200


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	# 必须运行时 load：本脚本作为主循环运行，preload 会在编译期解析面板脚本里的
	# autoload 标识（CompanionCore 等），而那时 autoload 还没注册。
	var panel_scene := load(PANEL_SCENE_PATH) as PackedScene
	if panel_scene == null:
		printerr("GRAPH_LAYOUT_PROBE 无法加载面板场景")
		quit(1)
		return
	var headless := DisplayServer.get_name() == "headless"
	var viewport := SubViewport.new()
	viewport.size = VIEWPORT_SIZE
	viewport.render_target_update_mode = (
		SubViewport.UPDATE_DISABLED if headless else SubViewport.UPDATE_ALWAYS
	)
	root.add_child(viewport)
	# 注入真实主题再实例化面板:--script 模式下 autoload 仍在树里,只是编译期
	# 解析不到标识符,运行时按节点取是安全的。不注入的话截图是 Godot 灰底
	# 默认主题,和玩家看到的颜色完全是两回事,可读性判断会失真。
	var theme_mgr := root.get_node_or_null("ThemeMgr")
	if theme_mgr != null and theme_mgr.has_method("apply_theme"):
		theme_mgr.call("apply_theme", "amber")
	var panel := panel_scene.instantiate()
	viewport.add_child(panel)
	panel.show()
	await process_frame
	await process_frame
	var canvas := panel.find_child("MemoryGraphCanvas", true, false) as MemoryGraphCanvas
	if not is_instance_valid(canvas):
		printerr("GRAPH_LAYOUT_PROBE 找不到画布")
		quit(1)
		return
	var payload := _build_payload()
	panel.call("_apply_graph_payload", payload)
	var empty_state := panel.get("_empty_state") as Control
	if is_instance_valid(empty_state):
		empty_state.hide()
	# 等力导向冷却沉降，并以「自动适配已执行」为真正的结束条件 ——
	# 固定帧数会在还没沉降完时截图，拍到的是一张被裁掉上下两端的图。
	for frame in SETTLE_FRAMES:
		await process_frame
		if frame > 60 and not bool(canvas.get("_auto_fit_pending")):
			break
	var failure := _report(canvas, payload)
	if not headless:
		# 截图前选中「最新」的一条记忆:实拍里同时验收详情卡、统计条、
		# 遗忘曲线和「选中锚定」的邻域高亮 —— 可读性要看的就是这个状态
		var probe_memory: Dictionary = {}
		for node in canvas.get("_nodes"):
			if str((node as Dictionary).get("node_type", "memory")) != "memory":
				continue
			if probe_memory.is_empty() or float(node.get("world_updated_at", 0.0)) > float(probe_memory.get("world_updated_at", 0.0)):
				probe_memory = node
		if not probe_memory.is_empty():
			canvas.select_node_by_id(str(probe_memory.get("id", "")), false)
			for _settle_index in 40:
				await process_frame
		var image := viewport.get_texture().get_image()
		if image != null and not image.is_empty():
			var path := "user://graph_layout_probe.png"
			image.save_png(path)
			print("GRAPH_LAYOUT_PROBE 截图 %s" % ProjectSettings.globalize_path(path))
	panel.free()
	viewport.free()
	if not failure.is_empty():
		printerr("GRAPH_LAYOUT_PROBE failure=", failure)
		quit(1)
		return
	quit(0)


# 断言把「打开就是一张方框」这个已发生的缺陷钉住：
#   * 云团要铺满画布（两个方向的填充率都不低于 0.55）；
#   * 落在包围盒四边窄带内的节点不能超过三分之一（贴墙排成矩形时会到 0.74）；
#   * 云团形状要跟随画布长宽比，而不是被压扁。
func _report(canvas: MemoryGraphCanvas, payload: Dictionary) -> String:
	var edges: Array = canvas.get("_edges")
	var primary = canvas.get("_primary_edge_ids")
	print("GRAPH_LAYOUT_PROBE 边: 载荷=%d 入账=%d 主边集=%d 默认可见=%d 阈值=%.2f" % [
		(payload["edges"] as Array).size(),
		edges.size(),
		(primary as Dictionary).size(),
		int(canvas.call("get_visible_edge_count")),
		float(canvas.get("_min_strength")),
	])
	var extent := _measure_extent(canvas)
	if extent.is_empty():
		return "探针无节点坐标"
	var canvas_size: Vector2 = canvas.size
	var zoom := float(canvas.get("_zoom"))
	var filled := Vector2(
		extent["span"].x * zoom / canvas_size.x,
		extent["span"].y * zoom / canvas_size.y
	)
	print("GRAPH_LAYOUT_PROBE 形态: 包围盒=%s 比例=%.2f 贴边比例=%.2f" % [
		extent["span"], extent["ratio"], extent["on_edge_ratio"]
	])
	print("GRAPH_LAYOUT_PROBE 构图: zoom=%.3f 画布=%s 填充率 宽=%.2f 高=%.2f" % [
		zoom, canvas_size, filled.x, filled.y
	])
	# 默认视角下大部分节点必须带着名字(Obsidian 式):一张无名点云什么
	# 都读不出来 —— 这个缺陷曾经由 LABEL_ZOOM(1.2) 高于自适应上限(1.15)
	# 造成,打开永远是匿名星座。碰撞避让会隐藏少数重叠标签,留 45% 余量。
	var labeled := int(canvas.call("debug_label_count"))
	var node_total := (canvas.get("_nodes") as Array).size()
	print("GRAPH_LAYOUT_PROBE 标签: %d / %d zoom=%.3f" % [labeled, node_total, zoom])
	if node_total > 0 and float(labeled) < float(node_total) * 0.55:
		return "默认视角下有名字的节点太少：%d / %d —— 图读不出来" % [labeled, node_total]
	var pane_aspect := canvas_size.x / maxf(1.0, canvas_size.y)
	if filled.x < 0.55 or filled.y < 0.55:
		return "节点云没有铺满画布：填充率 %.2f x %.2f" % [filled.x, filled.y]
	if float(extent["on_edge_ratio"]) > 0.34:
		return "节点被压成矩形：贴边比例 %.2f" % extent["on_edge_ratio"]
	var ratio := float(extent["ratio"])
	if ratio < pane_aspect * 0.6 or ratio > pane_aspect * 1.6:
		return "云团形状没有跟随画布长宽比：%.2f 对 %.2f" % [ratio, pane_aspect]
	return ""


# 包围盒与"贴边程度"：大量节点落在四条边附近的窄带里，就是被约束压成了矩形。
func _measure_extent(canvas: MemoryGraphCanvas) -> Dictionary:
	var positions: Dictionary = canvas.get("_positions")
	if positions.is_empty():
		return {}
	var min_point := Vector2.INF
	var max_point := -Vector2.INF
	for value in positions.values():
		var point: Vector2 = value
		min_point.x = minf(min_point.x, point.x)
		min_point.y = minf(min_point.y, point.y)
		max_point.x = maxf(max_point.x, point.x)
		max_point.y = maxf(max_point.y, point.y)
	var span := max_point - min_point
	var edge_band := 26.0
	var on_edge := 0
	for value in positions.values():
		var point: Vector2 = value
		if (
			point.x - min_point.x < edge_band
			or max_point.x - point.x < edge_band
			or point.y - min_point.y < edge_band
			or max_point.y - point.y < edge_band
		):
			on_edge += 1
	return {
		"span": span,
		"ratio": span.x / maxf(1.0, span.y),
		"on_edge_ratio": float(on_edge) / float(maxi(1, positions.size())),
	}


func _memory_node(index: int) -> Dictionary:
	var node_id := "memory-%02d" % index
	return {
		"node_id": node_id,
		"memory_id": node_id,
		"node_type": "memory",
		"title": "记忆主题 %d" % (index + 1),
		"summary": "第 %d 条记忆的正文内容，用来占位以便观察标签与节点尺寸。" % (index + 1),
		"scope_role_id": ["*", "ling", "nai"][index % 3],
		"kind": "episodic",
		"importance": 0.4 + float(index % 7) * 0.08,
		"keywords": ["主题%d" % (index % 11)],
		"recall_count": index % 5,
		"half_life_days": 6.0 + float(index % 7) * 4.0,
		"intrinsic": 1.0,
		"world_created_at": float(index) * 1.7,
		"world_updated_at": float(index) * 1.7,
		"created_at": 1_700_000_000 + index * 3600,
		"updated_at": 1_700_000_000 + index * 3600,
		"enabled": true,
	}


func _entity_node(index: int) -> Dictionary:
	return {
		"node_id": "entity-%02d" % index,
		"node_type": "entity",
		"name": "实体 %d" % (index + 1),
		"kind": ["person", "object", "place", "event", "concept"][index % 5],
		"aliases": [],
		"claim_count": 2 + index % 4,
		"world_created_at": float(index) * 3.0,
	}


func _build_payload() -> Dictionary:
	var nodes: Array = []
	var ids: Array = []
	for index in MEMORY_COUNT:
		ids.append("memory-%02d" % index)
		nodes.append(_memory_node(index))
	var entity_ids: Array = []
	for index in ENTITY_COUNT:
		entity_ids.append("entity-%02d" % index)
		nodes.append(_entity_node(index))
	var edges: Array = []
	# 关联边：6 个枢纽各带一串卫星
	for hub in 6:
		for offset in range(1, 9):
			var satellite := (hub * 9 + offset) % MEMORY_COUNT
			if satellite == hub:
				continue
			edges.append({
				"link_id": "assoc-%d-%d" % [hub, satellite],
				"src": ids[hub],
				"dst": ids[satellite],
				"link_type": "association",
				"link_strength": 0.62 + float(offset % 3) * 0.08,
				"reason": "共享主题",
			})
	for index in range(0, MEMORY_COUNT - 4, 4):
		edges.append({
			"link_id": "chain-%d" % index,
			"src": ids[index],
			"dst": ids[index + 3],
			"link_type": "association",
			"link_strength": 0.58,
			"reason": "",
		})
	# 主张边：实体挂在若干主题上，形成真实的「实体星座」
	for index in ENTITY_COUNT:
		for offset in 2:
			var owner := (index * 5 + offset * 7) % MEMORY_COUNT
			edges.append({
				"link_id": "claim-%d-%d" % [index, offset],
				"src": entity_ids[index],
				"dst": ids[owner],
				"link_type": "claim",
				"predicate": "关联",
				"object_text": "实体 %d" % (index + 1),
				"link_strength": 0.7,
				"reason": "",
				"world_from": float(index) * 3.0,
				"world_to": null,
			})
	return {
		"nodes": nodes,
		"edges": edges,
		"world_now": 120.0,
		"world_range": {"earliest": 0.0, "latest": 120.0},
		"memory_node_count": MEMORY_COUNT,
		"entity_node_count": ENTITY_COUNT,
		"node_count": nodes.size(),
	}
