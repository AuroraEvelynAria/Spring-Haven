extends Control

## 角色工坊(CAS 式预览台,参考模拟人生「新建市民」的左右布局):
## 左列 = 角色选择 / 表情盘 / 表演测试 / 后端信息,右侧 = 大幅立绘实时预览。
## 纯表现层:走与 GameWorld 完全相同的立绘工厂(Live2DRig.create_for_role,
## 失败回退 PortraitRig2D)与同一套调用面(set_role/set_expression/
## set_thinking/speak/get_manifest_summary),不读写存档,不影响任何模拟状态。

const PORTRAIT_RIG_SCENE := preload("res://scenes/Portrait/PortraitRig2D.tscn")
const LIVE2D_RIG_SCRIPT := preload("res://scripts/ui/Live2DRig.gd")
const MAIN_MENU_SCENE := "res://scenes/MainMenu/MainMenu.tscn"

# 语义表情词表:与 PortraitRig2D.EXPRESSIONS / Live2DRig 默认映射同源
const EXPRESSIONS := ["neutral", "happy", "worried", "angry", "shy", "tired", "thinking"]
const EXPRESSION_LABELS := {
	"neutral": "平静", "happy": "开心", "worried": "担忧", "angry": "生气",
	"shy": "害羞", "tired": "倦意", "thinking": "思考",
}
const ROLE_LABELS := {"ling": "小玲", "nai": "小奈"}
const PREVIEW_SIZE := Vector2(620, 740)

var _current_role := "ling"
var _current_expression := "neutral"
var _rig: Control = null
var _rig_holder: Control
var _role_buttons: Dictionary = {}
var _swatch_buttons: Dictionary = {}
var _thinking_toggle: CheckButton
var _info_label: Label

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_background()
	_build_layout()
	_set_role("ling")

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		UI.switch_scene(MAIN_MENU_SCENE)

func _exit_tree() -> void:
	# Live2D 的挂起纪律与 GameWorld 面板一致:退场前先停渲染再释放
	if is_instance_valid(_rig) and _rig.has_method("set_active"):
		_rig.call("set_active", false)

# ===== 结构 =====

func _build_background() -> void:
	var data := ThemeMgr.get_current_theme_data()
	var bg := ColorRect.new()
	bg.name = "Background"
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(str(data.bg))
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

func _build_layout() -> void:
	var data := ThemeMgr.get_current_theme_data()
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)

	# 顶栏:标题 + 返回
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	column.add_child(header)
	var title := Label.new()
	title.text = "✦ 角色工坊"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(data.primary, 0.95))
	header.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "· 立绘与表情预览"
	subtitle.add_theme_font_size_override("font_size", 13)
	subtitle.add_theme_color_override("font_color", Color(data.secondary, 0.66))
	header.add_child(subtitle)
	var header_spacer := Control.new()
	header_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(header_spacer)
	var back_button := Button.new()
	back_button.text = "← 返回"
	back_button.custom_minimum_size = Vector2(96, 34)
	back_button.add_theme_font_size_override("font_size", 13)
	back_button.add_theme_color_override("font_color", Color(data.text, 0.9))
	back_button.pressed.connect(func(): UI.switch_scene(MAIN_MENU_SCENE))
	header.add_child(back_button)

	# 主体:左列(工坊面板) + 右侧(预览)
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 16)
	column.add_child(body)

	body.add_child(_build_side_panel())
	body.add_child(_build_preview_panel())

# ===== 左列 =====

func _build_side_panel() -> PanelContainer:
	var data := ThemeMgr.get_current_theme_data()
	var panel := PanelContainer.new()
	panel.name = "StudioSidePanel"
	panel.custom_minimum_size = Vector2(304, 0)
	panel.add_theme_stylebox_override(
		"panel", _panel_style(Color(data.text, 0.035), Color(data.text, 0.10), 14, 16)
	)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 12)
	panel.add_child(content)

	# 角色选择
	content.add_child(_section_title("角色"))
	var role_row := HBoxContainer.new()
	role_row.add_theme_constant_override("separation", 8)
	var role_group := ButtonGroup.new()
	for role_id in ["ling", "nai"]:
		var button := Button.new()
		button.text = str(ROLE_LABELS.get(role_id, role_id))
		button.toggle_mode = true
		button.button_group = role_group
		button.custom_minimum_size = Vector2(128, 36)
		button.add_theme_font_size_override("font_size", 13)
		button.add_theme_color_override("font_color", Color(data.text, 0.88))
		button.pressed.connect(func(): _set_role(role_id))
		_role_buttons[role_id] = button
		role_row.add_child(button)
	content.add_child(role_row)

	# 表情盘
	content.add_child(_section_title("表情"))
	var swatch_grid := GridContainer.new()
	swatch_grid.name = "ExpressionSwatches"
	swatch_grid.columns = 4
	swatch_grid.add_theme_constant_override("h_separation", 6)
	swatch_grid.add_theme_constant_override("v_separation", 6)
	var swatch_group := ButtonGroup.new()
	for expression in EXPRESSIONS:
		var swatch := Button.new()
		swatch.text = str(EXPRESSION_LABELS.get(expression, expression))
		swatch.toggle_mode = true
		swatch.button_group = swatch_group
		swatch.custom_minimum_size = Vector2(64, 32)
		swatch.add_theme_font_size_override("font_size", 12)
		swatch.add_theme_color_override("font_color", Color(data.text, 0.85))
		swatch.pressed.connect(func(): _apply_expression(expression))
		_swatch_buttons[expression] = swatch
		swatch_grid.add_child(swatch)
	content.add_child(swatch_grid)

	# 表演测试
	content.add_child(_section_title("表演"))
	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 8)
	var speak_button := Button.new()
	speak_button.text = "▶ 说话"
	speak_button.custom_minimum_size = Vector2(96, 34)
	speak_button.add_theme_font_size_override("font_size", 12)
	speak_button.add_theme_color_override("font_color", Color(data.text, 0.88))
	speak_button.pressed.connect(func():
		if is_instance_valid(_rig):
			_rig.call("speak", "主人，今天也见到你了呢。", 3.0)
	)
	action_row.add_child(speak_button)
	_thinking_toggle = CheckButton.new()
	_thinking_toggle.text = "思考中…"
	_thinking_toggle.add_theme_font_size_override("font_size", 12)
	_thinking_toggle.add_theme_color_override("font_color", Color(data.text, 0.85))
	_thinking_toggle.toggled.connect(func(active: bool):
		if is_instance_valid(_rig):
			_rig.call("set_thinking", active)
	)
	action_row.add_child(_thinking_toggle)
	content.add_child(action_row)

	# 后端信息
	content.add_child(_section_title("后端"))
	_info_label = Label.new()
	_info_label.name = "BackendInfo"
	_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_label.add_theme_font_size_override("font_size", 11)
	_info_label.add_theme_color_override("font_color", Color(data.secondary, 0.78))
	content.add_child(_info_label)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(spacer)
	return panel

# ===== 右侧预览 =====

func _build_preview_panel() -> PanelContainer:
	var data := ThemeMgr.get_current_theme_data()
	var panel := PanelContainer.new()
	panel.name = "StudioPreviewPanel"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override(
		"panel", _panel_style(Color(data.text, 0.02), Color(data.text, 0.08), 16, 12)
	)
	var center := CenterContainer.new()
	panel.add_child(center)
	# 立绘挂架:固定取景框(上半身构图),Live2D 与 2D 立绘都按满框渲染
	_rig_holder = Control.new()
	_rig_holder.name = "RigHolder"
	_rig_holder.custom_minimum_size = PREVIEW_SIZE
	_rig_holder.clip_contents = true
	center.add_child(_rig_holder)
	return panel

# ===== 行为 =====

func _set_role(role_id: String) -> void:
	if role_id not in ["ling", "nai"]:
		return
	_current_role = role_id
	for key in _role_buttons:
		var button: Button = _role_buttons[key]
		button.set_pressed_no_signal(key == role_id)
	_replace_rig()

func _apply_expression(expression: String) -> void:
	if expression not in EXPRESSIONS:
		return
	_current_expression = expression
	if is_instance_valid(_rig):
		_rig.call("set_expression", expression)

## 立绘重建:与 GameWorld 同一条工厂路径——Live2D 可用且该角色有模型则
## Live2DRig,否则 PortraitRig2D;两个后端共享同一调用面。
func _replace_rig() -> void:
	if is_instance_valid(_rig):
		if _rig.has_method("set_active"):
			_rig.call("set_active", false)
		_rig.queue_free()
		_rig = null
	var live2d_rig: Control = LIVE2D_RIG_SCRIPT.create_for_role(_current_role)
	_rig = live2d_rig if live2d_rig != null else PORTRAIT_RIG_SCENE.instantiate()
	_rig.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rig_holder.add_child(_rig)
	_rig.call("set_expression", _current_expression)
	_refresh_info()

func _refresh_info() -> void:
	if not is_instance_valid(_info_label):
		return
	var data := ThemeMgr.get_current_theme_data()
	var model_path: String = LIVE2D_RIG_SCRIPT.model_path_for_role(_current_role)
	var lines: Array[String] = []
	if model_path.is_empty():
		lines.append("立绘后端: 程序化立绘 (2D)")
	else:
		lines.append("立绘后端: Live2D (Cubism)")
		lines.append("模型: %s" % model_path.get_file())
	lines.append("表情词表: %d 个语义表情" % EXPRESSIONS.size())
	if is_instance_valid(_rig) and _rig.has_method("get_manifest_summary"):
		var summary: Dictionary = _rig.call("get_manifest_summary")
		var shown := 0
		for key in summary:
			if shown >= 6:
				break
			lines.append("%s: %s" % [str(key), str(summary[key])])
			shown += 1
	_info_label.text = "\n".join(lines)
	_info_label.add_theme_color_override("font_color", Color(data.secondary, 0.78))

# ===== 样式(与 dashboard 同源:text 派生,不写死白色) =====

func _panel_style(bg: Color, border: Color, radius: int, margin: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.set_corner_radius_all(radius)
	style.set_border_width_all(1)
	style.border_color = border
	style.content_margin_left = margin
	style.content_margin_right = margin
	style.content_margin_top = margin * 0.75
	style.content_margin_bottom = margin * 0.75
	return style

func _section_title(text_value: String) -> Label:
	var data := ThemeMgr.get_current_theme_data()
	var title := Label.new()
	title.text = text_value
	title.add_theme_font_size_override("font_size", 11)
	title.add_theme_color_override("font_color", Color(data.primary, 0.72))
	return title
