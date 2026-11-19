extends Node

## 首启体验确定性验收:不与 Core 自愈机制赛跑,直接驱动状态行状态机
## 拍四张证据图:连接中(呼吸)/就绪/失败(红点+详情)/向导两步。
## 用法:真窗口运行本场景。

const OUT_DIR := "user://startup_verify"
const MAIN_MENU := preload("res://scenes/MainMenu/MainMenu.tscn")
const STATUS_LINE := preload("res://scripts/ui/StartupStatusLine.gd")
const WIZARD := preload("res://scenes/MainMenu/FirstRunWizard.gd")

var _shots := 0

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("STARTUP_VERIFY headless unsupported")
		get_tree().quit(2)
		return
	var dir := DirAccess.open("user://")
	dir.make_dir_recursive(OUT_DIR)
	var main_menu: Node = MAIN_MENU.instantiate()
	get_tree().root.add_child(main_menu)
	await get_tree().create_timer(2.5).timeout

	# 1) 连接中:直接把状态行置为 CONNECTING(排除 Core 秒连的竞速)。
	# 状态行的 _process 轮询会把状态刷回真实值——验收时先停表,拍完三态再恢复。
	var status_line: Control = main_menu.get("_startup_status")
	if not is_instance_valid(status_line):
		printerr("STARTUP_VERIFY status_line missing")
		get_tree().quit(3)
		return
	status_line.set_process(false)
	status_line.call("_apply_state", 1, "正在启动对话核心…")
	await get_tree().create_timer(1.2).timeout
	await _shot("01-startup-connecting")

	# 2) 就绪
	status_line.call("_apply_state", 2, "已连接 Companion Core")
	await get_tree().create_timer(0.8).timeout
	await _shot("02-startup-ready")

	# 3) 失败:红点+详情按钮
	status_line.call("_apply_state", 3, "Companion Core 未连接")
	await get_tree().create_timer(0.8).timeout
	await _shot("03-startup-failed")
	status_line.set_process(true)

	# 4/5) 向导两步(修复后的 open_wizard 必须真的出现)
	var wizard: Control = WIZARD.new()
	wizard.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	get_tree().root.add_child(wizard)
	wizard.call("open_wizard")
	await get_tree().create_timer(1.0).timeout
	await _shot("04-wizard-step1")
	wizard.call("_on_next_pressed")
	await get_tree().create_timer(0.8).timeout
	await _shot("05-wizard-step2")

	print("STARTUP_VERIFY shots=", _shots)
	get_tree().quit(0)

func _shot(caption: String) -> void:
	_shots += 1
	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, caption]
	if image.save_png(path) == OK:
		print("STARTUP_VERIFY shot=", ProjectSettings.globalize_path(path))
