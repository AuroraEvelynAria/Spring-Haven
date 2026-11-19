extends Node

## 主菜单美术评审取证:安静状态一张 + 悬停「继续旅程」一张 + 展开旅程档案
## (如果面板在主菜单实例里)一张——给主人/评审模型看真实观感。

const OUT_DIR := "user://menu_review"

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("MENU_REVIEW headless unsupported")
		get_tree().quit(2)
		return
	var dir := DirAccess.open("user://")
	dir.make_dir_recursive(OUT_DIR)
	var main_menu: Node = load("res://scenes/MainMenu/MainMenu.tscn").instantiate()
	get_tree().root.add_child(main_menu)
	# 等入场动画完全落定 + 漂浮进入稳态
	await get_tree().create_timer(3.0).timeout
	await _shot("01-menu-idle")
	# 悬停主按钮的观感
	var start_button: Button = main_menu.get("_start_button")
	main_menu.call("_scale_button", start_button, 1.05)
	await get_tree().create_timer(0.3).timeout
	await _shot("02-menu-hover-continue")
	main_menu.call("_scale_button", start_button, 1.0)
	# 设置面板打开态(外测者第二个高频界面)
	var settings: Control = main_menu.get("_settings")
	settings.call("show_panel", "ai")
	await get_tree().create_timer(1.0).timeout
	await _shot("03-menu-settings-open")
	print("MENU_REVIEW done")
	get_tree().quit(0)

func _shot(caption: String) -> void:
	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, caption]
	if image.save_png(path) == OK:
		print("MENU_REVIEW shot=", ProjectSettings.globalize_path(path))
