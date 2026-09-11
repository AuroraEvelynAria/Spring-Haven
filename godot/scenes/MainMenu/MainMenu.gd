extends Control

const SETTINGS_SCENE := preload("res://scenes/Settings/SettingsPanel.tscn")
const SETTINGS_PANEL_SCRIPT := preload("res://scenes/Settings/SettingsPanel.gd")
const JOURNEY_LIBRARY_SCENE := preload("res://scenes/JourneyLibrary/JourneyLibraryPanel.tscn")
const GLOW_SHADER := preload("res://shaders/glow.gdshader")
const TITLE_SHADER := preload("res://shaders/gradient_text.gdshader")
const BACKGROUND_SHADER := preload("res://shaders/menu_background.gdshader")

var _content: VBoxContainer
var _title: Label
var _subtitle: Label
var _start_button: Button
var _new_game_button: Button
var _journey_library_button: Button
var _life_lab_button: Button
var _settings_button: Button
var _version: Label
var _glow: ColorRect
var _background: ColorRect
var _settings: SETTINGS_PANEL_SCRIPT
var _journey_library: JourneyLibraryPanel
var _new_game_confirmation: ConfirmationDialog
var _save_error_dialog: AcceptDialog
var _model_setup_dialog: ConfirmationDialog
var _core_startup_dialog: AcceptDialog
var _model_setup_checked := false
var _particles: Array = []
var _rng := RandomNumberGenerator.new()
var _intro_tween: Tween

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rng.seed = 20260718
	_initialize_particles()
	_build_background()
	_build_glow()
	_build_menu()
	_settings = SETTINGS_SCENE.instantiate() as SETTINGS_PANEL_SCRIPT
	add_child(_settings)
	_journey_library = JOURNEY_LIBRARY_SCENE.instantiate() as JourneyLibraryPanel
	_journey_library.journey_selected.connect(_on_journey_selected)
	_journey_library.new_journey_requested.connect(_on_named_new_journey)
	add_child(_journey_library)
	Global.theme_changed.connect(_on_theme_changed)
	Global.font_size_changed.connect(_on_font_size_changed)
	Global.save_catalog_changed.connect(_refresh_active_journey_hint)
	_refresh_active_journey_hint()
	_animate_intro()
	Audio.play_default_music()
	_check_first_run_model_setup.call_deferred()

func _initialize_particles() -> void:
	_particles.clear()
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		viewport_size = Vector2(1280, 720)
	for index in 72:
		_particles.append({
			"position": Vector2(_rng.randf_range(0.0, viewport_size.x), _rng.randf_range(0.0, viewport_size.y)),
			"speed": _rng.randf_range(5.0, 18.0),
			"radius": _rng.randf_range(0.6, 1.8),
			"alpha": _rng.randf_range(0.08, 0.32),
			"phase": _rng.randf_range(0.0, TAU)
		})
func _process(delta: float) -> void:
	var viewport_size := get_viewport_rect().size
	for particle in _particles:
		particle.position.y -= particle.speed * delta
		particle.position.x += sin(Time.get_ticks_msec() * 0.0004 + particle.phase) * delta * 3.0
		if particle.position.y < -8.0:
			particle.position.y = viewport_size.y + 8.0
		if particle.position.x < -8.0:
			particle.position.x = viewport_size.x + 8.0
		elif particle.position.x > viewport_size.x + 8.0:
			particle.position.x = -8.0
	queue_redraw()

func _draw() -> void:
	var data := ThemeMgr.get_current_theme_data()
	for particle in _particles:
		var alpha: float = float(particle.alpha) * (0.78 + sin(Time.get_ticks_msec() * 0.001 + float(particle.phase)) * 0.22)
		draw_circle(particle.position, float(particle.radius), Color(data.primary, alpha))

func _build_background() -> void:
	_background = ColorRect.new()
	_background.name = "AnimatedBackground"
	_background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var material := ShaderMaterial.new()
	material.shader = BACKGROUND_SHADER
	_background.material = material
	add_child(_background)

func _build_glow() -> void:
	_glow = ColorRect.new()
	_glow.name = "CenterGlow"
	_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glow.size = Vector2(600, 600)
	_glow.position = get_viewport_rect().size / 2.0 - _glow.size / 2.0
	var material := ShaderMaterial.new()
	material.shader = GLOW_SHADER
	material.set_shader_parameter("glow_color", Color(ThemeMgr.get_current_theme_data().primary, 0.14))
	material.set_shader_parameter("radius", 0.62)
	_glow.material = material
	add_child(_glow)

func _build_menu() -> void:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_content = VBoxContainer.new()
	_content.name = "MenuContent"
	_content.alignment = BoxContainer.ALIGNMENT_CENTER
	_content.add_theme_constant_override("separation", 12)
	_content.mouse_filter = Control.MOUSE_FILTER_PASS
	center.add_child(_content)

	_title = Label.new()
	_title.text = "✦ 春日庭院 ✦"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title.custom_minimum_size = Vector2(560, 78)
	_title.add_theme_font_size_override("font_size", 56)
	_title.add_theme_constant_override("outline_size", 0)
	var title_material := ShaderMaterial.new()
	title_material.shader = TITLE_SHADER
	_title.material = title_material
	_content.add_child(_title)

	_subtitle = Label.new()
	_subtitle.text = "双生  ·  絮语  ·  陪伴"
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle.add_theme_font_size_override("font_size", 16)
	_subtitle.custom_minimum_size = Vector2(0, 28)
	_content.add_child(_subtitle)

	var menu := VBoxContainer.new()
	menu.name = "MenuButtons"
	menu.alignment = BoxContainer.ALIGNMENT_CENTER
	menu.add_theme_constant_override("separation", 12)
	_content.add_child(menu)

	_start_button = _make_menu_button("🌸 继续旅程", true)
	_start_button.name = "StartButton"
	_start_button.pressed.connect(_on_start_pressed)
	menu.add_child(_start_button)
	_new_game_button = _make_menu_button("↻ 新旅程", false)
	_new_game_button.name = "NewGameButton"
	_new_game_button.pressed.connect(_on_new_game_pressed)
	menu.add_child(_new_game_button)
	_journey_library_button = _make_menu_button("📚 旅程档案", false)
	_journey_library_button.name = "JourneyLibraryButton"
	_journey_library_button.pressed.connect(_on_journey_library_pressed)
	menu.add_child(_journey_library_button)
	_life_lab_button = _make_menu_button("🍡 团子生活实验室", false)
	_life_lab_button.name = "LifeLabButton"
	_life_lab_button.pressed.connect(_on_life_lab_pressed)
	menu.add_child(_life_lab_button)
	_settings_button = _make_menu_button("⚙️ 设置", false)
	_settings_button.name = "SettingsButton"
	_settings_button.pressed.connect(_on_settings_pressed)
	menu.add_child(_settings_button)
	_new_game_confirmation = ConfirmationDialog.new()
	_new_game_confirmation.title = "开始新旅程"
	_new_game_confirmation.dialog_text = "当前旅程会完整保留。新旅程将使用独立的对话、属性、生活状态与心织记忆作用域。"
	_new_game_confirmation.ok_button_text = "开始新旅程"
	_new_game_confirmation.cancel_button_text = "取消"
	_new_game_confirmation.confirmed.connect(_start_new_game)
	add_child(_new_game_confirmation)
	_save_error_dialog = AcceptDialog.new()
	_save_error_dialog.title = "无法使用本地存档"
	_save_error_dialog.ok_button_text = "知道了"
	add_child(_save_error_dialog)
	_model_setup_dialog = ConfirmationDialog.new()
	_model_setup_dialog.title = "连接聊天模型"
	_model_setup_dialog.dialog_text = (
		"本地 Companion Core 已就绪，但还没有可用的聊天模型。\n"
		+ "配置 OpenAI-compatible 服务后即可与小玲和小奈对话。"
	)
	_model_setup_dialog.ok_button_text = "打开模型设置"
	_model_setup_dialog.cancel_button_text = "稍后"
	_model_setup_dialog.confirmed.connect(_open_model_settings)
	add_child(_model_setup_dialog)
	_core_startup_dialog = AcceptDialog.new()
	_core_startup_dialog.title = "Companion Core 未启动"
	_core_startup_dialog.ok_button_text = "知道了"
	_core_startup_dialog.add_button("📂 打开游戏目录", true, "open_game_directory")
	_core_startup_dialog.custom_action.connect(_on_core_startup_dialog_action)
	add_child(_core_startup_dialog)

	_version = Label.new()
	_version.text = "v0.6.0  ·  双团子生活实验室"
	_version.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_version.add_theme_font_size_override("font_size", 12)
	_version.add_theme_color_override("font_color", Color(1, 1, 1, 0.28))
	_version.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_version.offset_top = -38
	_version.offset_bottom = -18
	add_child(_version)
	_update_visuals()

func _make_menu_button(text: String, filled: bool) -> Button:
	var data := ThemeMgr.get_current_theme_data()
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(200, 50)
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	button.add_theme_font_size_override("font_size", 16)
	button.add_theme_color_override("font_color", Color.WHITE if filled else Color(data.text))
	button.add_theme_color_override("font_hover_color", Color.WHITE)
	button.add_theme_stylebox_override("normal", _menu_style(filled, false))
	button.add_theme_stylebox_override("hover", _menu_style(filled, true))
	button.add_theme_stylebox_override("pressed", _menu_style(false, true))
	button.mouse_entered.connect(func(): _scale_button(button, 1.03))
	button.mouse_exited.connect(func(): _scale_button(button, 1.0))
	return button

func _menu_style(filled: bool, hover: bool) -> StyleBoxFlat:
	var data := ThemeMgr.get_current_theme_data()
	var primary := Color(data.primary)
	var style := StyleBoxFlat.new()
	style.set_corner_radius_all(40)
	style.set_border_width_all(1)
	style.border_color = primary if filled or hover else Color(data.text, 0.16)
	style.bg_color = primary if filled and not hover else Color(primary, 0.18 if hover else 0.07)
	style.content_margin_left = 30
	style.content_margin_right = 30
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	return style

func _animate_intro() -> void:
	await get_tree().process_frame
	var target_position := _content.position
	_content.modulate.a = 0.0
	_content.position = target_position + Vector2(0, 30)
	_intro_tween = create_tween().set_parallel(true)
	_intro_tween.tween_property(_content, "modulate:a", 1.0, 1.2).set_ease(Tween.EASE_OUT)
	_intro_tween.tween_property(_content, "position", target_position, 1.2).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)

func _scale_button(button: Button, scale_value: float) -> void:
	var tween := create_tween()
	tween.tween_property(button, "scale", Vector2(scale_value, scale_value), 0.18).set_ease(Tween.EASE_OUT)

func _on_start_pressed() -> void:
	if not Global.is_state_loaded():
		_show_save_error(Global.get_last_save_error())
		return
	_set_navigation_disabled(true)
	CompanionCore.set_save_id(Global.get_active_save_id())
	_enter_game_world()

func _on_new_game_pressed() -> void:
	_new_game_confirmation.popup_centered(Vector2i(520, 210))

func _start_new_game(display_name := "") -> void:
	_set_navigation_disabled(true)
	var local_result: Dictionary = Global.reset_default_state(display_name)
	if not bool(local_result.get("ok", false)):
		_set_navigation_disabled(false)
		_show_save_error(str(local_result.get("message", "无法写入新存档")))
		return
	var previous_save_id := str(local_result.get("previous_save_id", ""))
	CompanionCore.set_save_id(Global.get_active_save_id())
	if CompanionCore.has_credentials() and not previous_save_id.is_empty():
		var reset_result: Dictionary = await CompanionCore.reset_session(previous_save_id)
		if not bool(reset_result.get("ok", false)):
			push_warning("旧 Companion Core 即时会话暂未清理，将由后续维护处理")
	_enter_game_world()

func _on_named_new_journey(display_name: String) -> void:
	_start_new_game(display_name)

func _on_journey_library_pressed() -> void:
	_journey_library.show_panel()

func _on_journey_selected(target_save_id: String) -> void:
	_set_navigation_disabled(true)
	var result: Dictionary = Global.load_save_slot(target_save_id)
	if not bool(result.get("ok", false)):
		_set_navigation_disabled(false)
		_show_save_error(str(result.get("message", "无法载入旅程")))
		return
	CompanionCore.set_save_id(Global.get_active_save_id())
	_enter_game_world()

func _refresh_active_journey_hint() -> void:
	if not is_instance_valid(_start_button):
		return
	for slot in Global.list_save_slots(true):
		if bool(slot.get("active", false)):
			_start_button.tooltip_text = "继续：%s" % str(slot.get("display_name", "当前旅程"))
			return
	_start_button.tooltip_text = "继续当前旅程"

func _set_navigation_disabled(disabled: bool) -> void:
	if _start_button:
		_start_button.disabled = disabled
	if _new_game_button:
		_new_game_button.disabled = disabled
	if _journey_library_button:
		_journey_library_button.disabled = disabled
	if _settings_button:
		_settings_button.disabled = disabled
	if _life_lab_button:
		_life_lab_button.disabled = disabled

func _show_save_error(message: String) -> void:
	var detail := message.strip_edges()
	if detail.is_empty():
		detail = "本地存档不可用。你可以检查磁盘权限，或明确开始一段新旅程。"
	_save_error_dialog.dialog_text = detail
	_save_error_dialog.popup_centered(Vector2i(560, 220))

func _enter_game_world() -> void:
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 0.35)
	await tween.finished
	UI.switch_scene("res://scenes/GameWorld/GameWorld.tscn")

func _on_settings_pressed() -> void:
	_settings.show_panel()

func _open_model_settings() -> void:
	_settings.show_panel("ai")

func _check_first_run_model_setup() -> void:
	if _model_setup_checked:
		return
	_model_setup_checked = true
	# Windows Defender 首扫 python 运行时可能远超 12s；新装的本地运行时放宽等待窗口。
	var deadline_ms := 12000
	if bool(CompanionCore.get_managed_core_status().get("runtime_created", false)):
		deadline_ms = 45000
	var deadline := Time.get_ticks_msec() + deadline_ms
	while not CompanionCore.is_active() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.25).timeout
	if not CompanionCore.is_active():
		_show_core_startup_failure()
		return
	var result: Dictionary = await CompanionCore.get_provider_status()
	if not bool(result.get("ok", false)):
		return
	var provider_data = result.get("data", {})
	if provider_data is Dictionary and not bool((provider_data as Dictionary).get("api_key_configured", false)):
		_model_setup_dialog.popup_centered(Vector2i(540, 220))

func _show_core_startup_failure() -> void:
	if not is_instance_valid(_core_startup_dialog):
		return
	var managed: Dictionary = CompanionCore.get_managed_core_status()
	var detail := str(managed.get("runtime_error", "")).strip_edges()
	if detail.is_empty():
		detail = str(managed.get("last_error", "")).strip_edges()
	if detail.is_empty():
		detail = "Core 在启动时限内没有返回健康状态"
	_core_startup_dialog.dialog_text = (
		"本地对话核心没有启动，聊天和记忆暂时不可用。\n\n"
		+ detail
		+ "\n\n请确认 companion-core 文件夹完整，并检查 Windows 安全中心是否隔离了运行文件。"
	)
	_core_startup_dialog.popup_centered(Vector2i(590, 280))

func _on_core_startup_dialog_action(action: StringName) -> void:
	if action != &"open_game_directory":
		return
	OS.shell_open(OS.get_executable_path().get_base_dir())

func _on_life_lab_pressed() -> void:
	if not Global.is_state_loaded():
		_show_save_error(Global.get_last_save_error())
		return
	_set_navigation_disabled(true)
	UI.switch_scene("res://scenes/LifeLab/LifeLabWorld.tscn")

func _on_theme_changed(_data: Dictionary) -> void:
	_update_visuals()
	queue_redraw()

func _on_font_size_changed(size: int) -> void:
	if _title:
		_title.add_theme_font_size_override("font_size", maxi(42, size + 41))
	if _subtitle:
		_subtitle.add_theme_font_size_override("font_size", size + 1)
	if _start_button:
		_start_button.add_theme_font_size_override("font_size", size + 1)
	if _new_game_button:
		_new_game_button.add_theme_font_size_override("font_size", size + 1)
	if _settings_button:
		_settings_button.add_theme_font_size_override("font_size", size + 1)
	if _life_lab_button:
		_life_lab_button.add_theme_font_size_override("font_size", size + 1)

func _update_visuals() -> void:
	if not _title:
		return
	var data := ThemeMgr.get_current_theme_data()
	_version.add_theme_color_override("font_color", Color(data.secondary, 0.32))
	var material := _title.material as ShaderMaterial
	if material:
		material.set_shader_parameter("color_a", Color(data.primary))
		material.set_shader_parameter("color_b", Color(data.accent))
	if _background and _background.material is ShaderMaterial:
		var background_material := _background.material as ShaderMaterial
		var bg := Color(data.bg)
		background_material.set_shader_parameter("color_top", bg.lightened(0.055 if bool(data.is_dark) else 0.025))
		background_material.set_shader_parameter("color_bottom", bg.darkened(0.055 if bool(data.is_dark) else 0.025))
		background_material.set_shader_parameter("color_glow", Color(data.primary))
	if _glow and _glow.material is ShaderMaterial:
		var glow_material := _glow.material as ShaderMaterial
		glow_material.set_shader_parameter("glow_color", Color(data.primary, 0.14))
	if _start_button:
		_start_button.add_theme_color_override("font_color", Color.WHITE)
		_start_button.add_theme_stylebox_override("normal", _menu_style(true, false))
		_start_button.add_theme_stylebox_override("hover", _menu_style(true, true))
	if _settings_button:
		_settings_button.add_theme_color_override("font_color", Color(data.text))
		_settings_button.add_theme_stylebox_override("normal", _menu_style(false, false))
		_settings_button.add_theme_stylebox_override("hover", _menu_style(false, true))
	if _new_game_button:
		_new_game_button.add_theme_color_override("font_color", Color(data.text))
		_new_game_button.add_theme_stylebox_override("normal", _menu_style(false, false))
		_new_game_button.add_theme_stylebox_override("hover", _menu_style(false, true))
	if _life_lab_button:
		_life_lab_button.add_theme_color_override("font_color", Color(data.text))
		_life_lab_button.add_theme_stylebox_override("normal", _menu_style(false, false))
		_life_lab_button.add_theme_stylebox_override("hover", _menu_style(false, true))

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _glow:
		_glow.position = get_viewport_rect().size / 2.0 - _glow.size / 2.0
		var viewport_size := get_viewport_rect().size
		for particle in _particles:
			particle.position.x = fposmod(float(particle.position.x), maxf(1.0, viewport_size.x))
			particle.position.y = fposmod(float(particle.position.y), maxf(1.0, viewport_size.y))
