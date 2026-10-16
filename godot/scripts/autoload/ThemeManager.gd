extends Node

const DEFAULT_FONT_PATH := "res://assets/fonts/LXGWWenKai-Regular.ttf"

# 语义色 token:全局固定,不随主题变化(统一全 UI 的成功/警告/危险/信息色)
const SEMANTIC_SUCCESS := Color("#4CAF7D")
const SEMANTIC_WARNING := Color("#D9A441")
const SEMANTIC_DANGER := Color("#E25B5B")
const SEMANTIC_INFO := Color("#5B8DEF")

static func semantic(kind: String) -> Color:
	match kind:
		"success": return SEMANTIC_SUCCESS
		"warning": return SEMANTIC_WARNING
		"danger": return SEMANTIC_DANGER
	return SEMANTIC_INFO

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
	"stardust": {"bg": "#0A0A14", "primary": "#8B8BC0", "accent": "#C8C8E8", "text": "#E8E8F0", "secondary": "#9898B0", "is_dark": true},
	# UI v3 预览稿(春日庭院UI-v3-预览.html)的官方 token:明昼(奶油木)与夜话
	"haru": {"bg": "#F6F1E7", "primary": "#C96B2E", "accent": "#9E4E1B", "text": "#33291F", "secondary": "#6B5D4C", "is_dark": false},
	"haru_night": {"bg": "#171521", "primary": "#E8935C", "accent": "#D9B36A", "text": "#EAE4D8", "secondary": "#B5AA9A", "is_dark": true}
}

var current_theme_name := "amber"
var current_theme_data: Dictionary = {}
var current_theme: Theme
var default_font: Font

func _ready() -> void:
	if ResourceLoader.exists(DEFAULT_FONT_PATH):
		default_font = load(DEFAULT_FONT_PATH)
	# Window 家族(对话框 / PopupMenu / 工具提示)是独立视口,**不继承 root 主题**,
	# 不逐个指派就整体落在 Godot 默认深色主题上(浅色应用里弹出黑盒子/深色下拉)。
	get_tree().node_added.connect(_on_node_added)
	await get_tree().process_frame
	_apply_global_font(get_tree().root)

func _on_node_added(node: Node) -> void:
	if node is Window and current_theme != null:
		(node as Window).theme = current_theme

## 把当前主题补派给树里已存在的 Window(切换主题时调用;新窗口由 node_added 兜住)
func _apply_theme_to_windows(node: Node) -> void:
	if node is Window and current_theme != null:
		(node as Window).theme = current_theme
	for child in node.get_children():
		_apply_theme_to_windows(child)

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

	# 表面色必须由 text 派生(text 与 bg 天然对立):原先写死的白色半透明
	# Color(1,1,1,0.055) 在浅色主题上**完全隐形**——输入框与下拉框因此看起来
	# 只是裸文字、没有任何可点击的形体。
	var button_normal := _style(Color(text, 0.05), Color(text, 0.12), 18, 14, 7)
	var button_hover := _style(Color(primary, 0.16), primary, 18, 14, 7)
	var button_pressed := _style(Color(primary, 0.25), primary, 18, 14, 7)
	theme.set_stylebox("normal", "Button", button_normal)
	theme.set_stylebox("hover", "Button", button_hover)
	theme.set_stylebox("pressed", "Button", button_pressed)
	# disabled 不覆盖会跌回默认主题的灰色方块,任何被禁用的按钮都会突兀地
	# 变成"web 灰盒";取 normal 同款造型再淡一档,安静地退到背景里。
	theme.set_stylebox("disabled", "Button", _style(Color(text, 0.03), Color(text, 0.07), 18, 14, 7))
	# 焦点框必须隐形:Godot 在鼠标点击后也会保留焦点,若 focus 样式可见,
	# 每个点过的按钮都会挂着一个描边框直到点别处——是"网页感"的最大来源。
	# 悬停/按压样式已足够给鼠标反馈;LineEdit 例外,文本输入需要可见焦点。
	var no_focus := StyleBoxEmpty.new()
	for focus_type in ["Button", "OptionButton", "CheckBox", "CheckButton", "MenuButton"]:
		theme.set_stylebox("focus", focus_type, no_focus)
	theme.set_stylebox("normal", "LineEdit", _style(Color(text, 0.05), Color(text, 0.12), 22, 16, 9))
	theme.set_stylebox("focus", "LineEdit", _style(Color(text, 0.07), primary, 22, 16, 9))
	theme.set_stylebox("normal", "OptionButton", _style(Color(text, 0.05), Color(text, 0.12), 10, 10, 6))
	theme.set_stylebox("panel", "Panel", _style(Color(text, 0.05), Color(text, 0.1), 14, 12, 10))
	theme.set_stylebox("panel", "PopupPanel", _style(bg, Color(text, 0.22), 10, 12, 12))
	theme.set_stylebox("panel", "PopupMenu", _style(bg, Color(text, 0.22), 10, 8, 7))
	theme.set_stylebox("hover", "PopupMenu", _style(Color(primary, 0.16), primary, 7, 8, 5))
	theme.set_constant("separation", "HBoxContainer", 8)
	theme.set_constant("separation", "VBoxContainer", 8)

	# ── 对话框(Window 家族)──────────────────────────────────────────
	# ConfirmationDialog / AcceptDialog 是独立 Window,不套用普通 Control 的控件
	# 样式:不显式覆盖就整体落回 Godot 默认**深色**主题——浅色应用里弹出一个黑盒子
	# (旅程档案的"新建旅程"、主菜单的"新旅程"确认等全部命中)。这里按当前主题的
	# 底色重建面板与标题色。
	var dialog_panel := _style(bg, Color(text, 0.20), 12, 18, 16)
	for window_type in ["Window", "AcceptDialog", "ConfirmationDialog"]:
		theme.set_stylebox("embedded_border", window_type, dialog_panel)
		theme.set_stylebox("panel", window_type, dialog_panel)
		theme.set_color("title_color", window_type, text)

	# ── 滚动条 ─────────────────────────────────────────────────────
	# 不覆盖同样是默认样式(粗轨道 + 两端小箭头),在浅色界面里非常突兀。轨道留白、
	# 滑块用正文色的低透明度;两端箭头图标用零尺寸占位贴图隐去(改用滚轮/拖拽)。
	var scroll_track := _style(Color(text, 0.05), Color.TRANSPARENT, 8, 0, 0)
	var scroll_grabber := _style(Color(text, 0.18), Color.TRANSPARENT, 8, 0, 0)
	var scroll_grabber_hot := _style(Color(primary, 0.40), Color.TRANSPARENT, 8, 0, 0)
	var no_arrow := PlaceholderTexture2D.new()
	no_arrow.size = Vector2i.ZERO
	for scroll_type in ["VScrollBar", "HScrollBar"]:
		theme.set_stylebox("scroll", scroll_type, scroll_track)
		theme.set_stylebox("scroll_focus", scroll_type, scroll_track)
		theme.set_stylebox("grabber", scroll_type, scroll_grabber)
		theme.set_stylebox("grabber_highlight", scroll_type, scroll_grabber_hot)
		theme.set_stylebox("grabber_pressed", scroll_type, scroll_grabber_hot)
		for arrow in [
			"increment", "increment_highlight", "increment_pressed",
			"decrement", "decrement_highlight", "decrement_pressed",
		]:
			theme.set_icon(arrow, scroll_type, no_arrow)

	get_tree().root.theme = theme
	current_theme = theme
	_apply_theme_to_windows(get_tree().root)
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
