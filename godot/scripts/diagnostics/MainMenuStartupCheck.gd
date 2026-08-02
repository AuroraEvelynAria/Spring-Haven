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
	var journey_button := menu.find_child("JourneyLibraryButton", true, false) as Button
	var journey_library := menu.get("_journey_library") as Control
	_expect(is_instance_valid(model_dialog), "主菜单缺少聊天模型首次设置入口")
	_expect(is_instance_valid(startup_dialog), "主菜单缺少 Core 启动失败对话框")
	_expect(is_instance_valid(journey_button), "主菜单缺少旅程档案按钮")
	_expect(is_instance_valid(journey_library), "主菜单缺少旅程档案面板")
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


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	push_error(message)
