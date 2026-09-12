extends RefCounted
## 设置面板共享 UI 工具集：无状态纯静态函数，不访问 autoload、不持有控件引用。
## 根脚本与后续分节脚本统一经 preload 常量调用。

static func style(background: Color, border: Color, radius: int, margin: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.content_margin_left = margin
	style.content_margin_right = margin
	style.content_margin_top = margin
	style.content_margin_bottom = margin
	return style

static func section_label(text: String, data: Dictionary) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", Color(data.text, 0.84))
	return label

static func contrast_ratio(a: Color, b: Color) -> float:
	var l1 := relative_luminance(a)
	var l2 := relative_luminance(b)
	return (maxf(l1, l2) + 0.05) / (minf(l1, l2) + 0.05)

static func relative_luminance(color: Color) -> float:
	var r := color.r / 12.92 if color.r <= 0.03928 else pow((color.r + 0.055) / 1.055, 2.4)
	var g := color.g / 12.92 if color.g <= 0.03928 else pow((color.g + 0.055) / 1.055, 2.4)
	var b := color.b / 12.92 if color.b <= 0.03928 else pow((color.b + 0.055) / 1.055, 2.4)
	return 0.2126 * r + 0.7152 * g + 0.0722 * b

static func updates_to_dictionary(updates: Array) -> Dictionary:
	var result := {}
	for update_variant in updates:
		if not update_variant is Array or update_variant.size() < 2:
			continue
		result[str(update_variant[0])] = float(update_variant[1])
	return result

static func format_delta(value: float) -> String:
	return ("+" if value > 0.0 else "") + "%.1f" % value

static func short_save_id(save_id: String) -> String:
	if save_id.length() <= 12:
		return save_id
	return "%s…%s" % [save_id.left(8), save_id.right(4)]

static func rag_spin(
	grid: GridContainer, label_text: String, value: Variant, minimum: int, maximum: int
) -> SpinBox:
	var label := Label.new()
	label.text = label_text
	grid.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = 1
	spin.value = float(value)
	spin.custom_minimum_size = Vector2(92, 32)
	grid.add_child(spin)
	return spin

static func labeled_line_edit(
	grid: GridContainer, label_text: String, value: String, placeholder: String
) -> LineEdit:
	var label := Label.new()
	label.text = label_text
	grid.add_child(label)
	var input := LineEdit.new()
	input.text = value
	input.placeholder_text = placeholder
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(input)
	return input

static func apply_content_readability(node: Node, data: Dictionary) -> void:
	var text_color := Color(data.text)
	var secondary_color := Color(data.secondary, 0.96)
	if node is Label and not (node as Label).has_theme_color_override("font_color"):
		(node as Label).add_theme_color_override("font_color", text_color)
	elif node is CheckBox:
		var checkbox := node as CheckBox
		checkbox.add_theme_color_override("font_color", text_color)
		checkbox.add_theme_color_override("font_hover_color", text_color)
		checkbox.add_theme_color_override("font_pressed_color", text_color)
		checkbox.add_theme_color_override("font_hover_pressed_color", text_color)
		checkbox.add_theme_color_override("font_disabled_color", secondary_color)
	for child in node.get_children():
		apply_content_readability(child, data)
