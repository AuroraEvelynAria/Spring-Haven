extends Node

const SETTINGS_SCENE := preload("res://scenes/Settings/SettingsPanel.tscn")


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	get_window().size = Vector2i(1440, 900)
	var panel := SETTINGS_SCENE.instantiate()
	add_child(panel)
	panel.show_panel()
	panel.call("_switch_settings_category", "ai")
	panel.call("_switch_settings_subcategory", "fallbacks")
	for _frame in 16:
		await get_tree().process_frame
	var drafts: Dictionary = panel.get("_provider_fallback_drafts")
	if (drafts.get("chat", []) as Array).is_empty():
		panel.call("_add_provider_fallback_candidate", "chat")
	for _frame in 8:
		await get_tree().process_frame
	var image := get_viewport().get_texture().get_image()
	var path := "user://provider_fallback_ui.png"
	var error := image.save_png(path)
	if error != OK or image.is_empty():
		printerr("PROVIDER_FALLBACK_UI_VISUAL_CHECK failure=empty_capture")
		get_tree().quit(1)
		return
	print("PROVIDER_FALLBACK_UI_VISUAL_CHECK=PASS path=", ProjectSettings.globalize_path(path), " size=", image.get_size())
	panel.queue_free()
	await get_tree().process_frame
	get_tree().quit(0)
