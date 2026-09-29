extends Node

const GAME_WORLD_SCENE := preload("res://scenes/GameWorld/GameWorld.tscn")
const RUNTIME_TUNING := preload("res://scripts/domain/DeveloperRuntimeTuning.gd")

func _is_headless() -> bool:
	return DisplayServer.get_name() == "headless"


func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	Global.save_id = "diagnostic-ui-render"
	Global.current_character = "ling"
	Global.stats_by_role = Global.call("_normalize_stats_by_role", {})
	Global.conversation_history = [{
		"id": "seed",
		"sender": "ai",
		"role": "ling",
		"text": "今天的阳光落在餐桌边，绿植看起来很精神。",
		"status": "sent",
		"event_type": "chat",
		"created_at": int(Time.get_unix_time_from_system()),
	}, {
		"id": "ambient-seed",
		"sender": "ai",
		"role": "nai",
		"target_role": "ling",
		"text": "小玲姐姐，等会儿一起去看看窗边的花吧。",
		"status": "sent",
		"kind": "ambient_dialogue",
		"event_type": "chat",
		"created_at": int(Time.get_unix_time_from_system()),
	}]
	Global.applied_local_effect_ids = []
	Global.full_stat_milestones = {}
	Global.life_runtime = Global.call("_normalize_life_runtime", {})
	Global.state_loaded = true
	var world := GAME_WORLD_SCENE.instantiate()
	world.set("_suppress_exit_persistence", true)
	get_tree().root.add_child(world)
	await get_tree().process_frame
	await get_tree().process_frame
	world.set("_pending_roles", {
		"diagnostic-wait": {"role": "nai", "history_id": "seed"},
	})
	world.set("_network_waiting", true)
	world.call("_add_waiting_message", "diagnostic-wait", "nai")
	world.call("_refresh_interaction_state")
	for _frame in 12:
		await get_tree().process_frame

	var failures: Array[String] = []
	_check_developer_reply_tuning(world, failures)
	await _expect_scene_layout_matrix(failures)
	await _expect_short_history_shrinks(failures)
	var send_button := world.get("_send_button") as Button
	var chat_input := world.get("_chat_input") as LineEdit
	var ling_button := world.get("_ling_button") as Button
	var thinking_strip := world.get("_thinking_strip") as ColorRect
	var thinking_material := world.get("_thinking_strip_material") as ShaderMaterial
	var log_label := world.get("_log_label") as Label
	var message_views: Dictionary = world.get("_message_views")
	var sidebar := world.get("_sidebar") as ScrollContainer
	var portrait_rig := world.get("_portrait_rig") as Control
	var utility_rail := world.get("_utility_rail") as HBoxContainer
	var chat_area := world.get("_chat_area") as VBoxContainer
	var viewport_rect := Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size)
	if not is_instance_valid(chat_area) or not chat_area.is_inside_tree() or not viewport_rect.encloses(chat_area.get_global_rect()):
		failures.append("视觉小说式对话层没有完整显示在视口内")
	if not is_instance_valid(chat_input) or not chat_input.is_inside_tree() or not viewport_rect.encloses(chat_input.get_global_rect()):
		failures.append("对话输入框没有完整显示在视口内")
	if not is_instance_valid(utility_rail) or not utility_rail.is_inside_tree() or utility_rail.get_global_rect().end.x > viewport_rect.end.x - 12.0:
		failures.append("工具栏右侧入口被视口边缘裁切")
	if (
		viewport_rect.size.x > 940.0
		and is_instance_valid(chat_area)
		and is_instance_valid(portrait_rig)
		and chat_area.get_global_rect().intersects(portrait_rig.get_global_rect())
	):
		failures.append("宽屏对话阅读区与角色舞台重叠")
	chat_input.text = "输入光标位置测试"
	chat_input.caret_column = 4
	await get_tree().process_frame
	var widgets: Dictionary = world.get("_stat_widgets")
	if send_button.disabled or ling_button.disabled or not chat_input.editable:
		failures.append(
			"等待回复时交互控件被禁用 send=%s ling=%s editable=%s typewriter=%s intro=%s" % [
				send_button.disabled,
				ling_button.disabled,
				chat_input.editable,
				bool(world.get("_typewriter_active")),
				bool(world.get("_intro_active")),
			]
		)
	if not is_instance_valid(thinking_strip) or not thinking_strip.visible:
		failures.append("小奈思考时没有显示独立渐变光带")
	var expected_thinking_colors: Array = world.call(
		"_thinking_colors", ThemeMgr.get_current_theme_data()
	)
	if (
		not is_instance_valid(thinking_material)
		or expected_thinking_colors.size() != 2
		or not (thinking_material.get_shader_parameter("color_a") as Color).is_equal_approx(
			expected_thinking_colors[0] as Color
		)
		or not (thinking_material.get_shader_parameter("color_b") as Color).is_equal_approx(
			expected_thinking_colors[1] as Color
		)
	):
		failures.append("思考光带没有跟随当前主题配色")
	if not send_button.modulate.is_equal_approx(Color.WHITE):
		failures.append("思考状态仍然突兀染色发送按钮")
	if chat_input.get_theme_constant("caret_width") < 2:
		failures.append("输入框插入光标宽度不足")
	if chat_input.get_theme_color("caret_color").a < 0.95:
		failures.append("输入框插入光标颜色不可见")
	if chat_input.caret_blink or chat_input.caret_column != 4:
		failures.append("输入框插入光标不能稳定指示当前位置")
	if (
		not is_instance_valid(log_label)
		or log_label.get_theme_color("font_color").a < 0.90
		or log_label.modulate.a < 0.89
	):
		failures.append("左下角提示文字对比度不足")
	if _has_core_client_log_window(world):
		failures.append("游戏内 CompanionCore 日志窗口仍然存在")
	var ambient_view: Dictionary = message_views.get("ambient-seed", {})
	var ambient_meta := ambient_view.get("meta") as Label
	if not is_instance_valid(ambient_meta) or "小奈 →" not in ambient_meta.text or "小玲" not in ambient_meta.text:
		failures.append("后台互聊消息没有显示说话者和收件人")
	if sidebar.visible:
		failures.append("状态抽屉默认不应常驻显示")
	var status_toggle := world.get("_status_toggle_button") as Button
	if not is_instance_valid(status_toggle):
		failures.append("状态抽屉入口未创建")
	else:
		status_toggle.pressed.emit()
		await get_tree().process_frame
		if not sidebar.visible or sidebar.size.x < 260.0:
			failures.append("状态抽屉打开后尺寸异常")
		status_toggle.pressed.emit()
		await get_tree().process_frame
		if sidebar.visible:
			failures.append("状态抽屉关闭失败")
	_expect_modal_layer(world, failures)
	await _expect_overlay_covers_world(world, failures)
	_expect_reduced_motion(world, failures)
	if not is_instance_valid(portrait_rig):
		failures.append("角色表现层未创建")
	else:
		var portrait_summary = portrait_rig.call("get_manifest_summary")
		if not portrait_summary is Dictionary or str((portrait_summary as Dictionary).get("role_id", "")) != "ling":
			failures.append("角色表现层没有跟随当前选择角色")
		portrait_rig.call("set_thinking", true)
		if str(portrait_rig.call("get_expression")) != "thinking":
			failures.append("角色表现层没有响应思考状态")
		portrait_rig.call("set_thinking", false)
		portrait_rig.call("speak", "今天见到你很开心。", 0.5)
	if widgets.has("arousal") or widgets.has("climax") or not widgets.has("fertility") or not widgets.has("implantation"):
		failures.append("亲密字段默认显示规则错误")
	if widgets.has("urine_sexual"):
		failures.append("旧亲密尿液字段仍在界面显示")
	var sidebar_content := world.get("_sidebar_content") as VBoxContainer
	if not is_instance_valid(sidebar_content) or sidebar_content.get_node_or_null("MenstrualCycleCard") == null:
		failures.append("生理周期卡片未显示")
	if not is_instance_valid(sidebar_content) or sidebar_content.get_node_or_null("LifeStatusCard") == null:
		failures.append("实时生活状态卡片未显示")
	if widgets.has("fertility"):
		var fertility_label := (widgets.fertility as Dictionary).get("value_label") as Label
		if not is_instance_valid(fertility_label) or "%" in fertility_label.text:
			failures.append("内膜容受性仍显示伪精确百分比")
	if widgets.has("implantation"):
		var implantation_label := (widgets.implantation as Dictionary).get("value_label") as Label
		if not is_instance_valid(implantation_label) or "%" in implantation_label.text:
			failures.append("服药后着床倾向仍显示伪精确百分比")

	var screenshot_path := "user://gameworld_waiting_ui.png"
	if _is_headless():
		print("GAMEWORLD_UI_RENDER_CHECK headless: 截图跳过")
	else:
		var image := get_viewport().get_texture().get_image()
		if image == null or image.is_empty() or image.save_png(screenshot_path) != OK:
			failures.append("UI 截图保存失败")

	var settings_panel := world.get("_settings") as Control
	if not is_instance_valid(settings_panel):
		failures.append("设置面板未创建")
	else:
		settings_panel.call("show_panel")
		settings_panel.call("_switch_settings_category", "advanced")
		for _frame in 8:
			await get_tree().process_frame
		var advanced: Object = settings_panel.get("_advanced")
		var maintenance_backup_list := advanced.get("_maintenance_backup_list") as VBoxContainer
		var maintenance_backup_status := advanced.get("_maintenance_backup_status") as Label
		if not is_instance_valid(maintenance_backup_list) or not is_instance_valid(maintenance_backup_status):
			failures.append("备份查看与校验入口未创建")
		settings_panel.call("_switch_settings_category", "life")
		for _frame in 8:
			await get_tree().process_frame
		var ambient_controls: Dictionary = (settings_panel.get("_advanced") as Object).get("_ambient_controls")
		for key in [
			"enabled", "idle_minutes", "cooldown_min_minutes", "cooldown_max_minutes",
			"turns_min", "turns_max", "notifications_enabled", "memory_enabled"
		]:
			if not ambient_controls.has(key) or not is_instance_valid(ambient_controls[key]):
				failures.append("后台生活设置缺少控件：%s" % key)
		var ambient_status := (settings_panel.get("_advanced") as Object).get("_ambient_status") as Label
		if not is_instance_valid(ambient_status) or ambient_status.text != "尚未修改":
			failures.append("后台生活设置状态指示器异常")
		settings_panel.call("_switch_settings_category", "advanced")
		settings_panel.call("_switch_settings_subcategory", "runtime")
		for _frame in 4:
			await get_tree().process_frame
		var runtime_controls: Dictionary = (settings_panel.get("_advanced") as Object).get("_runtime_controls")
		for key_variant in RUNTIME_TUNING.SPECS:
			var key := str(key_variant)
			if not runtime_controls.has(key) or not is_instance_valid(runtime_controls[key]):
				failures.append("运行参数设置缺少控件：%s" % key)
		var stat_controls: Dictionary = (settings_panel.get("_advanced") as Object).get("_stat_controls")
		for stat_key in ["health", "intimacy", "mood"]:
			if not stat_controls.has(stat_key) or not is_instance_valid(stat_controls[stat_key]):
				failures.append("当前属性编辑器缺少控件：%s" % stat_key)
		var settings_scroll := _find_scroll_container(settings_panel)
		if is_instance_valid(settings_scroll):
			settings_scroll.scroll_vertical = int(settings_scroll.get_v_scroll_bar().max_value)
			for _frame in 4:
				await get_tree().process_frame
		var settings_screenshot_path := "user://ambient_settings_ui.png"
		if _is_headless():
			print("GAMEWORLD_UI_RENDER_CHECK headless: 设置页截图跳过")
		else:
			var settings_image := get_viewport().get_texture().get_image()
			if settings_image == null or settings_image.is_empty() or settings_image.save_png(settings_screenshot_path) != OK:
				failures.append("后台生活设置截图保存失败")

	var archive_button := world.get("_archive_button") as Button
	var archive_panel := world.get("_archive_panel") as Control
	if not is_instance_valid(archive_button) or not is_instance_valid(archive_panel):
		failures.append("聊天归档入口或面板未创建")
	else:
		if is_instance_valid(settings_panel):
			settings_panel.hide()
		archive_panel.call("show_panel")
		for _frame in 18:
			await get_tree().process_frame
		if not archive_panel.visible:
			failures.append("聊天归档面板无法打开")
		var archive_date_select := archive_panel.get("_date_select") as OptionButton
		var archive_search_input := archive_panel.get("_search_input") as LineEdit
		var archive_results := archive_panel.get("_results") as VBoxContainer
		if (
			not is_instance_valid(archive_date_select)
			or not is_instance_valid(archive_search_input)
			or not is_instance_valid(archive_results)
		):
			failures.append("聊天归档筛选控件不完整")
		var archive_screenshot_path := "user://conversation_archive_ui.png"
		if _is_headless():
			print("GAMEWORLD_UI_RENDER_CHECK headless: 归档截图跳过")
		else:
			var archive_image := get_viewport().get_texture().get_image()
			if archive_image == null or archive_image.is_empty() or archive_image.save_png(archive_screenshot_path) != OK:
				failures.append("聊天归档界面截图保存失败")

	if failures.is_empty():
		print("GAMEWORLD_UI_RENDER_CHECK passed screenshot=", ProjectSettings.globalize_path(screenshot_path))
		await _finish(world, 0)
		return
	for failure in failures:
		printerr("GAMEWORLD_UI_RENDER_CHECK failure=", failure)
	await _finish(world, 1)

# 层级契约。改坏的那次就是在这里翻车的：SceneShell 被设成 z_index = 1，而五个
# 遮罩面板还是 GameWorld 的普通兄弟节点（z_index 0）。Godot 的 z_index 优先于
# 树序，于是 move_to_front() 再也压不上去 —— 心织被 GameWorld 的标题、角色切换、
# 对话层和角色舞台整个打穿，而从未调用 move_to_front 的设置、生活回顾、家の地图
# 连显示都做不到。
func _expect_modal_layer(world: Node, failures: Array[String]) -> void:
	var shell := world.get("_main_layout") as Control
	if not is_instance_valid(shell):
		failures.append("场景外壳未创建")
	elif shell.z_index > 0:
		failures.append("场景外壳不应有正 z_index，否则会盖住遮罩面板：%d" % shell.z_index)
	var modal_layer := world.get_node_or_null("ModalLayer") as CanvasLayer
	if not is_instance_valid(modal_layer) or modal_layer.layer <= 0:
		failures.append("缺少高于场景外壳的遮罩画布层")
		return
	for key in [
		"_settings",
		"_archive_panel",
		"_memory_network_panel",
		"_life_review_panel",
		"_house_editor",
	]:
		var panel := world.get(key) as Control
		if not is_instance_valid(panel):
			failures.append("遮罩面板未创建：%s" % key)
			continue
		if panel.get_parent() != modal_layer:
			failures.append("遮罩面板不在模态画布层上：%s" % key)
	print("GAMEWORLD_UI_RENDER_CHECK 层级: shell.z=%d modal.layer=%d" % [
		shell.z_index if is_instance_valid(shell) else -1, modal_layer.layer
	])


# 打开心织后必须真正盖住 GameWorld：遮罩铺满视口并且吃掉鼠标输入。
func _expect_overlay_covers_world(world: Node, failures: Array[String]) -> void:
	var panel := world.get("_memory_network_panel") as Control
	if not is_instance_valid(panel):
		failures.append("心织面板未创建")
		return
	panel.call("show_panel")
	# show_panel 把 modulate.a 从 0 淡入到 1，只等两帧的话截图会停在几乎全透明
	# 的状态上——那正是"覆层装作不存在"的假象，必须等淡入走完再判定。headless
	# 没有垂直同步，帧率远高于 60，固定等 N 帧并不可靠，所以等到位为止。
	var waited := 0
	while waited < 600 and not is_equal_approx(panel.modulate.a, 1.0):
		await get_tree().process_frame
		waited += 1
	if not is_equal_approx(panel.modulate.a, 1.0):
		failures.append("心织面板淡入没有完成：modulate.a=%s" % panel.modulate.a)
	if not _is_headless():
		# 这份合成数据截图就是"心织覆层到底有没有被打穿"的证据。
		await _save_viewport_screenshot("user://gameworld_heartloom_overlay.png")
	var viewport_rect := Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size)
	var scrim := panel.get("_background") as ColorRect
	var covers := is_instance_valid(scrim) and viewport_rect.encloses(scrim.get_global_rect())
	var blocks := is_instance_valid(scrim) and scrim.mouse_filter == Control.MOUSE_FILTER_STOP
	if not covers:
		failures.append("心织遮罩没有铺满视口")
	if not blocks:
		failures.append("心织遮罩没有拦截鼠标输入")
	panel.call("close_panel")
	for _frame in 24:
		await get_tree().process_frame
	if panel.visible:
		failures.append("心织面板无法关闭")
	print("GAMEWORLD_UI_RENDER_CHECK 心织覆层: 遮罩铺满=%s 拦截=%s 关闭=%s" % [
		covers, blocks, not panel.visible
	])


# Settings 在自己的 _ready 里就发过一次 visual_accessibility_changed，早于
# GameWorld 连接它 —— 连接信号不会补发历史值，所以必须在 _ready 里主动应用一次，
# 否则"减少动态效果"完全不影响 GameWorld 的庭院底板与立绘呼吸。
func _expect_reduced_motion(world: Node, failures: Array[String]) -> void:
	var backdrop := world.get("_background_fx") as Control
	if not is_instance_valid(backdrop):
		failures.append("庭院底板未创建")
		return
	var portrait := world.get("_portrait_rig") as Control
	world.call("_on_visual_accessibility_changed", true)
	var stopped_backdrop := not backdrop.is_processing()
	var frozen_portrait := (
		is_instance_valid(portrait)
		and is_zero_approx(float(portrait.get("motion_strength")))
	)
	world.call("_on_visual_accessibility_changed", false)
	var resumed_backdrop := backdrop.is_processing()
	var resumed_portrait := (
		is_instance_valid(portrait) and float(portrait.get("motion_strength")) > 0.0
	)
	if not stopped_backdrop or not resumed_backdrop:
		failures.append("减少动态效果没有停掉庭院底板")
	if is_instance_valid(portrait) and (not frozen_portrait or not resumed_portrait):
		failures.append("减少动态效果没有收掉立绘呼吸")
	print("GAMEWORLD_UI_RENDER_CHECK 减少动态效果: 底板 停=%s 恢复=%s 立绘 停=%s 恢复=%s" % [
		stopped_backdrop, resumed_backdrop, frozen_portrait, resumed_portrait
	])


# 视口矩阵：宽屏（>=1280）阅读层在左、舞台在右；中屏（641~1279）纵向上下
# 分离；窄屏（<=640）压缩舞台并堆叠。956~1259px 是旧二分法（>940 即宽屏）
# 漏掉的区间，必须逐档验证，不能只测默认尺寸与 600×600。
const SCENE_LAYOUT_VIEWPORTS := [
	Vector2i(1440, 900),
	Vector2i(1280, 720),
	Vector2i(1152, 720),
	Vector2i(1024, 720),
	Vector2i(800, 600),
	Vector2i(600, 600),
]


func _expect_scene_layout_matrix(failures: Array[String]) -> void:
	var before := failures.size()
	for size in SCENE_LAYOUT_VIEWPORTS:
		await _expect_scene_layout_for_size(size, failures)
	print("GAMEWORLD_UI_RENDER_CHECK 视口矩阵: %d 档, 新增失败 %d" % [
		SCENE_LAYOUT_VIEWPORTS.size(), failures.size() - before
	])


func _expect_scene_layout_for_size(size: Vector2i, failures: Array[String]) -> void:
	var viewport := SubViewport.new()
	viewport.size = size
	viewport.render_target_update_mode = (
		SubViewport.UPDATE_DISABLED if _is_headless() else SubViewport.UPDATE_ALWAYS
	)
	get_tree().root.add_child(viewport)
	var world := GAME_WORLD_SCENE.instantiate() as Control
	world.set("_suppress_exit_persistence", true)
	world.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewport.add_child(world)
	await get_tree().process_frame
	await get_tree().process_frame
	world.call("_apply_responsive_layout")
	await get_tree().process_frame
	var label := "%d×%d" % [size.x, size.y]
	var viewport_rect := Rect2(Vector2.ZERO, Vector2(size))
	var shell := world.get("_main_layout") as Control
	var shell_origin := shell.get_global_rect().position if is_instance_valid(shell) else Vector2.ZERO
	var title_lockup := world.get("_nav") as Control
	var utility_rail := world.get("_utility_rail") as Control
	var chat_area := world.get("_chat_area") as Control
	var chat_input := world.get("_chat_input") as Control
	var stage := world.get("_stage_column") as Control
	for entry in [
		[title_lockup, "标题锁定卡"],
		[utility_rail, "工具栏"],
		[chat_area, "对话阅读层"],
		[chat_input, "输入框"],
		[stage, "角色舞台"],
	]:
		var control := entry[0] as Control
		if not is_instance_valid(control):
			failures.append("%s 缺少%s" % [label, str(entry[1])])
			continue
		var global_rect := control.get_global_rect()
		var rect := Rect2(global_rect.position - shell_origin, global_rect.size)
		if not viewport_rect.encloses(rect):
			failures.append("%s 的%s超出视口：%s" % [label, str(entry[1]), rect])
	if is_instance_valid(chat_area) and is_instance_valid(stage):
		if _offset_rect(chat_area, shell_origin).intersects(_offset_rect(stage, shell_origin)):
			failures.append("%s 的对话阅读层与角色舞台重叠" % label)
	if is_instance_valid(utility_rail) and is_instance_valid(title_lockup):
		if _offset_rect(utility_rail, shell_origin).intersects(
			_offset_rect(title_lockup, shell_origin)
		):
			failures.append("%s 的工具栏与标题锁定卡重叠" % label)
	if is_instance_valid(chat_area):
		# 阅读层高度必须等于它自己的目标公式（页脚 + 间距 + 内容收敛后的历史面），
		# 且不低于页脚下限。低于下限会把输入框挤出视口；写死高度或整列铺满
		# 都会让这条断言失败——那正是"巨大的空对话板"的两种回退方式。
		var tier := str(world.call("_layout_tier", float(size.x)))
		var floor_height := float(world.call("_reading_layer_floor"))
		var target := float(world.call("_reading_layer_target_height", float(size.y), tier))
		var area_height := chat_area.get_global_rect().size.y
		print("GAMEWORLD_UI_RENDER_CHECK  %s tier=%s 阅读层=%s 目标=%s 内容=%s 下限=%s 舞台=%s" % [
			label,
			tier,
			area_height,
			target,
			float(world.call("_history_content_height")),
			floor_height,
			stage.get_global_rect().size.y if is_instance_valid(stage) else -1.0,
		])
		if not is_equal_approx(area_height, target):
			failures.append("%s 的阅读层高度 %s 与目标 %s 不一致" % [label, area_height, target])
		if area_height < floor_height - 1.0:
			failures.append("%s 的阅读层高度 %s 低于页脚下限 %s" % [label, area_height, floor_height])
	if not _is_headless():
		# 每档留一张实拍图:三档构图是"是否重叠/是否被压没"的最终证据。
		# 多等两帧让 SubViewport 的尺寸与布局都落定，否则会拍到退化帧。
		await get_tree().process_frame
		await get_tree().process_frame
		_save_subviewport_screenshot(
			viewport, "user://gameworld_scene_%dx%d.png" % [size.x, size.y]
		)
	world.free()
	viewport.free()


func _offset_rect(control: Control, origin: Vector2) -> Rect2:
	var rect := control.get_global_rect()
	rect.position -= origin
	return rect


func _save_viewport_screenshot(path: String) -> void:
	var image := get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		printerr("GAMEWORLD_UI_RENDER_CHECK 截图失败：", path)
		return
	image.save_png(path)
	print("GAMEWORLD_UI_RENDER_CHECK 截图 %s" % ProjectSettings.globalize_path(path))


func _save_subviewport_screenshot(viewport: SubViewport, path: String) -> void:
	var image := viewport.get_texture().get_image()
	if image == null or image.is_empty():
		printerr("GAMEWORLD_UI_RENDER_CHECK 分档截图失败：", path)
		return
	image.save_png(path)
	print("GAMEWORLD_UI_RENDER_CHECK 分档截图 %s" % ProjectSettings.globalize_path(path))


# "巨大的空对话板"的直接回归守卫：把已有对白隐藏后，阅读面必须收到内容大小
# （页脚 + 最小历史面），而不是继续占满整列。旧实现是固定高度，这里必然失败。
func _expect_short_history_shrinks(failures: Array[String]) -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	get_tree().root.add_child(viewport)
	var world := GAME_WORLD_SCENE.instantiate() as Control
	world.set("_suppress_exit_persistence", true)
	world.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewport.add_child(world)
	await get_tree().process_frame
	await get_tree().process_frame
	world.call("_apply_responsive_layout")
	await get_tree().process_frame
	var chat_list := world.get("_chat_list") as VBoxContainer
	var chat_area := world.get("_chat_area") as Control
	if not is_instance_valid(chat_list) or not is_instance_valid(chat_area):
		failures.append("短对白收缩检查缺少对话层")
		world.free()
		viewport.free()
		return
	var tall := chat_area.get_global_rect().size.y
	# 隐藏而不是释放，避免打字机等协程持有悬空引用。
	for child in chat_list.get_children():
		(child as Control).hide()
	chat_list.update_minimum_size()
	await get_tree().process_frame
	world.call("_refresh_reading_layer_height")
	await get_tree().process_frame
	var short := chat_area.get_global_rect().size.y
	var floor_height := float(world.call("_reading_layer_floor"))
	print("GAMEWORLD_UI_RENDER_CHECK  对白清空前后阅读层=%s → %s 下限=%s" % [
		tall, short, floor_height
	])
	if short >= tall - 1.0:
		failures.append("清空对白后阅读层仍占满整列：%s → %s" % [tall, short])
	if short < floor_height - 1.0:
		failures.append("清空对白后阅读层低于页脚下限：%s < %s" % [short, floor_height])
	world.free()
	viewport.free()


func _finish(world: Node, exit_code: int) -> void:
	if is_instance_valid(world):
		world.set("_typewriter_skip_requested", true)
		for tween in get_tree().get_processed_tweens():
			tween.kill()
		await get_tree().process_frame
		world.free()
		for _frame in 6:
			await get_tree().process_frame
	get_tree().quit(exit_code)

func _check_developer_reply_tuning(world: Node, failures: Array[String]) -> void:
	var developer_before: Dictionary = Settings.settings.get("developer", {}).duplicate(true)
	var tuning := Settings.get_runtime_tuning()
	var developer := developer_before.duplicate(true)
	tuning["default_reply_mode"] = "both"
	tuning["both_names_trigger_dual"] = false
	developer["runtime_tuning"] = tuning
	Settings.settings["developer"] = developer

	var result: Dictionary = world.call("_resolve_recipients", "晚上好", "ling")
	if result.get("roles", []) != ["ling", "nai"]:
		failures.append("未点名双人回复设置没有生效")
	result = world.call("_resolve_recipients", "小奈来回答一下", "ling")
	if result.get("roles", []) != ["nai"]:
		failures.append("明确点名小奈时被双人回复设置覆盖")
	result = world.call("_resolve_recipients", "让小玲问问小奈晚饭吃什么", "ling")
	var route_variant = result.get("route", {})
	var route: Dictionary = route_variant if route_variant is Dictionary else {}
	if (
		result.get("roles", []) != ["ling", "nai"]
		or str(route.get("origin_role", "")) != "ling"
		or str(route.get("target_role", "")) != "nai"
	):
		failures.append("双人回复设置覆盖了委托询问路由")

	tuning = tuning.duplicate(true)
	tuning["default_reply_mode"] = "selected"
	tuning["both_names_trigger_dual"] = true
	developer = developer.duplicate(true)
	developer["runtime_tuning"] = tuning
	Settings.settings["developer"] = developer
	result = world.call("_resolve_recipients", "今天小玲和小奈都很可爱", "ling")
	if result.get("roles", []) != ["ling", "nai"]:
		failures.append("同时提到两人时触发双人回复没有生效")
	result = world.call("_resolve_recipients", "小奈知道小玲是自己的老婆吧", "ling")
	if result.get("roles", []) != ["nai"]:
		failures.append("句首明确点名小奈时被双人提及设置覆盖")

	Settings.settings["developer"] = developer_before

func _find_scroll_container(node: Node) -> ScrollContainer:
	if node is ScrollContainer:
		return node as ScrollContainer
	for child in node.get_children():
		var result := _find_scroll_container(child)
		if is_instance_valid(result):
			return result
	return null

func _has_core_client_log_window(node: Node) -> bool:
	if node is Window and (node as Window).title == "CompanionCore 日志":
		return true
	for child in node.get_children():
		if _has_core_client_log_window(child):
			return true
	return false
