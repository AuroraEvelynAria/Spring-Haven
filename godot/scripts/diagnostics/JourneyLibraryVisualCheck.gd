extends Node

const MAIN_MENU_SCENE := preload("res://scenes/MainMenu/MainMenu.tscn")
const VIEWPORTS := [Vector2i(1440, 900), Vector2i(1280, 720), Vector2i(800, 600)]


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var failures: Array[String] = []
	var menu := MAIN_MENU_SCENE.instantiate()
	add_child(menu)
	for _frame in 4:
		await get_tree().process_frame
	var library := menu.get("_journey_library") as Control
	if not is_instance_valid(library):
		_finish(menu, ["旅程档案面板未创建"])
		return
	library.call("show_panel")
	for viewport_size in VIEWPORTS:
		get_window().size = viewport_size
		for _frame in 10:
			await get_tree().process_frame
		_check_layout(library, viewport_size, failures)
		var image := get_viewport().get_texture().get_image()
		var path := "user://journey_library_%dx%d.png" % [viewport_size.x, viewport_size.y]
		if image == null or image.is_empty() or image.save_png(path) != OK:
			failures.append("%s 截图保存失败" % viewport_size)

	get_window().size = Vector2i(800, 600)
	library.call("_request_new_journey")
	for _frame in 8:
		await get_tree().process_frame
	var new_dialog := library.get("_new_dialog") as ConfirmationDialog
	if not is_instance_valid(new_dialog) or not new_dialog.visible:
		failures.append("新建旅程弹窗无法显示")
	elif new_dialog.size.x > 768:
		failures.append("小窗口中的新建弹窗超出视口")
	else:
		var dialog_image := get_viewport().get_texture().get_image()
		if dialog_image == null or dialog_image.is_empty() or dialog_image.save_png(
			"user://journey_library_new_dialog_800x600.png"
		) != OK:
			failures.append("新建旅程弹窗截图保存失败")
	new_dialog.hide()
	_finish(menu, failures)


func _check_layout(library: Control, viewport_size: Vector2i, failures: Array[String]) -> void:
	var panel := library.get("_panel") as PanelContainer
	var rows := library.get("_rows") as VBoxContainer
	if not is_instance_valid(panel) or not is_instance_valid(rows):
		failures.append("%s 缺少主面板或旅程列表" % viewport_size)
		return
	var viewport_rect := library.get_viewport_rect()
	var panel_rect := panel.get_global_rect()
	if not viewport_rect.encloses(panel_rect):
		failures.append("%s 主面板超出视口：%s" % [viewport_size, panel_rect])
	if panel_rect.size.x < minf(760.0, viewport_rect.size.x - 28.0):
		failures.append("%s 主面板没有合理利用可用宽度" % viewport_size)
	for row in rows.get_children():
		if not row is Control or not (row as Control).visible:
			continue
		var row_rect := (row as Control).get_global_rect()
		if row_rect.size.x > panel_rect.size.x + 1.0:
			failures.append("%s 旅程行宽度溢出主面板" % viewport_size)
		for button in row.find_children("*", "Button", true, false):
			if button is Button and not panel_rect.encloses((button as Button).get_global_rect()):
				failures.append("%s 旅程操作按钮超出主面板" % viewport_size)


func _finish(menu: Node, failures: Array[String]) -> void:
	if is_instance_valid(menu):
		menu.queue_free()
	await get_tree().process_frame
	if failures.is_empty():
		print("JOURNEY_LIBRARY_VISUAL_CHECK=PASS")
		get_tree().quit(0)
		return
	for failure in failures:
		printerr("JOURNEY_LIBRARY_VISUAL_CHECK failure=", failure)
	get_tree().quit(1)
