extends Node

## 主菜单按钮动画验收 v2:05/06 帧没拍到缩放——嫌疑是异步时序。
## 这次:驱动后立即 + 短间隔连环拍三帧,并同步打 log 验证 scale 值。

const OUT_DIR := "user://menu_anim_verify"

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("MENU_ANIM_VERIFY headless unsupported")
		get_tree().quit(2)
		return
	var dir := DirAccess.open("user://")
	dir.make_dir_recursive(OUT_DIR)
	var main_menu: Node = load("res://scenes/MainMenu/MainMenu.tscn").instantiate()
	get_tree().root.add_child(main_menu)
	await get_tree().create_timer(2.2).timeout
	await _shot("03-float-a")
	var new_game_button: Button = main_menu.get("_new_game_button")
	print("MENU_ANIM_VERIFY pre-scale=", new_game_button.scale)
	main_menu.call("_scale_button", new_game_button, 1.05)
	await get_tree().create_timer(0.26).timeout
	print("MENU_ANIM_VERIFY post-scale=", new_game_button.scale)
	await _shot("05-hover-scaled")
	main_menu.call("_press_bounce", new_game_button)
	await get_tree().create_timer(0.06).timeout
	print("MENU_ANIM_VERIFY mid-press=", new_game_button.scale)
	await _shot("06-press-squash")
	await get_tree().create_timer(0.4).timeout
	print("MENU_ANIM_VERIFY recovered=", new_game_button.scale)
	await _shot("07-press-recovered")
	print("MENU_ANIM_VERIFY done")
	get_tree().quit(0)

func _shot(caption: String) -> void:
	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, caption]
	if image.save_png(path) == OK:
		print("MENU_ANIM_VERIFY shot=", ProjectSettings.globalize_path(path))
