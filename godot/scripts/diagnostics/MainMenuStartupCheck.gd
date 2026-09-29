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
	_expect_font_size_stability(menu)
	_expect_reduced_motion_and_petal_layer(menu)
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


# 这个诊断跑在 SceneTree 主循环上,编译期解析不到 Settings 这个 autoload 标识,
# 只能运行时从 root 取。
func _settings_ui_value(key: String, fallback: Variant) -> Variant:
	var settings := root.get_node_or_null("/root/Settings")
	if settings == null:
		return fallback
	var ui: Dictionary = settings.settings.get("ui", {})
	return ui.get(key, fallback)


# 标题/副标题的构建初值与字号缩放公式必须是同一组。旧代码标题初值 30、公式却是
# maxi(42, size + 41)：用户第一次改字号时标题会从 30 直接跳到 56。
func _expect_font_size_stability(menu: Node) -> void:
	var title := menu.get("_title") as Label
	var subtitle := menu.get("_subtitle") as Label
	if not is_instance_valid(title) or not is_instance_valid(subtitle):
		_expect(false, "主菜单缺少标题或副标题")
		return
	var default_size := int(_settings_ui_value("font_size", 15))
	var title_before := title.get_theme_font_size("font_size")
	var subtitle_before := subtitle.get_theme_font_size("font_size")
	menu.call("_on_font_size_changed", default_size)
	var title_after := title.get_theme_font_size("font_size")
	var subtitle_after := subtitle.get_theme_font_size("font_size")
	_expect(
		title_before == title_after,
		"以默认字号重算时标题字号发生跳变：%d → %d" % [title_before, title_after]
	)
	_expect(
		subtitle_before == subtitle_after,
		"以默认字号重算时副标题字号发生跳变：%d → %d" % [subtitle_before, subtitle_after]
	)
	print("MAIN_MENU_STARTUP_CHECK 字号稳定: 标题=%d 副标题=%d" % [
		title_after, subtitle_after
	])


# 两个开箱即坏的设置：减少动态效果必须在 _ready 里主动应用一次(连接信号不会
# 补发历史值)，以及底板必须压到父节点自己的绘制之下，否则落花每帧照跑但看不见。
func _expect_reduced_motion_and_petal_layer(menu: Node) -> void:
	var backdrop := menu.get("_scene_backdrop") as Control
	if not is_instance_valid(backdrop):
		_expect(false, "主菜单缺少庭院底板")
		return
	_expect(
		backdrop.z_index < 0,
		"庭院底板没有压到负层级,父节点的落花会被它整屏盖住"
	)
	var reduced := bool(_settings_ui_value("reduced_motion", false))
	_expect(
		menu.is_processing() != reduced,
		"减少动态效果没有在启动时生效(processing=%s reduced=%s)" % [
			menu.is_processing(), reduced
		]
	)
	_expect(
		not bool(backdrop.is_processing()) == reduced,
		"庭院底板没有跟随减少动态效果设置"
	)
	print("MAIN_MENU_STARTUP_CHECK 动态效果: reduced=%s 菜单processing=%s 底板processing=%s z=%d" % [
		reduced, menu.is_processing(), backdrop.is_processing(), backdrop.z_index
	])
