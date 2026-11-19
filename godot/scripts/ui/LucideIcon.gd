class_name LucideIcon
extends Label

## Lucide 图标字体的轻封装:按图标名(sparkles/settings/leaf…)渲染单色字形。
## 2424 枚矢量图标、ISC 许可、零贴图导入;字形天生单色,颜色由 tint 控制,
## 随主题/悬停态换色零成本。图标名→码点映射在 lucide-codepoints.json
## (构建时打包为只读字典),查不到的名字画占位方块并报一次警告。

const FONT_PATH := "res://assets/fonts/lucide.ttf"
const CODEPOINTS_PATH := "res://assets/fonts/lucide-codepoints.json"

static var _font: FontFile
static var _codepoints: Dictionary
static var _warned_missing: Dictionary = {}


static func icon_char(icon_name: String) -> String:
	_ensure_loaded()
	var code := int(_codepoints.get(icon_name.strip_edges().to_lower(), 0))
	if code <= 0:
		if not _warned_missing.has(icon_name):
			_warned_missing[icon_name] = true
			push_warning("LucideIcon: unknown icon name %s" % icon_name)
		return String.chr(0xFFFD)
	return String.chr(code)


static func _ensure_loaded() -> void:
	if _font != null and not _codepoints.is_empty():
		return
	if _font == null:
		_font = load(FONT_PATH) as FontFile
		if _font == null:
			push_error("LucideIcon: lucide.ttf failed to load")
			_engine_fallback()
			return
	if _codepoints.is_empty():
		var raw := FileAccess.get_file_as_string(CODEPOINTS_PATH)
		var parsed: Variant = JSON.parse_string(raw)
		if parsed is Dictionary:
			_codepoints = parsed


static func _engine_fallback() -> void:
	_font = ThemeDB.fallback_font


@export var icon_name := "":
	set(value):
		icon_name = value
		_apply_icon()


@export var icon_size := 18.0:
	set(value):
		icon_size = value
		_apply_icon()


@export var tint := Color(0, 0, 0, 0):
	set(value):
		tint = value
		_explicit_tint = value.a > 0.0
		add_theme_color_override("font_color", tint if _explicit_tint else _theme_color())


var _explicit_tint := false


func _ready() -> void:
	horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_font_override("font", _load_font())
	_apply_icon()


func set_icon(value: String) -> void:
	icon_name = value


func _apply_icon() -> void:
	if not is_inside_tree():
		return
	text = icon_char(icon_name)
	add_theme_font_size_override("font_size", int(round(icon_size)))
	if not _explicit_tint:
		add_theme_color_override("font_color", _theme_color())


func _theme_color() -> Color:
	return Color(str(ThemeMgr.get_current_theme_data().get("secondary", "#A79B90")))


func _load_font() -> FontFile:
	_ensure_loaded()
	if _font == null:
		_engine_fallback()
	return _font
