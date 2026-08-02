extends Node

const DEFAULT_FONT_PATH := "res://assets/fonts/LXGWWenKai-Regular.ttf"

const THEMES := {
	"graphite": {"bg": "#F8F6F3", "primary": "#E8743C", "accent": "#2D2A24", "text": "#1A1715", "secondary": "#5A5550", "is_dark": false},
	"aurora": {"bg": "#F5F0F8", "primary": "#5BC0BE", "accent": "#4A3F5C", "text": "#3A2F4A", "secondary": "#6A5F7A", "is_dark": false},
	"slate": {"bg": "#EDEEF0", "primary": "#4A90D9", "accent": "#2C3E50", "text": "#1A2A3A", "secondary": "#4A5A6A", "is_dark": false},
	"carbon": {"bg": "#1A1715", "primary": "#6CC4A1", "accent": "#C4BDB5", "text": "#EDE8E0", "secondary": "#A09888", "is_dark": true},
	"nocturne": {"bg": "#14101A", "primary": "#C9A8D4", "accent": "#E8E0F0", "text": "#EDE8F0", "secondary": "#A098B0", "is_dark": true},
	"amber": {"bg": "#1A120E", "primary": "#F5A97F", "accent": "#E8C97A", "text": "#EDE0D0", "secondary": "#A09080", "is_dark": true},
	"wisteria": {"bg": "#100E1A", "primary": "#B8A6D9", "accent": "#E8D5F0", "text": "#EDE8F5", "secondary": "#A098B8", "is_dark": true},
	"sakura": {"bg": "#FDF5F7", "primary": "#E8A0BF", "accent": "#D4C5C9", "text": "#3A2A30", "secondary": "#7A5A6A", "is_dark": false},
	"mint": {"bg": "#F0F5F2", "primary": "#7EC8B0", "accent": "#3A7A5A", "text": "#1A2A22", "secondary": "#4A6A5A", "is_dark": false},
	"ocean": {"bg": "#0A0F14", "primary": "#6B9EC4", "accent": "#A8D8EA", "text": "#E8EEF5", "secondary": "#98A8B8", "is_dark": true},
	"dusk": {"bg": "#1A0F0F", "primary": "#C06C6C", "accent": "#E8C97A", "text": "#EDD8D0", "secondary": "#A08880", "is_dark": true},
	"stardust": {"bg": "#0A0A14", "primary": "#8B8BC0", "accent": "#C8C8E8", "text": "#E8E8F0", "secondary": "#9898B0", "is_dark": true}
}

var current_theme_name := "amber"
var current_theme_data: Dictionary = {}
var default_font: Font

func _ready() -> void:
	if ResourceLoader.exists(DEFAULT_FONT_PATH):
		default_font = load(DEFAULT_FONT_PATH)
	await get_tree().process_frame
	_apply_global_font(get_tree().root)

func _apply_global_font(node: Node) -> void:
	if node is Control and default_font and not node.has_theme_font_override("font"):
		node.add_theme_font_override("font", default_font)
	for child in node.get_children():
		_apply_global_font(child)

func apply_theme(theme_name: String) -> void:
	if theme_name == "custom":
		apply_custom_theme(str(Settings.settings.ui.custom_bg), str(Settings.settings.ui.custom_primary), str(Settings.settings.ui.custom_accent))
		return
	if not THEMES.has(theme_name):
		theme_name = "amber"
	current_theme_name = theme_name
	current_theme_data = THEMES[theme_name].duplicate(true)
	_apply_theme_resource(current_theme_data)

func apply_custom_theme(bg: String, primary: String, accent: String) -> void:
	var bg_color := Color(bg)
	var is_dark := _luminance(bg_color) < 0.4
	current_theme_name = "custom"
	current_theme_data = {
		"bg": bg,
		"primary": primary,
		"accent": accent,
		"text": "#EDE8E0" if is_dark else "#1A1715",
		"secondary": "#A09888" if is_dark else "#5A5550",
		"is_dark": is_dark
	}
	_apply_theme_resource(current_theme_data)

func _apply_theme_resource(data: Dictionary) -> void:
	var theme := Theme.new()
	if default_font:
		theme.default_font = _get_selected_font()
	theme.default_font_size = int(Settings.settings.ui.font_size)
	var bg := Color(data.bg)
	var primary := Color(data.primary)
	var accent := Color(data.accent)
	var text := Color(data.text)
	var secondary := Color(data.secondary)

	for type_name in ["Label", "Button", "LineEdit", "OptionButton", "CheckBox", "PopupMenu"]:
		theme.set_color("font_color", type_name, text)
		theme.set_color("font_hover_color", type_name, Color.WHITE if data.is_dark else text)
		theme.set_color("font_disabled_color", type_name, Color(secondary, 0.96))
	theme.set_color("font_placeholder_color", "LineEdit", Color(secondary, 0.96))
	theme.set_color("font_uneditable_color", "LineEdit", Color(secondary, 0.96))
	theme.set_color("font_focus_color", "LineEdit", text)
	theme.set_color("font_pressed_color", "Button", Color.WHITE)

	var button_normal := _style(Color(1, 1, 1, 0.055), Color(1, 1, 1, 0.12), 18, 14, 7)
	var button_hover := _style(Color(primary, 0.16), primary, 18, 14, 7)
	var button_pressed := _style(Color(primary, 0.25), primary, 18, 14, 7)
	theme.set_stylebox("normal", "Button", button_normal)
	theme.set_stylebox("hover", "Button", button_hover)
	theme.set_stylebox("pressed", "Button", button_pressed)
	theme.set_stylebox("focus", "Button", button_hover)
	theme.set_stylebox("normal", "LineEdit", _style(Color(1, 1, 1, 0.055), Color(1, 1, 1, 0.12), 22, 16, 9))
	theme.set_stylebox("focus", "LineEdit", _style(Color(1, 1, 1, 0.08), primary, 22, 16, 9))
	theme.set_stylebox("normal", "OptionButton", _style(Color(1, 1, 1, 0.055), Color(1, 1, 1, 0.12), 10, 10, 6))
	theme.set_stylebox("panel", "Panel", _style(Color(1, 1, 1, 0.055), Color(1, 1, 1, 0.1), 14, 12, 10))
	theme.set_stylebox("panel", "PopupPanel", _style(bg, Color(text, 0.22), 10, 12, 12))
	theme.set_stylebox("panel", "PopupMenu", _style(bg, Color(text, 0.22), 10, 8, 7))
	theme.set_stylebox("hover", "PopupMenu", _style(Color(primary, 0.16), primary, 7, 8, 5))
	theme.set_constant("separation", "HBoxContainer", 8)
	theme.set_constant("separation", "VBoxContainer", 8)
	get_tree().root.theme = theme
	get_tree().root.set_meta("theme_data", current_theme_data)
	Global.theme_changed.emit(current_theme_data)

func _style(background: Color, border: Color, radius: int, margin_x: int, margin_y: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.content_margin_left = margin_x
	style.content_margin_right = margin_x
	style.content_margin_top = margin_y
	style.content_margin_bottom = margin_y
	return style

func _luminance(color: Color) -> float:
	return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b

func _get_selected_font() -> Font:
	match str(Settings.settings.ui.get("font_family", "system")):
		"serif":
			return load("res://assets/fonts/LXGWWenKai-Light.ttf")
		"modern":
			return load("res://assets/fonts/LXGWWenKai-Medium.ttf")
		"mono":
			return load("res://assets/fonts/LXGWWenKaiMono-Regular.ttf")
		"wenkai":
			return default_font
		_:
			# Bundled fonts have deterministic glyph atlases. SystemFont can briefly
			# render black blocks after a viewport resize on the compatibility renderer.
			return default_font

func get_theme_keys() -> Array:
	return THEMES.keys()

func get_theme_data(theme_name: String) -> Dictionary:
	if theme_name == "custom":
		return current_theme_data
	return THEMES.get(theme_name, THEMES.amber)

func get_current_theme_data() -> Dictionary:
	return current_theme_data if not current_theme_data.is_empty() else THEMES.amber
