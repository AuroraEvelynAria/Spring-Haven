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
	var send_button := world.get("_send_button") as Button
	var chat_input := world.get("_chat_input") as LineEdit
	var ling_button := world.get("_ling_button") as Button
	var thinking_strip := world.get("_thinking_strip") as ColorRect
	var thinking_material := world.get("_thinking_strip_material") as ShaderMaterial
	var log_label := world.get("_log_label") as Label
	var message_views: Dictionary = world.get("_message_views")
	var sidebar := world.get("_sidebar") as ScrollContainer
	var portrait_rig := world.get("_portrait_rig") as Control
	chat_input.text = "输入光标位置测试"
	chat_input.caret_column = 4
	chat_input.grab_focus()
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
	if sidebar.size.x < 330.0:
		failures.append("桌面侧栏宽度未扩大")
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
	var image := get_viewport().get_texture().get_image()
	if image == null or image.is_empty() or image.save_png(screenshot_path) != OK:
		if not _is_headless():
			failures.append("UI 截图保存失败")
		else:
			print("GAMEWORLD_UI_RENDER_CHECK headless: 截图跳过")

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
		var settings_image := get_viewport().get_texture().get_image()
		if (
			settings_image == null
			or settings_image.is_empty()
			or settings_image.save_png(settings_screenshot_path) != OK
		):
			if _is_headless():
				print("GAMEWORLD_UI_RENDER_CHECK headless: 设置页截图跳过")
			else:
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
		var archive_image := get_viewport().get_texture().get_image()
		if archive_image == null or archive_image.is_empty() or archive_image.save_png(archive_screenshot_path) != OK:
			if _is_headless():
				print("GAMEWORLD_UI_RENDER_CHECK headless: 归档截图跳过")
			else:
				failures.append("聊天归档界面截图保存失败")
	if failures.is_empty():
		print("GAMEWORLD_UI_RENDER_CHECK passed screenshot=", ProjectSettings.globalize_path(screenshot_path))
		await _finish(world, 0)
		return
	for failure in failures:
		printerr("GAMEWORLD_UI_RENDER_CHECK failure=", failure)
	await _finish(world, 1)

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
