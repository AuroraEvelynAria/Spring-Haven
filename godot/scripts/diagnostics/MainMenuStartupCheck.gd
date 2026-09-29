extends SceneTree

var _failed := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var main_menu := load("res://scenes/MainMenu/MainMenu.tscn") as PackedScene
	_expect(main_menu != null, "主菜单场景无法加载")
	if main_menu == null:
		quit(1)
		return
	var menu := main_menu.instantiate()
	root.add_child(menu)
	await process_frame
	await process_frame
	var model_dialog := menu.get("_model_setup_dialog") as ConfirmationDialog
	var startup_dialog := menu.get("_core_startup_dialog") as AcceptDialog
	var menu_anchor := menu.get("_menu_anchor") as MarginContainer
	var menu_buttons := menu.get("_menu_buttons") as VBoxContainer
	var version := menu.get("_version") as Label
	var journey_button := menu.find_child("JourneyLibraryButton", true, false) as Button
	var journey_library := menu.get("_journey_library") as Control
	_expect(is_instance_valid(model_dialog), "主菜单缺少聊天模型首次设置入口")
	_expect(is_instance_valid(startup_dialog), "主菜单缺少 Core 启动失败对话框")
	_expect(is_instance_valid(menu_anchor) and is_instance_valid(menu_buttons), "主菜单缺少响应式入口锚点")
	_expect(is_instance_valid(version), "主菜单缺少版本标签")
	_expect(is_instance_valid(journey_button), "主菜单缺少旅程档案按钮")
	_expect(is_instance_valid(journey_library), "主菜单缺少旅程档案面板")
	if is_instance_valid(menu_buttons) and is_instance_valid(version) and version.visible:
		var menu_bottom := menu_buttons.get_global_rect().end.y
		var version_top := version.get_global_rect().position.y
		var content := menu.get("_content") as VBoxContainer
		var anchor_rect := menu_anchor.get_global_rect() if is_instance_valid(menu_anchor) else Rect2()
		var content_rect := content.get_global_rect() if is_instance_valid(content) else Rect2()
		var combined_minimum := content.get_combined_minimum_size() if is_instance_valid(content) else Vector2()
		_expect(
			menu_bottom <= version_top - 6.0,
			"主菜单入口组与版本标签重叠：入口底部 %.1f，版本顶部 %.1f，锚点=%s，内容=%s，内容最小尺寸=%s" % [
				menu_bottom, version_top, anchor_rect, content_rect, combined_minimum
			]
		)
	await _expect_compact_layout(main_menu)
	if is_instance_valid(journey_library):
		_expect(is_instance_valid(journey_library.get("_new_dialog")), "旅程档案缺少新建弹窗")
		_expect(is_instance_valid(journey_library.get("_rename_dialog")), "旅程档案缺少重命名弹窗")
		_expect(is_instance_valid(journey_library.get("_archive_dialog")), "旅程档案缺少归档弹窗")
		journey_library.call("show_panel")
		await process_frame
		_expect(journey_library.visible, "旅程档案面板无法打开")
		journey_library.call("close_panel")
		_expect(not journey_library.visible, "旅程档案面板无法关闭")
	menu.call("_show_core_startup_failure")
	await process_frame
	_expect(startup_dialog.visible, "Core 启动失败对话框无法显示")
	_expect("聊天和记忆暂时不可用" in startup_dialog.dialog_text, "Core 失败说明不完整")
	_expect("Windows 安全中心" in startup_dialog.dialog_text, "Core 失败说明缺少隔离排查提示")
	startup_dialog.hide()
	menu.free()
	if _failed:
		quit(1)
		return
	print("MAIN_MENU_STARTUP_CHECK=PASS")
	quit(0)


func _expect_compact_layout(main_menu: PackedScene) -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(600, 600)
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	root.add_child(viewport)
	var menu := main_menu.instantiate() as Control
	menu.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewport.add_child(menu)
	await process_frame
	await process_frame
	menu.call("_apply_responsive_layout")
	await process_frame
	var buttons := menu.get("_menu_buttons") as VBoxContainer
	var version := menu.get("_version") as Label
	var viewport_rect := Rect2(Vector2.ZERO, Vector2(viewport.size))
	if not is_instance_valid(buttons) or not viewport_rect.encloses(buttons.get_global_rect()):
		_expect(false, "紧凑主菜单入口组超出 600×600 视口")
	elif is_instance_valid(version) and version.visible:
		_expect(
			viewport_rect.encloses(version.get_global_rect())
			and buttons.get_global_rect().end.y <= version.get_global_rect().position.y - 6.0,
			"紧凑主菜单入口组与版本标签重叠或被裁切"
		)
	menu.free()
	viewport.free()


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	push_error(message)
