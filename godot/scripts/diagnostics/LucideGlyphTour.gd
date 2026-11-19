extends Node

## Lucide 图标字体渲染验证:把 12 枚常用图标画成两行大号(48px)对照图,
## 每枚下方标注图标名——供视觉验收"图标名→字形"是否正确。

const OUT := "user://lucide_verify/samples.png"

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("LUCIDE_VERIFY headless unsupported")
		get_tree().quit(2)
		return
	var dir := DirAccess.open("user://")
	dir.make_dir_recursive("lucide_verify")
	var bg := ColorRect.new()
	bg.color = Color("#FFFFFF")
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var grid := GridContainer.new()
	grid.columns = 6
	grid.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	grid.add_theme_constant_override("h_separation", 28)
	grid.add_theme_constant_override("v_separation", 20)
	add_child(grid)
	var names := [
		"settings", "sparkles", "book-open", "leaf", "sliders-horizontal",
		"database", "download", "x", "search", "house", "brain", "heart",
	]
	for icon_name in names:
		var cell := VBoxContainer.new()
		cell.alignment = BoxContainer.ALIGNMENT_CENTER
		var icon := LucideIcon.new()
		icon.icon_name = str(icon_name)
		icon.icon_size = 48.0
		icon.tint = Color("#222222")
		cell.add_child(icon)
		var label := Label.new()
		label.text = str(icon_name)
		label.add_theme_font_size_override("font_size", 11)
		label.add_theme_color_override("font_color", Color("#666666"))
		cell.add_child(label)
		grid.add_child(cell)
	await get_tree().create_timer(1.0).timeout
	var image := get_viewport().get_texture().get_image()
	if image.save_png(OUT) == OK:
		print("LUCIDE_VERIFY saved=", ProjectSettings.globalize_path(OUT))
	get_tree().quit(0)
