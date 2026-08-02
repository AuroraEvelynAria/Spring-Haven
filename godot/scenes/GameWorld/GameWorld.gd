extends Control

const SETTINGS_SCENE := preload("res://scenes/Settings/SettingsPanel.tscn")
const ARCHIVE_SCENE := preload("res://scenes/ConversationArchive/ConversationArchivePanel.tscn")
const MEMORY_NETWORK_SCENE := preload("res://scenes/MemoryNetwork/MemoryNetworkPanel.tscn")
const PORTRAIT_RIG_SCENE := preload("res://scenes/Portrait/PortraitRig2D.tscn")
const EXPLORATION_SCENE_PATH := "res://scenes/Exploration/ExplorationWorld.tscn"
const GLOW_SHADER := preload("res://shaders/glow.gdshader")
const GLASS_SHADER := preload("res://shaders/glass.gdshader")
const THINKING_STRIP_SHADER := preload("res://shaders/thinking_strip.gdshader")
const INTERACTION_RULES := preload("res://scripts/domain/InteractionRules.gd")
const LIFE_PERSONALITY := preload("res://scripts/domain/LifePersonalityProfiles.gd")
const RECIPIENT_RESOLVER := preload("res://scripts/domain/ConversationRecipientResolver.gd")
const TEXT_SANITIZER := preload("res://scripts/domain/TextSanitizer.gd")
const SHARED_HISTORY_LIMIT := 24
const UI_MESSAGE_LIMIT := 72
const STAT_TWEEN_DURATION := 0.58
const TYPEWRITER_MIN_CPS := 42.0
const TYPEWRITER_MAX_SECONDS := 4.8
const AFFECTION_ACTIONS := ["hug", "kiss", "sex", "comfort", "praise"]
const AFFECTION_STAT_KEYS := ["intimacy", "mood", "arousal", "climax"]
const THINKING_STEP_SECONDS := 0.42
const CONVERSATION_VISIBILITY_PROTOCOL := "spring_heaven.conversation_visibility.v1"
const ACTION_BUTTON_LABELS := {
	"hug": "🤗 拥抱", "kiss": "💋 亲吻", "eat": "🍗 喂食",
	"drink": "💧 喂水", "sleep": "🛏️ 休息", "sex": "💞 做爱"
}

const ROLE_DATA := {
	"ling": {
		"name": "小玲", "full_name": "春日 鈴音", "icon": "🐾", "sub": "猫娘 · 21岁", "mood": "☀️ 暖洋洋", "color": "#F5A97F",
		"diary": "“主人呀……刚才眯了一会儿，梦到小鱼干了。醒了发现你还在，比梦好。”",
		"diary_footer": "—— 小玲 · 午后"
	},
	"nai": {
		"name": "小奈", "full_name": "白瀬 雪奈", "icon": "🐇", "sub": "兔娘 · 19岁", "mood": "🌸 活力满满", "color": "#B8A6D9",
		"diary": "“嗯～今天排练的时候一直在想主人，跳错了好几个拍子。回来看到主人在，就对了。”",
		"diary_footer": "—— 雪奈 · 傍晚"
	}
}

const STAT_DEFS := {
	"health": {"icon": "❤️", "label": "健康", "warning": "low", "threshold": 25.0},
	"stamina": {"icon": "⚡", "label": "体力", "warning": "low", "threshold": 20.0},
	"hunger": {"icon": "🍗", "label": "饥饿", "warning": "high", "threshold": 80.0},
	"thirst": {"icon": "💧", "label": "口渴", "warning": "high", "threshold": 80.0},
	"awake": {"icon": "😴", "label": "清醒度", "warning": "low", "threshold": 20.0},
	"urine": {"icon": "💦", "label": "膀胱充盈", "warning": "high", "threshold": 85.0},
	"intimacy": {"icon": "💞", "label": "好感度", "warning": "low", "threshold": 20.0},
	"mood": {"icon": "🧠", "label": "心情", "warning": "low", "threshold": 30.0},
	"stress": {"icon": "😰", "label": "压力", "warning": "high", "threshold": 75.0},
	"fertility": {"icon": "❤️‍🔥", "label": "内膜容受性", "warning": "high", "threshold": 70.0},
	"implantation": {"icon": "🛡️", "label": "服药后着床倾向", "warning": "high", "threshold": 100.0},
	"arousal": {"icon": "💕", "label": "亲密温度", "warning": "high", "threshold": 90.0},
	"climax": {"icon": "🌊", "label": "亲密浪潮", "warning": "high", "threshold": 80.0}
}

var _current_role := "ling"
var _role_revision := 0
var _stats_by_role: Dictionary = {}
var _network_waiting := false
var _typewriter_active := false
var _typewriter_skip_requested := false
var _thinking_elapsed := 0.0
var _thinking_dot_phase := 0
var _thinking_visual_elapsed := 0.0
var _thinking_strip_visibility := 0.0
var _intro_active := false
var _scene_exiting := false
var _suppress_exit_persistence := false
var _particles: Array = []
var _rng := RandomNumberGenerator.new()
var _pending_roles: Dictionary = {}
var _foreground_scope_tokens: Dictionary = {}
var _message_nodes: Array[Dictionary] = []
var _conversation_history: Array[Dictionary] = []
var _message_views: Dictionary = {}
var _waiting_nodes: Dictionary = {}
var _stat_widgets: Dictionary = {}
var _stat_tweens: Dictionary = {}
var _stat_pulse_tweens: Dictionary = {}
var _pending_full_effects: Dictionary = {}
var _last_action_event: Dictionary = {}

var _glow: ColorRect
var _nav: PanelContainer
var _brand: Label
var _connection_status: Label
var _memory_status: Label
var _memory_state := "idle"
var _memory_pulse_elapsed := 0.0
var _ling_button: Button
var _nai_button: Button
var _explore_button: Button
var _archive_button: Button
var _memory_network_button: Button
var _settings_button: Button
var _menu_button: Button
var _role_switch_panel: PanelContainer
var _main_layout: BoxContainer
var _chat_area: VBoxContainer
var _chat_scroll: ScrollContainer
var _chat_list: VBoxContainer
var _input_panel: PanelContainer
var _input_panel_style: StyleBoxFlat
var _thinking_strip: ColorRect
var _thinking_strip_material: ShaderMaterial
var _action_bar: HFlowContainer
var _chat_input: LineEdit
var _recipient_hint: Label
var _voice_button: Button
var _voice_status: Label
var _send_button: Button
var _sidebar: ScrollContainer
var _sidebar_content: HFlowContainer
var _portrait_rig: Control
var _life_status_clock: Label
var _life_status_cadence: Label
var _life_status_elapsed := 0.0
var _log_bar: PanelContainer
var _log_label: Label
var _settings: Control
var _archive_panel: Control
var _memory_network_panel: Control

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rng.randomize()
	_stats_by_role = Global.stats_by_role
	_conversation_history = Global.conversation_history
	_current_role = Global.current_character if ROLE_DATA.has(Global.current_character) else "ling"
	_initialize_background_particles()
	_build_background_glow()
	_build_interface()
	_settings = SETTINGS_SCENE.instantiate()
	add_child(_settings)
	_archive_panel = ARCHIVE_SCENE.instantiate()
	add_child(_archive_panel)
	_memory_network_panel = MEMORY_NETWORK_SCENE.instantiate()
	add_child(_memory_network_panel)
	Global.theme_changed.connect(_on_theme_changed)
	Global.font_size_changed.connect(_on_font_size_changed)
	CompanionCore.reply_received.connect(_on_core_reply)
	CompanionCore.request_failed.connect(_on_core_request_failed)
	CompanionCore.health_changed.connect(_on_core_health_changed)
	CompanionCore.memory_status_changed.connect(_on_memory_status_changed)
	VoiceInput.recording_changed.connect(_on_voice_recording_changed)
	VoiceInput.transcription_started.connect(_on_voice_transcription_started)
	VoiceInput.transcription_ready.connect(_on_voice_transcription_ready)
	VoiceInput.transcription_failed.connect(_on_voice_transcription_failed)
	Multimodal.tts_audio_ready.connect(_on_tts_audio_ready)
	Global.life_stat_changed.connect(_on_life_stat_changed)
	LifeSim.proactive_message.connect(_on_proactive_message)
	LifeSim.autonomous_action.connect(_on_life_autonomous_action)
	LifeSim.ambient_dialogue_message.connect(_on_ambient_dialogue_message)
	LifeSim.menstrual_cycle_changed.connect(_on_menstrual_cycle_changed)
	LifeSim.menstrual_phase_changed.connect(_on_menstrual_phase_changed)
	get_viewport().size_changed.connect(_on_viewport_size_changed)
	CompanionCore.set_save_id(Global.get_active_save_id())
	_apply_responsive_layout()
	_switch_role(_current_role, false, false)
	if _conversation_history.is_empty():
		_add_system_message("✦ 絮语开始 ✦")
		_intro_sequence()
	else:
		_restore_conversation_ui()
		_add_system_message("✦ 已恢复上次的絮语 ✦")
		_refresh_interaction_state()
	if CompanionCore.has_credentials():
		_update_core_status(
			"已连接" if CompanionCore.is_active() else "连接中",
			Color(ThemeMgr.get_current_theme_data().primary if CompanionCore.is_active() else ThemeMgr.get_current_theme_data().secondary)
		)
		CompanionCore.connect_to_core()
	else:
		_update_core_status("离线 · 未配置 Core 密钥", Color("#D9534F"))
		_add_system_message("Companion Core 未配置：消息不会由本地文本冒充 AI 回复。")

func _process(delta: float) -> void:
	var viewport_size := get_viewport_rect().size
	for particle in _particles:
		particle.position.y -= particle.speed * delta
		particle.position.x += sin(Time.get_ticks_msec() * 0.00035 + particle.phase) * delta * 2.0
		if particle.position.y < -6.0:
			particle.position.y = viewport_size.y + 6.0
			particle.position.x = _rng.randf_range(0.0, maxf(1.0, viewport_size.x))
		elif particle.position.x < -8.0:
			particle.position.x = viewport_size.x + 8.0
		elif particle.position.x > viewport_size.x + 8.0:
			particle.position.x = -8.0
	if _network_waiting:
		_thinking_elapsed += delta
		if _thinking_elapsed >= THINKING_STEP_SECONDS:
			_thinking_elapsed = fmod(_thinking_elapsed, THINKING_STEP_SECONDS)
			_thinking_dot_phase = (_thinking_dot_phase + 1) % 3
			_update_thinking_indicators()
	else:
		_thinking_elapsed = 0.0
		_thinking_dot_phase = 0
	_update_thinking_visuals(delta)
	if _memory_state in ["queued", "processing", "waiting"] and is_instance_valid(_memory_status):
		_memory_pulse_elapsed += delta
		_memory_status.modulate.a = 0.68 + 0.30 * sin(_memory_pulse_elapsed * 3.2)
	elif is_instance_valid(_memory_status):
		_memory_pulse_elapsed = 0.0
		_memory_status.modulate.a = 1.0
	_life_status_elapsed += delta
	if _life_status_elapsed >= 30.0:
		_life_status_elapsed = fmod(_life_status_elapsed, 30.0)
		_update_life_status_time()
	queue_redraw()

func _input(event: InputEvent) -> void:
	if not _typewriter_active or not event.is_pressed():
		return
	var input_has_focus := is_instance_valid(_chat_input) and _chat_input.has_focus()
	var should_skip: bool = event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT
	if should_skip and is_instance_valid(_chat_input):
		should_skip = not _chat_input.get_global_rect().has_point(event.position)
	if event is InputEventKey:
		should_skip = (
			event.keycode == KEY_ESCAPE
			or (not input_has_focus and event.keycode in [KEY_SPACE, KEY_ENTER, KEY_KP_ENTER])
		)
	if should_skip:
		_typewriter_skip_requested = true
		get_viewport().set_input_as_handled()

func _exit_tree() -> void:
	_scene_exiting = true
	_typewriter_skip_requested = true
	if _suppress_exit_persistence:
		for request_id_variant in _pending_roles.keys():
			CompanionCore.discard_request(str(request_id_variant))
		_pending_roles.clear()
		_network_waiting = false
		return
	var history_changed := false
	for request_id_variant in _pending_roles.keys():
		var request_id := str(request_id_variant)
		var pending: Dictionary = _pending_roles[request_id]
		var history_id := str(pending.get("history_id", ""))
		if not history_id.is_empty():
			if Global.update_conversation_entry(history_id, {
				"status": "failed",
				"error": "离开对话页面，请重试",
				"retryable": true
			}, false):
				history_changed = true
		CompanionCore.discard_request(request_id)
	_pending_roles.clear()
	_network_waiting = false
	for token_variant in _foreground_scope_tokens.values():
		MessageScheduler.end_foreground(str(token_variant))
	_foreground_scope_tokens.clear()
	if history_changed:
		Global.save_default_state()

func _draw() -> void:
	var data := ThemeMgr.get_current_theme_data()
	var viewport_size := get_viewport_rect().size
	var bg := Color(data.bg)
	draw_rect(Rect2(Vector2.ZERO, viewport_size), bg)
	draw_circle(viewport_size * Vector2(0.48, 0.52), 430.0, Color(data.primary, 0.025))
	for particle in _particles:
		var alpha: float = float(particle.alpha) * (0.8 + sin(Time.get_ticks_msec() * 0.001 + float(particle.phase)) * 0.2)
		draw_circle(particle.position, float(particle.radius), Color(data.primary, alpha))

func _build_background_glow() -> void:
	_glow = ColorRect.new()
	_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glow.size = Vector2(620, 620)
	var material := ShaderMaterial.new()
	material.shader = GLOW_SHADER
	material.set_shader_parameter("glow_color", Color(ThemeMgr.get_current_theme_data().primary, 0.09))
	material.set_shader_parameter("radius", 0.64)
	_glow.material = material
	add_child(_glow)

func _initialize_background_particles() -> void:
	_particles.clear()
	var viewport_size := get_viewport_rect().size
	for _index in 54:
		_particles.append({
			"position": Vector2(
				_rng.randf_range(0.0, maxf(1.0, viewport_size.x)),
				_rng.randf_range(0.0, maxf(1.0, viewport_size.y))
			),
			"speed": _rng.randf_range(4.0, 14.0),
			"radius": _rng.randf_range(0.6, 1.7),
			"alpha": _rng.randf_range(0.06, 0.24),
			"phase": _rng.randf_range(0.0, TAU)
		})

func _stats_for_role(role: String) -> Dictionary:
	if not ROLE_DATA.has(role):
		role = "ling"
	var stats := Global.get_role_stats(role)
	_stats_by_role = Global.stats_by_role
	return stats

func _current_stats() -> Dictionary:
	return _stats_for_role(_current_role)

func _build_interface() -> void:
	var root_vbox := VBoxContainer.new()
	root_vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_vbox.add_theme_constant_override("separation", 0)
	add_child(root_vbox)
	_build_nav(root_vbox)

	_main_layout = BoxContainer.new()
	_main_layout.vertical = false
	_main_layout.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_main_layout.add_theme_constant_override("separation", 0)
	root_vbox.add_child(_main_layout)
	_build_chat_area(_main_layout)
	_build_sidebar(_main_layout)
	_build_log_bar(root_vbox)

func _build_nav(parent: VBoxContainer) -> void:
	var data := ThemeMgr.get_current_theme_data()
	_nav = PanelContainer.new()
	_nav.custom_minimum_size = Vector2(0, 52)
	_nav.add_theme_stylebox_override("panel", _panel_style(Color(1, 1, 1, 0.035), Color(data.text, 0.08), 0, 0))
	_nav.material = _glass_material(data, 2.0)
	parent.add_child(_nav)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	_nav.add_child(margin)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	margin.add_child(row)

	_brand = Label.new()
	_brand.text = "✦  春日庭院"
	_brand.add_theme_font_size_override("font_size", 14)
	_brand.add_theme_color_override("font_color", Color(data.primary))
	_brand.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_brand)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	_connection_status = Label.new()
	_connection_status.name = "ConnectionStatus"
	_connection_status.add_theme_font_size_override("font_size", 11)
	_connection_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_connection_status)
	_memory_status = Label.new()
	_memory_status.name = "MemoryStatus"
	_memory_status.text = "🧶 心织记忆 · 待命"
	_memory_status.tooltip_text = "独立 Heartloom SQLite 记忆尚无召回记录"
	_memory_status.add_theme_font_size_override("font_size", 11)
	_memory_status.add_theme_color_override("font_color", Color(data.secondary, 0.70))
	_memory_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_memory_status)
	_memory_network_button = Button.new()
	_memory_network_button.text = "🕸️"
	_memory_network_button.tooltip_text = "打开心织记忆网络"
	_memory_network_button.flat = true
	_memory_network_button.custom_minimum_size = Vector2(38, 34)
	_memory_network_button.pressed.connect(func(): _memory_network_panel.show_panel())
	row.add_child(_memory_network_button)

	_explore_button = Button.new()
	_explore_button.text = "🌿 小玲 3D"
	_explore_button.tooltip_text = "进入客餐厅探索样板"
	_explore_button.flat = true
	_explore_button.custom_minimum_size = Vector2(86, 34)
	_explore_button.pressed.connect(_open_exploration)
	row.add_child(_explore_button)

	_role_switch_panel = PanelContainer.new()
	_role_switch_panel.add_theme_stylebox_override("panel", _panel_style(Color(1, 1, 1, 0.045), Color(data.text, 0.08), 18, 3))
	row.add_child(_role_switch_panel)
	var roles := HBoxContainer.new()
	roles.add_theme_constant_override("separation", 3)
	_role_switch_panel.add_child(roles)
	_ling_button = _role_button("🐾 小玲", "ling")
	_nai_button = _role_button("🐇 小奈", "nai")
	roles.add_child(_ling_button)
	roles.add_child(_nai_button)

	_archive_button = Button.new()
	_archive_button.text = "📚"
	_archive_button.tooltip_text = "聊天归档"
	_archive_button.flat = true
	_archive_button.custom_minimum_size = Vector2(38, 34)
	_archive_button.pressed.connect(func(): _archive_panel.show_panel())
	row.add_child(_archive_button)

	_settings_button = Button.new()
	_settings_button.text = "🎨"
	_settings_button.tooltip_text = "设置与开发者选项"
	_settings_button.flat = true
	_settings_button.custom_minimum_size = Vector2(38, 34)
	_settings_button.pressed.connect(func(): _settings.show_panel())
	row.add_child(_settings_button)
	_menu_button = Button.new()
	_menu_button.text = "⏻"
	_menu_button.tooltip_text = "返回主菜单"
	_menu_button.flat = true
	_menu_button.custom_minimum_size = Vector2(38, 34)
	_menu_button.pressed.connect(_back_to_menu)
	row.add_child(_menu_button)

func _role_button(text: String, role: String) -> Button:
	var button := Button.new()
	button.name = "Role_%s" % role
	button.text = text
	button.toggle_mode = true
	button.custom_minimum_size = Vector2(84, 28)
	button.add_theme_font_size_override("font_size", 12)
	button.pressed.connect(func(): _select_reply_role(role))
	return button

func _build_chat_area(parent: BoxContainer) -> void:
	_chat_area = VBoxContainer.new()
	_chat_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chat_area.add_theme_constant_override("separation", 0)
	parent.add_child(_chat_area)
	_chat_scroll = ScrollContainer.new()
	_chat_scroll.name = "ChatScroll"
	_chat_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chat_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_chat_area.add_child(_chat_scroll)
	var chat_margin := MarginContainer.new()
	chat_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chat_margin.add_theme_constant_override("margin_left", 18)
	chat_margin.add_theme_constant_override("margin_right", 18)
	chat_margin.add_theme_constant_override("margin_top", 14)
	chat_margin.add_theme_constant_override("margin_bottom", 8)
	_chat_scroll.add_child(chat_margin)
	_chat_list = VBoxContainer.new()
	_chat_list.name = "ChatList"
	_chat_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_list.add_theme_constant_override("separation", 12)
	chat_margin.add_child(_chat_list)
	_build_input_area()

func _build_input_area() -> void:
	var data := ThemeMgr.get_current_theme_data()
	_input_panel = PanelContainer.new()
	_input_panel_style = _panel_style(Color(1, 1, 1, 0.035), Color(data.text, 0.08), 0, 0)
	_input_panel.add_theme_stylebox_override("panel", _input_panel_style)
	_input_panel.material = _glass_material(data, 1.8)
	_chat_area.add_child(_input_panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 14)
	_input_panel.add_child(margin)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 6)
	margin.add_child(content)
	_thinking_strip = ColorRect.new()
	_thinking_strip.name = "ThinkingStrip"
	_thinking_strip.custom_minimum_size = Vector2(0, 3)
	_thinking_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_thinking_strip.visible = false
	_thinking_strip_material = ShaderMaterial.new()
	_thinking_strip_material.shader = THINKING_STRIP_SHADER
	_thinking_strip.material = _thinking_strip_material
	content.add_child(_thinking_strip)
	_action_bar = HFlowContainer.new()
	_action_bar.add_theme_constant_override("h_separation", 5)
	_action_bar.add_theme_constant_override("v_separation", 5)
	content.add_child(_action_bar)
	for key in ACTION_BUTTON_LABELS:
		var button := Button.new()
		button.name = "Action_%s" % key
		button.text = ACTION_BUTTON_LABELS[key]
		button.set_meta("action_id", str(key))
		button.set_meta("idle_text", str(ACTION_BUTTON_LABELS[key]))
		button.custom_minimum_size = Vector2(70, 27)
		button.add_theme_font_size_override("font_size", 12)
		var action := str(key)
		button.pressed.connect(func(): _apply_action(action))
		_action_bar.add_child(button)

	var input_row := HBoxContainer.new()
	input_row.add_theme_constant_override("separation", 10)
	content.add_child(input_row)
	_chat_input = LineEdit.new()
	_chat_input.name = "ChatInput"
	_chat_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_input.custom_minimum_size = Vector2(0, 40)
	_chat_input.add_theme_font_size_override("font_size", 14)
	_chat_input.caret_blink = false
	_apply_chat_input_theme(data)
	_chat_input.text_submitted.connect(func(_text: String): _send_message())
	_chat_input.text_changed.connect(_on_chat_input_changed)
	input_row.add_child(_chat_input)
	_voice_button = Button.new()
	_voice_button.name = "VoiceInputButton"
	_voice_button.text = "🎙️"
	_voice_button.tooltip_text = "开始语音输入"
	_voice_button.custom_minimum_size = Vector2(44, 40)
	_voice_button.add_theme_font_size_override("font_size", 18)
	_voice_button.add_theme_stylebox_override(
		"normal", _panel_style(Color(data.text, 0.055), Color(data.text, 0.16), 8, 6)
	)
	_voice_button.add_theme_stylebox_override(
		"hover", _panel_style(Color(data.primary, 0.14), Color(data.primary, 0.45), 8, 6)
	)
	_voice_button.pressed.connect(_toggle_voice_input)
	input_row.add_child(_voice_button)
	_send_button = Button.new()
	_send_button.name = "SendButton"
	_send_button.text = "发送"
	_send_button.custom_minimum_size = Vector2(112, 40)
	_send_button.add_theme_color_override("font_color", Color.WHITE)
	_send_button.add_theme_stylebox_override("normal", _filled_button_style(false))
	_send_button.add_theme_stylebox_override("hover", _filled_button_style(true))
	_send_button.pressed.connect(_send_message)
	input_row.add_child(_send_button)
	var hint_row := HBoxContainer.new()
	hint_row.add_theme_constant_override("separation", 8)
	content.add_child(hint_row)
	_recipient_hint = Label.new()
	_recipient_hint.name = "RecipientHint"
	_recipient_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_recipient_hint.add_theme_font_size_override("font_size", 10)
	_recipient_hint.add_theme_color_override("font_color", Color(data.text, 0.72))
	hint_row.add_child(_recipient_hint)
	_voice_status = Label.new()
	_voice_status.name = "VoiceInputStatus"
	_voice_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_voice_status.add_theme_font_size_override("font_size", 10)
	_voice_status.add_theme_color_override("font_color", Color(data.secondary, 0.96))
	hint_row.add_child(_voice_status)
	_update_recipient_hint()

func _build_sidebar(parent: BoxContainer) -> void:
	_sidebar = ScrollContainer.new()
	_sidebar.name = "StatusSidebar"
	_sidebar.custom_minimum_size = Vector2(340, 0)
	_sidebar.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_sidebar.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_sidebar.add_theme_stylebox_override("panel", _panel_style(Color(1, 1, 1, 0.025), Color(ThemeMgr.get_current_theme_data().text, 0.08), 0, 0))
	_sidebar.material = _glass_material(ThemeMgr.get_current_theme_data(), 2.0)
	parent.add_child(_sidebar)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 10)
	_sidebar.add_child(margin)
	_sidebar_content = HFlowContainer.new()
	_sidebar_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sidebar_content.add_theme_constant_override("h_separation", 6)
	_sidebar_content.add_theme_constant_override("v_separation", 10)
	margin.add_child(_sidebar_content)

func _build_log_bar(parent: VBoxContainer) -> void:
	var data := ThemeMgr.get_current_theme_data()
	_log_bar = PanelContainer.new()
	_log_bar.custom_minimum_size = Vector2(0, 26)
	_log_bar.add_theme_stylebox_override("panel", _panel_style(Color(1, 1, 1, 0.045), Color(data.text, 0.10), 0, 0))
	_log_bar.material = _glass_material(data, 1.4)
	parent.add_child(_log_bar)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 3)
	margin.add_theme_constant_override("margin_bottom", 3)
	_log_bar.add_child(margin)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	margin.add_child(row)
	_log_label = Label.new()
	_log_label.text = "📋   等待互动…"
	_log_label.add_theme_font_size_override("font_size", 11)
	_log_label.add_theme_color_override("font_color", Color(data.text, 0.92))
	_log_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_log_label)

func _refresh_sidebar() -> void:
	for active_tween in _stat_tweens.values():
		var tween := active_tween as Tween
		if tween and tween.is_valid():
			tween.kill()
	for pulse_key in _stat_pulse_tweens:
		var pulse_tween := _stat_pulse_tweens[pulse_key] as Tween
		if pulse_tween and pulse_tween.is_valid():
			pulse_tween.kill()
		if _stat_widgets.has(pulse_key):
			var pulse_bar := (_stat_widgets[pulse_key] as Dictionary).get("bar") as ProgressBar
			if is_instance_valid(pulse_bar):
				pulse_bar.scale = Vector2.ONE
	for stored_widget in _stat_widgets.values():
		var widget := stored_widget as Dictionary
		var warning_tween := widget.get("warning_tween") as Tween
		if warning_tween and warning_tween.is_valid():
			warning_tween.kill()
	_stat_tweens.clear()
	_stat_pulse_tweens.clear()
	_stat_widgets.clear()
	_portrait_rig = null
	for child in _sidebar_content.get_children():
		child.free()
	var role: Dictionary = ROLE_DATA[_current_role]
	_portrait_rig = PORTRAIT_RIG_SCENE.instantiate()
	_portrait_rig.name = "ActivePortraitRig"
	_portrait_rig.set_meta("sidebar_full_width", true)
	_sidebar_content.add_child(_portrait_rig)
	_portrait_rig.call("set_role", _current_role)
	_portrait_rig.call("set_body_state", LifeSim.build_role_state(_current_role))
	var profile := _profile_card(role)
	profile.set_meta("sidebar_full_width", true)
	_sidebar_content.add_child(profile)
	_sidebar_content.add_child(_life_status_card())
	_sidebar_content.add_child(_stat_group(
		"❤️‍🩹  生理体征",
		["health", "stamina", "hunger", "thirst", "awake", "urine"],
		Color("#62A887")
	))
	_sidebar_content.add_child(_cycle_card())
	_sidebar_content.add_child(_stat_group(
		"💭  情感状态",
		["intimacy", "mood", "stress"],
		Color("#78A3C2")
	))
	var intimate_keys: Array = ["arousal", "fertility", "implantation"]
	if float(_current_stats().get("arousal", 0.0)) >= 100.0:
		intimate_keys.append("climax")
	_sidebar_content.add_child(_stat_group(
		"💕  亲密状态",
		intimate_keys,
		Color("#D47C9B")
	))
	_sidebar_content.add_child(_diary_card(role))
	_sync_portrait_state()
	_apply_sidebar_card_widths()
	call_deferred("_flush_pending_full_effects")

func _sync_portrait_state(speaking_text := "") -> void:
	if not is_instance_valid(_portrait_rig):
		return
	_portrait_rig.call("set_body_state", LifeSim.build_role_state(_current_role))
	_portrait_rig.call("set_thinking", _is_role_waiting(_current_role))
	if not speaking_text.strip_edges().is_empty():
		_portrait_rig.call("speak", speaking_text)

func _is_role_waiting(role: String) -> bool:
	for pending_variant in _pending_roles.values():
		if pending_variant is Dictionary and str((pending_variant as Dictionary).get("role", "")) == role:
			return true
	return false

func _profile_card(role: Dictionary) -> PanelContainer:
	var data := ThemeMgr.get_current_theme_data()
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _panel_style(Color(data.primary, 0.07), Color(data.primary, 0.8), 16, 12))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	card.add_child(row)
	var avatar := Label.new()
	avatar.text = role.icon
	avatar.add_theme_font_size_override("font_size", 34)
	row.add_child(avatar)
	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 1)
	row.add_child(info)
	var name := Label.new()
	name.text = role.name
	name.add_theme_font_size_override("font_size", 17)
	name.add_theme_color_override("font_color", Color(data.primary))
	info.add_child(name)
	var sub := Label.new()
	sub.text = role.sub
	sub.add_theme_font_size_override("font_size", 11)
	sub.add_theme_color_override("font_color", Color(data.secondary))
	info.add_child(sub)
	var mood := Label.new()
	mood.text = role.mood
	mood.add_theme_font_size_override("font_size", 11)
	mood.add_theme_color_override("font_color", Color(data.secondary, 0.72))
	info.add_child(mood)
	return card

func _life_status_card() -> PanelContainer:
	var data := ThemeMgr.get_current_theme_data()
	var role_color := Color(str((ROLE_DATA[_current_role] as Dictionary).color))
	var roles_runtime = Global.life_runtime.get("roles", {})
	var role_runtime: Dictionary = (
		(roles_runtime as Dictionary).get(_current_role, {})
		if roles_runtime is Dictionary
		else {}
	)
	var intent_variant = role_runtime.get("current_intent", {})
	var intent: Dictionary = intent_variant if intent_variant is Dictionary else {}
	var intent_status := str(intent.get("status", ""))
	var is_active := intent_status in ["planned", "executing"]
	var description := str(intent.get("description", "")).strip_edges()
	if description.is_empty() or intent_status in ["failed", "expired"]:
		description = _life_event_label(str(role_runtime.get("last_life_event", "")))
	if description.is_empty():
		description = "%s正按自己的节奏生活" % str((ROLE_DATA[_current_role] as Dictionary).name)

	var card := PanelContainer.new()
	card.name = "LifeStatusCard"
	card.add_theme_stylebox_override(
		"panel",
		_panel_style(Color(role_color, 0.075), Color(role_color, 0.32), 14, 11)
	)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 5)
	card.add_child(content)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	content.add_child(header)
	var pulse := Label.new()
	pulse.text = "●"
	pulse.add_theme_font_size_override("font_size", 9)
	pulse.add_theme_color_override(
		"font_color",
		Color("#72C995") if is_active else Color(role_color, 0.86)
	)
	header.add_child(pulse)
	var title := Label.new()
	title.text = "正在生活" if is_active else "此刻生活"
	title.add_theme_font_size_override("font_size", 10)
	title.add_theme_color_override("font_color", Color(role_color, 0.92))
	header.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	_life_status_clock = Label.new()
	var local_time := Time.get_datetime_dict_from_system()
	_life_status_clock.text = "%02d:%02d" % [int(local_time.get("hour", 0)), int(local_time.get("minute", 0))]
	_life_status_clock.add_theme_font_size_override("font_size", 10)
	_life_status_clock.add_theme_color_override("font_color", Color(data.secondary, 0.58))
	header.add_child(_life_status_clock)

	var activity := Label.new()
	activity.text = description.left(54)
	activity.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	activity.add_theme_font_size_override("font_size", 11)
	activity.add_theme_color_override("font_color", Color(data.text, 0.88))
	content.add_child(activity)

	_life_status_cadence = Label.new()
	_life_status_cadence.text = "%s · %s" % [_day_period_label(int(local_time.get("hour", 0))), _life_cadence_label(role_runtime)]
	_life_status_cadence.add_theme_font_size_override("font_size", 9)
	_life_status_cadence.add_theme_color_override("font_color", Color(data.secondary, 0.58))
	content.add_child(_life_status_cadence)
	return card

func _cycle_card() -> PanelContainer:
	var data := ThemeMgr.get_current_theme_data()
	var state: Dictionary = LifeSim.build_menstrual_state(_current_role)
	var card := PanelContainer.new()
	card.name = "MenstrualCycleCard"
	var cycle_color := Color("#D96B84")
	card.add_theme_stylebox_override(
		"panel",
		_panel_style(Color(cycle_color, 0.08), Color(cycle_color, 0.42), 16, 11)
	)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 4)
	card.add_child(content)
	var title := Label.new()
	title.text = "🩸  生理周期"
	title.add_theme_font_size_override("font_size", 10)
	title.add_theme_color_override("font_color", Color(cycle_color, 0.86))
	content.add_child(title)
	if state.is_empty():
		var unavailable := Label.new()
		unavailable.text = "周期状态暂不可用"
		unavailable.add_theme_font_size_override("font_size", 11)
		unavailable.add_theme_color_override("font_color", Color(data.secondary, 0.62))
		content.add_child(unavailable)
		return card
	var phase := str(state.get("phase", "follicular"))
	var phase_line := Label.new()
	phase_line.text = "%s · 周期第 %d / %d 天" % [
		_cycle_phase_label(phase),
		int(state.get("cycle_day", 1)),
		int(state.get("cycle_length_days", 28)),
	]
	phase_line.add_theme_font_size_override("font_size", 12)
	phase_line.add_theme_color_override("font_color", Color(data.text, 0.92))
	content.add_child(phase_line)
	var detail := Label.new()
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if phase == "menstrual":
		detail.text = "经量 %s · 腹部不适 %s" % [
			_bleeding_label(str(state.get("bleeding", "none"))),
			_cramps_label(str(state.get("cramps", "none"))),
		]
	else:
		detail.text = "距下次经期 %d 天 · %s" % [
			int(state.get("days_until_next_period", 0)),
			"易孕窗口" if bool(state.get("fertile_window", false)) else "非易孕窗口",
		]
	detail.add_theme_font_size_override("font_size", 10)
	detail.add_theme_color_override("font_color", Color(data.secondary, 0.72))
	content.add_child(detail)
	return card

func _stat_group(title_text: String, keys: Array, accent: Color) -> PanelContainer:
	var data := ThemeMgr.get_current_theme_data()
	var card := PanelContainer.new()
	card.add_theme_stylebox_override(
		"panel",
		_panel_style(Color(accent, 0.045), Color(accent, 0.20), 14, 11)
	)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 5)
	card.add_child(content)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	content.add_child(header)
	var marker := ColorRect.new()
	marker.color = Color(accent, 0.82)
	marker.custom_minimum_size = Vector2(3, 13)
	marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(marker)
	var title := Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", 10)
	title.add_theme_color_override("font_color", Color(accent, 0.88))
	header.add_child(title)
	for key in keys:
		content.add_child(_stat_row(str(key)))
	return card

func _stat_row(key: String) -> HBoxContainer:
	var data := ThemeMgr.get_current_theme_data()
	var definition: Dictionary = STAT_DEFS[key]
	var value := float(_current_stats()[key])
	var row := HBoxContainer.new()
	row.name = "Stat_%s" % key
	row.add_theme_constant_override("separation", 8)
	var icon := Label.new()
	icon.text = definition.icon
	icon.custom_minimum_size = Vector2(18, 0)
	icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon.add_theme_font_size_override("font_size", 13)
	row.add_child(icon)
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 1)
	row.add_child(info)
	var label_row := HBoxContainer.new()
	info.add_child(label_row)
	var label := Label.new()
	label.text = definition.label
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", Color(data.secondary))
	label_row.add_child(label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label_row.add_child(spacer)
	var value_label := Label.new()
	value_label.name = "Value_%s" % key
	value_label.text = _stat_display_text(key, value)
	value_label.add_theme_font_size_override("font_size", 11)
	value_label.add_theme_color_override("font_color", Color(data.text))
	label_row.add_child(value_label)
	var bar := ProgressBar.new()
	bar.name = "Bar_%s" % key
	bar.min_value = 0
	bar.max_value = 100
	bar.value = value
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 4)
	bar.add_theme_stylebox_override("background", _panel_style(Color(1, 1, 1, 0.06), Color.TRANSPARENT, 4, 0))
	var fill_style := _panel_style(_stat_color(key, value), Color.TRANSPARENT, 4, 0)
	bar.add_theme_stylebox_override("fill", fill_style)
	info.add_child(bar)
	var fx_layer := Control.new()
	fx_layer.name = "Fx_%s" % key
	fx_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fx_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	fx_layer.clip_contents = false
	fx_layer.z_index = 20
	bar.add_child(fx_layer)
	var ruler := HBoxContainer.new()
	ruler.add_theme_constant_override("separation", 0)
	info.add_child(ruler)
	for tick in ["0", "50", "100"]:
		var tick_label := Label.new()
		tick_label.text = tick
		tick_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tick_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if tick == "0" else HORIZONTAL_ALIGNMENT_RIGHT
		tick_label.add_theme_font_size_override("font_size", 7)
		tick_label.add_theme_color_override("font_color", Color(data.secondary, 0.25))
		ruler.add_child(tick_label)
	ruler.visible = not _is_discreet_stat(key)
	_stat_widgets[key] = {
		"bar": bar,
		"value_label": value_label,
		"fill_style": fill_style,
		"fx_layer": fx_layer,
		"warning_tween": null
	}
	_sync_stat_warning(key, value)
	return row

func _sync_stat_warning(key: String, value: float) -> void:
	if not _stat_widgets.has(key):
		return
	var widget: Dictionary = _stat_widgets[key]
	var bar := widget.get("bar") as ProgressBar
	var warning_tween := widget.get("warning_tween") as Tween
	if warning_tween and warning_tween.is_valid():
		warning_tween.kill()
	widget.warning_tween = null
	if not is_instance_valid(bar):
		return
	bar.modulate.a = 1.0
	if _is_warning(key, value):
		warning_tween = create_tween().set_loops()
		warning_tween.tween_property(bar, "modulate:a", 0.42, 0.6)
		warning_tween.tween_property(bar, "modulate:a", 1.0, 0.6)
		widget.warning_tween = warning_tween

func _animate_stat_value(role: String, key: String, old_value: float, new_value: float, show_hearts: bool) -> void:
	if role != _current_role or not _stat_widgets.has(key):
		return
	var widget: Dictionary = _stat_widgets[key]
	var bar := widget.get("bar") as ProgressBar
	var value_label := widget.get("value_label") as Label
	var fill_style := widget.get("fill_style") as StyleBoxFlat
	if not is_instance_valid(bar) or not is_instance_valid(value_label) or not fill_style:
		return
	var previous_tween := _stat_tweens.get(key) as Tween
	if previous_tween and previous_tween.is_valid():
		previous_tween.kill()
	var warning_tween := widget.get("warning_tween") as Tween
	if warning_tween and warning_tween.is_valid():
		warning_tween.kill()
	widget.warning_tween = null
	bar.modulate.a = 1.0
	var visual_start := float(bar.value)
	var tween := create_tween()
	_stat_tweens[key] = tween
	var update_visuals := func(current_value: float) -> void:
		if not is_instance_valid(bar) or not is_instance_valid(value_label):
			return
		bar.value = current_value
		value_label.text = _stat_display_text(key, current_value)
		fill_style.bg_color = _stat_color(key, current_value)
	tween.tween_method(update_visuals, visual_start, new_value, STAT_TWEEN_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_callback(func():
		_stat_tweens.erase(key)
		_sync_stat_warning(key, new_value)
		if key == "arousal" and (old_value < 100.0) != (new_value < 100.0):
			_refresh_sidebar.call_deferred()
	)
	if show_hearts and not is_equal_approx(old_value, new_value):
		_spawn_stat_particles(key, true, 8)
	if old_value < 100.0 and new_value >= 100.0:
		_schedule_full_stat_effect(role, key)

func _spawn_stat_particles(key: String, hearts: bool, amount: int) -> void:
	if not bool(Settings.get_runtime_tuning_value("full_stat_effects_enabled", true)):
		return
	var particle_scale := float(Settings.get_runtime_tuning_value("particle_count_scale", 1.0))
	amount = maxi(0, int(round(float(amount) * particle_scale)))
	if amount <= 0:
		return
	if not _stat_widgets.has(key):
		return
	var widget: Dictionary = _stat_widgets[key]
	var fx_layer := widget.get("fx_layer") as Control
	if not is_instance_valid(fx_layer):
		return
	var width := maxf(24.0, fx_layer.size.x)
	var stat_color := _stat_color(key, float(_current_stats()[key]))
	var data := ThemeMgr.get_current_theme_data()
	var symbols := ["♥", "♡"] if hearts else ["✦", "✧", "•"]
	var origin := fx_layer.get_global_rect().position - get_global_rect().position
	for index in amount:
		var particle := Label.new()
		particle.mouse_filter = Control.MOUSE_FILTER_IGNORE
		particle.text = str(symbols[index % symbols.size()])
		particle.custom_minimum_size = Vector2(16, 16)
		particle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		particle.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		particle.add_theme_font_size_override("font_size", _rng.randi_range(8, 13))
		var particle_color := Color("#FF5C91").lerp(stat_color, _rng.randf_range(0.15, 0.55)) if hearts else stat_color.lerp(Color(data.accent), _rng.randf_range(0.15, 0.65))
		particle.add_theme_color_override("font_color", particle_color)
		particle.position = origin + Vector2(_rng.randf_range(0.0, width - 12.0), _rng.randf_range(-3.0, 3.0))
		particle.pivot_offset = Vector2(8, 8)
		particle.scale = Vector2(0.45, 0.45)
		particle.rotation = _rng.randf_range(-0.3, 0.3)
		particle.modulate.a = 0.0
		particle.z_index = 100
		add_child(particle)
		var lifetime := _rng.randf_range(0.68, 1.0) * float(
			Settings.get_runtime_tuning_value("particle_lifetime_scale", 1.0)
		)
		var target_position := particle.position + Vector2(_rng.randf_range(-22.0, 22.0), _rng.randf_range(-48.0, -24.0))
		var motion := create_tween().set_parallel(true)
		motion.tween_property(particle, "position", target_position, lifetime).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		motion.tween_property(particle, "rotation", particle.rotation + _rng.randf_range(-0.7, 0.7), lifetime)
		motion.tween_property(particle, "scale", Vector2.ONE * _rng.randf_range(0.82, 1.18), lifetime).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		var fade := create_tween()
		fade.tween_property(particle, "modulate:a", 1.0, 0.1)
		fade.tween_interval(maxf(0.12, lifetime - 0.32))
		fade.tween_property(particle, "modulate:a", 0.0, 0.22)
		fade.finished.connect(particle.queue_free)

func _pulse_full_bar(key: String) -> void:
	if not bool(Settings.get_runtime_tuning_value("full_stat_effects_enabled", true)):
		return
	if not _stat_widgets.has(key):
		return
	var bar := (_stat_widgets[key] as Dictionary).get("bar") as ProgressBar
	if not is_instance_valid(bar):
		return
	var previous_pulse := _stat_pulse_tweens.get(key) as Tween
	if previous_pulse and previous_pulse.is_valid():
		previous_pulse.kill()
	bar.scale = Vector2.ONE
	bar.pivot_offset = bar.size * 0.5
	var pulse := create_tween()
	_stat_pulse_tweens[key] = pulse
	pulse.tween_property(bar, "scale", Vector2(1.02, 1.35), 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	pulse.tween_property(bar, "scale", Vector2.ONE, 0.32).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	pulse.tween_callback(func():
		if is_instance_valid(bar):
			bar.scale = Vector2.ONE
		_stat_pulse_tweens.erase(key)
	)

func _schedule_full_stat_effect(role: String, key: String) -> void:
	var effect_key := "%s:%s" % [role, key]
	_pending_full_effects[effect_key] = true
	await get_tree().create_timer(STAT_TWEEN_DURATION).timeout
	if _scene_exiting or not _pending_full_effects.has(effect_key):
		return
	if role == _current_role and _stat_widgets.has(key):
		_spawn_stat_particles(key, false, 14)
		_pulse_full_bar(key)
		_pending_full_effects.erase(effect_key)

func _flush_pending_full_effects() -> void:
	if _scene_exiting:
		return
	for effect_key_variant in _pending_full_effects.keys():
		var effect_key := str(effect_key_variant)
		var parts := effect_key.split(":", false, 1)
		if parts.size() != 2 or parts[0] != _current_role:
			continue
		var key := str(parts[1])
		if not _stat_widgets.has(key):
			continue
		_spawn_stat_particles(key, false, 14)
		_pulse_full_bar(key)
		_pending_full_effects.erase(effect_key)

func _diary_card(role: Dictionary) -> PanelContainer:
	var data := ThemeMgr.get_current_theme_data()
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _panel_style(Color(1, 1, 1, 0.018), Color(data.text, 0.07), 16, 11))
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 6)
	card.add_child(content)
	var title := Label.new()
	title.text = "📖  今日絮语"
	title.add_theme_font_size_override("font_size", 10)
	title.add_theme_color_override("font_color", Color(data.secondary, 0.48))
	content.add_child(title)
	var diary := Label.new()
	diary.text = role.diary
	diary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	diary.add_theme_font_size_override("font_size", 11)
	diary.add_theme_color_override("font_color", Color(data.secondary, 0.85))
	content.add_child(diary)
	var footer := Label.new()
	footer.text = role.diary_footer
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	footer.add_theme_font_size_override("font_size", 9)
	footer.add_theme_color_override("font_color", Color(data.secondary, 0.4))
	content.add_child(footer)
	return card

func _add_system_message(text: String) -> Label:
	var data := ThemeMgr.get_current_theme_data()
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(data.secondary, 0.3))
	label.custom_minimum_size = Vector2(0, 24)
	_chat_list.add_child(label)
	_trim_chat_nodes()
	_scroll_to_bottom()
	return label

func _add_message(
	text: String,
	sender: String,
	role_id: String = "",
	typewriter: bool = false,
	message_id: String = "",
	delivery_status: String = "sent",
	target_role_id: String = ""
) -> Dictionary:
	var data := ThemeMgr.get_current_theme_data()
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_list.add_child(row)
	var group := VBoxContainer.new()
	group.add_theme_constant_override("separation", 4)
	if sender == "user":
		var leading_spacer := Control.new()
		leading_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(leading_spacer)
		row.add_child(group)
	else:
		row.add_child(group)
		var trailing_spacer := Control.new()
		trailing_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(trailing_spacer)

	var meta_row := HBoxContainer.new()
	meta_row.add_theme_constant_override("separation", 6)
	group.add_child(meta_row)
	var meta_spacer := Control.new()
	meta_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if sender == "user":
		meta_row.add_child(meta_spacer)
	var meta := Label.new()
	if sender == "user":
		var target_role: Dictionary = ROLE_DATA.get(role_id, {})
		meta.text = "主人 → %s  👤" % str(target_role.get("name", "大家"))
		meta.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	else:
		var role: Dictionary = ROLE_DATA.get(role_id, ROLE_DATA.ling)
		var target_role: Dictionary = ROLE_DATA.get(target_role_id, {})
		if target_role.is_empty():
			meta.text = str(role.icon) + "  " + str(role.name)
		else:
			meta.text = "%s  %s → %s  %s" % [
				str(role.icon),
				str(role.name),
				str(target_role.icon),
				str(target_role.name),
			]
	meta.add_theme_font_size_override("font_size", 11)
	meta.add_theme_color_override("font_color", Color(data.secondary, 0.55))
	meta_row.add_child(meta)

	var bubble := PanelContainer.new()
	var bubble_color := Color(data.primary, 0.12) if sender == "ai" else Color(data.accent, 0.10)
	bubble.add_theme_stylebox_override("panel", _panel_style(bubble_color, Color(data.text, 0.08), 14, 10))
	group.add_child(bubble)
	var label := Label.new()
	label.text = "" if typewriter else text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(_message_bubble_width(text), 0)
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color(data.text, 0.92))
	bubble.add_child(label)

	var delivery_row := HBoxContainer.new()
	delivery_row.visible = sender == "user" and delivery_status != "sent"
	delivery_row.alignment = BoxContainer.ALIGNMENT_END
	delivery_row.add_theme_constant_override("separation", 5)
	group.add_child(delivery_row)
	var status_label := Label.new()
	status_label.add_theme_font_size_override("font_size", 10)
	delivery_row.add_child(status_label)
	var retry_button := Button.new()
	retry_button.text = "↻"
	retry_button.tooltip_text = "重新发送"
	retry_button.flat = true
	retry_button.custom_minimum_size = Vector2(24, 22)
	retry_button.visible = false
	if not message_id.is_empty():
		retry_button.pressed.connect(func(): _retry_failed_message(message_id))
	delivery_row.add_child(retry_button)

	var item := {
		"row": row,
		"group": group,
		"bubble": bubble,
		"label": label,
		"meta": meta,
		"sender": sender,
		"role_id": role_id,
		"target_role_id": target_role_id,
		"text": text,
		"message_id": message_id,
		"delivery_row": delivery_row,
		"status_label": status_label,
		"retry_button": retry_button
	}
	_message_nodes.append(item)
	if not message_id.is_empty():
		_message_views[message_id] = item
	_update_message_delivery_view(message_id, delivery_status)
	group.modulate.a = 0.0
	group.position.y += 10.0
	var tween := create_tween().set_parallel(true)
	tween.tween_property(group, "modulate:a", 1.0, 0.35)
	tween.tween_property(group, "position:y", group.position.y - 10.0, 0.35).set_ease(Tween.EASE_OUT)
	_trim_chat_nodes()
	_scroll_to_bottom()
	if typewriter:
		_type_text(label, text)
	return item

func _type_text(label: Label, text: String) -> void:
	_typewriter_active = true
	_typewriter_skip_requested = false
	_refresh_interaction_state()
	var character_count := text.length()
	var characters_per_second := maxf(TYPEWRITER_MIN_CPS, float(character_count) / TYPEWRITER_MAX_SECONDS)
	var started_at := Time.get_ticks_usec()
	var previous_visible := 0
	while previous_visible < character_count and not _scene_exiting:
		if _typewriter_skip_requested:
			break
		var elapsed := float(Time.get_ticks_usec() - started_at) / 1000000.0
		var visible_count := mini(character_count, maxi(previous_visible + 1, int(elapsed * characters_per_second)))
		if is_instance_valid(label):
			label.text = text.substr(0, visible_count)
		else:
			break
		previous_visible = visible_count
		_scroll_to_bottom()
		await get_tree().process_frame
	if is_instance_valid(label):
		label.text = text
	_typewriter_active = false
	_typewriter_skip_requested = false
	_refresh_interaction_state()

func _interaction_locked() -> bool:
	return _network_waiting or _typewriter_active or _intro_active

func _refresh_interaction_state() -> void:
	if not is_instance_valid(_chat_input):
		return
	var presentation_locked := _typewriter_active or _intro_active
	var draft_enabled := not _intro_active
	_chat_input.editable = draft_enabled
	# 网络等待只阻止重复提交，不再把控件切成灰色禁用态。
	_send_button.disabled = presentation_locked
	# Role selection is a user preference, not part of the in-flight payload.
	# It remains available while waiting; revision tracking protects it from a
	# late callback that would otherwise apply the automatic next turn.
	_ling_button.disabled = _intro_active
	_nai_button.disabled = _intro_active
	if is_instance_valid(_explore_button):
		_explore_button.disabled = presentation_locked
	if is_instance_valid(_voice_button):
		_voice_button.disabled = _intro_active or VoiceInput.is_transcribing()
	for child in _action_bar.get_children():
		if child is Button:
			child.disabled = presentation_locked
	for view_variant in _message_views.values():
		var view := view_variant as Dictionary
		var retry_button := view.get("retry_button") as Button
		if is_instance_valid(retry_button):
			retry_button.disabled = presentation_locked
	_update_command_button_styles()
	_update_thinking_indicators()
	_sync_portrait_state()
	if draft_enabled and get_viewport().gui_get_focus_owner() == null:
		_chat_input.grab_focus()

func _pending_response_role() -> String:
	for request_id_variant in _pending_roles:
		var pending: Dictionary = _pending_roles[request_id_variant]
		var role := str(pending.get("role", ""))
		if ROLE_DATA.has(role):
			return role
	return _current_role

func _thinking_dots() -> String:
	return ["·", "··", "···"][_thinking_dot_phase]

func _update_command_button_styles() -> void:
	if not is_instance_valid(_send_button):
		return
	var data := ThemeMgr.get_current_theme_data()
	var response_role := _pending_response_role()
	var role: Dictionary = ROLE_DATA.get(response_role, ROLE_DATA.ling)
	var role_color := Color(str(role.color))
	_send_button.add_theme_color_override("font_disabled_color", Color.WHITE)
	_send_button.add_theme_stylebox_override(
		"disabled",
		_panel_style(Color(role_color, 0.88), Color(role_color), 22, 9)
	)
	if _typewriter_active:
		_send_button.text = "回复中…"
	elif _intro_active:
		_send_button.text = "请稍候…"
	else:
		_send_button.text = "发送"
	_send_button.tooltip_text = (
		"%s正在思考；可以继续编辑草稿或切换收件人" % str(role.name)
		if _network_waiting
		else "发送消息"
	)

	var lock_reason := "%s正在思考，回复后即可互动" % str(role.name)
	if _typewriter_active and not _network_waiting:
		lock_reason = "回复正在显示，点击对话可立即显示全文"
	elif _intro_active:
		lock_reason = "引导结束后即可互动"
	for child in _action_bar.get_children():
		if not child is Button:
			continue
		var button := child as Button
		button.add_theme_color_override("font_disabled_color", Color(data.text, 0.72))
		button.add_theme_stylebox_override(
			"disabled",
			_panel_style(Color(role_color, 0.13), Color(role_color, 0.38), 14, 5)
		)
		if _network_waiting:
			button.tooltip_text = lock_reason
		elif button.disabled:
			button.tooltip_text = lock_reason
		else:
			button.tooltip_text = "对%s进行%s" % [
				str((ROLE_DATA[_current_role] as Dictionary).name),
				INTERACTION_RULES.action_label(str(button.get_meta("action_id", "")))
			]

func _update_thinking_indicators() -> void:
	for request_id_variant in _waiting_nodes:
		var waiting_variant = _waiting_nodes[request_id_variant]
		if not waiting_variant is Dictionary:
			continue
		var waiting: Dictionary = waiting_variant
		var label := waiting.get("label") as Label
		var role_id := str(waiting.get("role", "ling"))
		var role: Dictionary = ROLE_DATA.get(role_id, ROLE_DATA.ling)
		if is_instance_valid(label):
			label.text = "%s  %s正在思考 %s" % [
				str(role.icon), str(role.name), _thinking_dots()
			]

func _update_thinking_visuals(delta: float) -> void:
	if not is_instance_valid(_input_panel) or not _input_panel_style:
		return
	var data := ThemeMgr.get_current_theme_data()
	var base_background := Color(1, 1, 1, 0.035)
	var base_border := Color(data.text, 0.08)
	_input_panel_style.bg_color = base_background
	_input_panel_style.border_color = base_border
	if is_instance_valid(_send_button):
		_send_button.modulate = Color.WHITE
	var thinking_intensity := float(Settings.get_runtime_tuning_value("thinking_intensity", 1.0))
	var target_visibility := 1.0 if _network_waiting and thinking_intensity > 0.0 else 0.0
	_thinking_strip_visibility = move_toward(
		_thinking_strip_visibility,
		target_visibility,
		delta * 3.6 * maxf(0.25, thinking_intensity)
	)
	if is_instance_valid(_thinking_strip):
		_thinking_strip.visible = _thinking_strip_visibility > 0.01
		_thinking_strip.modulate.a = _thinking_strip_visibility
	if not _network_waiting:
		_thinking_visual_elapsed = 0.0
		return
	_thinking_visual_elapsed += delta * maxf(0.25, thinking_intensity)
	var blend := 0.5 + 0.5 * sin(_thinking_visual_elapsed * 2.8)
	var thinking_colors := _thinking_colors(data)
	var thinking_a: Color = thinking_colors[0]
	var thinking_b: Color = thinking_colors[1]
	if _thinking_strip_material:
		_thinking_strip_material.set_shader_parameter("color_a", thinking_a)
		_thinking_strip_material.set_shader_parameter("color_b", thinking_b)
	for waiting_variant in _waiting_nodes.values():
		if not waiting_variant is Dictionary:
			continue
		var waiting: Dictionary = waiting_variant
		var style := waiting.get("style") as StyleBoxFlat
		if style:
			style.bg_color = Color(thinking_a, 0.07).lerp(
				Color(thinking_b, 0.17), blend
			)
			style.border_color = Color(thinking_a, 0.34).lerp(
				Color(thinking_b, 0.68), blend
			)

func _update_message_delivery_view(message_id: String, status: String, error_text := "") -> void:
	if message_id.is_empty() or not _message_views.has(message_id):
		return
	var view: Dictionary = _message_views[message_id]
	var delivery_row := view.get("delivery_row") as HBoxContainer
	var status_label := view.get("status_label") as Label
	var retry_button := view.get("retry_button") as Button
	if not is_instance_valid(delivery_row) or not is_instance_valid(status_label) or not is_instance_valid(retry_button):
		return
	match status:
		"pending":
			delivery_row.visible = true
			status_label.text = "发送中…"
			status_label.add_theme_color_override("font_color", Color(ThemeMgr.get_current_theme_data().secondary, 0.55))
			retry_button.visible = false
		"failed":
			var can_retry := bool(_find_history_entry(message_id).get("retryable", true))
			delivery_row.visible = true
			status_label.text = "发送失败 · 可重试" if can_retry else "发送失败"
			status_label.tooltip_text = error_text
			status_label.add_theme_color_override("font_color", Color("#D9534F"))
			retry_button.visible = can_retry
		_:
			delivery_row.visible = false
			retry_button.visible = false

func _show_persistence_failure(message: String, context := "本地保存失败") -> void:
	var detail := message.strip_edges()
	if detail.is_empty():
		detail = "本地存档写入失败"
	if detail.length() > 180:
		detail = detail.left(180) + "…"
	_add_system_message("⚠ %s · %s" % [context, detail])
	_update_log("%s：%s" % [context, detail])

func _commit_user_entry(entry: Dictionary, role: String, effect_spec: Dictionary = {}) -> Dictionary:
	var result: Dictionary = Global.commit_user_message(entry, role, effect_spec)
	if not bool(result.get("ok", false)):
		_show_persistence_failure(
			str(result.get("message", Global.get_last_save_error())),
			"消息未发送"
		)
		return {}
	var committed_variant = result.get("entry", {})
	if not committed_variant is Dictionary:
		_show_persistence_failure("事务没有返回已提交的消息", "消息未发送")
		return {}
	var committed_entry: Dictionary = committed_variant
	_conversation_history = Global.conversation_history
	_stats_by_role = Global.stats_by_role
	var message_id := str(committed_entry.get("id", ""))
	_add_message(
		str(committed_entry.get("text", "")),
		"user",
		role,
		false,
		message_id,
		str(committed_entry.get("status", "pending"))
	)
	var already_applied := bool(result.get("already_applied", result.get("duplicate", false)))
	if not effect_spec.is_empty() and not already_applied:
		var action := str(effect_spec.get("action", ""))
		var changes_variant = result.get("stat_changes", [])
		var stat_changes: Array = changes_variant if changes_variant is Array else []
		var cycle_variant = result.get("cycle_events", [])
		var cycle_events: Array = cycle_variant if cycle_variant is Array else []
		_play_committed_effect(role, action, stat_changes, cycle_events)
		var local_effect_variant = committed_entry.get("local_effect", {})
		_last_action_event = (
			(local_effect_variant as Dictionary).duplicate(true)
			if local_effect_variant is Dictionary
			else effect_spec.duplicate(true)
		)
		_last_action_event["text"] = str(committed_entry.get("text", ""))
		Global.action_triggered.emit(action, role)
		_update_log("%s · %s" % [
			str((ROLE_DATA[role] as Dictionary).name),
			INTERACTION_RULES.action_label(action)
		])
	return committed_entry

func _play_committed_effect(
	role: String,
	action: String,
	stat_changes: Array,
	cycle_events: Array = []
) -> void:
	for change_variant in stat_changes:
		if not change_variant is Dictionary:
			continue
		var change: Dictionary = change_variant
		var key := str(change.get("stat", ""))
		if not STAT_DEFS.has(key):
			continue
		var old_value := float(change.get("old_value", 0.0))
		var new_value := float(change.get("new_value", old_value))
		if key == "climax":
			var cycle_event := _find_climax_cycle_event(role, cycle_events)
			if not cycle_event.is_empty():
				_animate_climax_cycle(
					role,
					old_value,
					float(cycle_event.get("reset_value", new_value))
				)
				Global.stat_changed.emit(role, key, new_value)
				continue
		var show_hearts := action in AFFECTION_ACTIONS and key in AFFECTION_STAT_KEYS
		_animate_stat_value(role, key, old_value, new_value, show_hearts)
		Global.stat_changed.emit(role, key, new_value)

func _find_climax_cycle_event(role: String, cycle_events: Array) -> Dictionary:
	for event_variant in cycle_events:
		if not event_variant is Dictionary:
			continue
		var event: Dictionary = event_variant
		if (
			str(event.get("kind", "")) == "climax_cycle_completed"
			and str(event.get("role_id", "")) == role
		):
			return event
	return {}

func _animate_climax_cycle(role: String, old_value: float, reset_value: float) -> void:
	if role != _current_role or not _stat_widgets.has("climax"):
		return
	var widget: Dictionary = _stat_widgets.climax
	var bar := widget.get("bar") as ProgressBar
	var value_label := widget.get("value_label") as Label
	var fill_style := widget.get("fill_style") as StyleBoxFlat
	if not is_instance_valid(bar) or not is_instance_valid(value_label) or not fill_style:
		return
	var previous_tween := _stat_tweens.get("climax") as Tween
	if previous_tween and previous_tween.is_valid():
		previous_tween.kill()
	var update_visuals := func(current_value: float) -> void:
		if not is_instance_valid(bar) or not is_instance_valid(value_label):
			return
		bar.value = current_value
		value_label.text = _stat_display_text("climax", current_value)
		fill_style.bg_color = _stat_color("climax", current_value)
	var tween := create_tween()
	_stat_tweens["climax"] = tween
	tween.tween_method(update_visuals, old_value, 100.0, 0.42).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_callback(func():
		_spawn_stat_particles("climax", true, 18)
		_pulse_full_bar("climax")
	)
	tween.tween_interval(0.16)
	tween.tween_method(update_visuals, 100.0, reset_value, 0.56).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	tween.tween_callback(func():
		_stat_tweens.erase("climax")
		_sync_stat_warning("climax", reset_value)
	)

func _entry_request_state(entry: Dictionary, role_override := "") -> Dictionary:
	var state_variant = entry.get("state", {})
	var state: Dictionary = state_variant.duplicate(true) if state_variant is Dictionary else {}
	var role := role_override if ROLE_DATA.has(role_override) else str(entry.get("target_role", entry.get("role", _current_role)))
	if ROLE_DATA.has(role):
		state["body_state"] = LifeSim.build_role_state(role)
	var source_message_id := str(entry.get("id", "")).strip_edges()
	if not source_message_id.is_empty():
		state["source_message_id"] = source_message_id
	var audience_roles: Array[String] = []
	var audience_variant = entry.get("audience_roles", ["ling", "nai"])
	if audience_variant is Array:
		for audience_variant_role in audience_variant:
			var audience_role := str(audience_variant_role)
			if ROLE_DATA.has(audience_role) and audience_role not in audience_roles:
				audience_roles.append(audience_role)
	if audience_roles.is_empty():
		audience_roles.assign(["ling", "nai"])
	state["conversation_visibility"] = {
		"protocol": CONVERSATION_VISIBILITY_PROTOCOL,
		"mode": "shared_room",
		"audience_roles": audience_roles,
		"responder_role": role,
		"parenthetical_content_visible": true,
	}
	var route_variant = entry.get("conversation_route", {})
	if route_variant is Dictionary and not route_variant.is_empty():
		var route: Dictionary = (route_variant as Dictionary).duplicate(true)
		var origin_role := str(route.get("origin_role", ""))
		var target_role := str(route.get("target_role", ""))
		if role == origin_role:
			route["turn_role"] = role
			route["turn_index"] = 0
			state["conversation_route"] = route
		elif role == target_role:
			route["turn_role"] = role
			route["turn_index"] = 1
			state["conversation_route"] = route
	var local_effect_variant = entry.get("local_effect", {})
	var local_effects_variant = entry.get("local_effects_by_role", {})
	if local_effects_variant is Dictionary and (local_effects_variant as Dictionary).has(role):
		local_effect_variant = (local_effects_variant as Dictionary).get(role, {})
	if local_effect_variant is Dictionary and not local_effect_variant.is_empty():
		state["local_effect"] = (local_effect_variant as Dictionary).duplicate(true)
	return state

func _append_history_message(
	sender: String,
	role: String,
	text: String,
	status: String,
	extra: Dictionary = {}
) -> String:
	var message_id := str(extra.get("id", Global.new_local_id("message")))
	var entry := {
		"id": message_id,
		"sender": sender,
		"role": role,
		"text": text.strip_edges(),
		"status": status,
		"created_at": int(Time.get_unix_time_from_system())
	}
	for key in extra:
		if key != "id":
			entry[key] = extra[key]
	if not Global.append_conversation_entry(entry):
		_show_persistence_failure(Global.get_last_save_error(), "回复未保存")
	_conversation_history = Global.conversation_history
	return message_id

func _find_history_entry(message_id: String) -> Dictionary:
	for index in range(_conversation_history.size() - 1, -1, -1):
		var entry: Dictionary = _conversation_history[index]
		if str(entry.get("id", "")) == message_id:
			return entry
	return {}

func _latest_ai_speaker_role() -> String:
	for index in range(_conversation_history.size() - 1, -1, -1):
		var entry: Dictionary = _conversation_history[index]
		if str(entry.get("sender", "")) != "ai" or str(entry.get("status", "sent")) != "sent":
			continue
		var role := str(entry.get("role", ""))
		if ROLE_DATA.has(role):
			return role
	return ""

func _set_history_delivery_status(
	message_id: String,
	status: String,
	error_text := "",
	retryable := true
) -> void:
	var changes := {
		"status": status,
		"error": error_text,
		"retryable": retryable
	}
	if not Global.update_conversation_entry(message_id, changes):
		_show_persistence_failure(Global.get_last_save_error(), "消息状态未保存")
	_conversation_history = Global.conversation_history
	_update_message_delivery_view(message_id, status, error_text)

func _restore_conversation_ui() -> void:
	for entry_variant in _conversation_history:
		var entry := entry_variant as Dictionary
		var sender := str(entry.get("sender", ""))
		if sender not in ["user", "ai"]:
			continue
		var text := str(entry.get("text", "")).strip_edges()
		if text.is_empty():
			continue
		var message_id := str(entry.get("id", ""))
		var status := str(entry.get("status", "sent"))
		_add_message(
			text,
			sender,
			str(entry.get("role", "")),
			false,
			message_id,
			status,
			str(entry.get("target_role", entry.get("recipient_role", "")))
		)
		if status == "failed":
			_update_message_delivery_view(message_id, status, str(entry.get("error", "请求未完成")))
	_update_turn_hint()

func _build_shared_history(_reply_role: String, excluded_message_id := "") -> Array[Dictionary]:
	var transcript: Array[Dictionary] = []
	var used_characters := 0
	for index in range(_conversation_history.size() - 1, -1, -1):
		var item: Dictionary = _conversation_history[index]
		if str(item.get("id", "")) == excluded_message_id:
			continue
		if str(item.get("status", "sent")) != "sent":
			continue
		var sender := str(item.get("sender", ""))
		if sender not in ["user", "ai"]:
			continue
		var history_role := str(item.get("role", ""))
		var speaker := "主人"
		if sender == "ai":
			if not ROLE_DATA.has(history_role):
				continue
			speaker = str((ROLE_DATA[history_role] as Dictionary).name)
		var history_text := TEXT_SANITIZER.strip_nul(str(item.get("text", ""))).strip_edges()
		if history_text.is_empty():
			continue
		if history_text.length() > 3000:
			history_text = history_text.left(3000)
		var history_event_type := str(item.get("event_type", "chat"))
		if history_event_type not in ["chat", "action"]:
			history_event_type = "chat"
		var entry := {
			"id": str(item.get("id", "")).left(128),
			"sender": sender,
			"speaker": speaker,
			"text": history_text,
			"event_type": history_event_type,
			"action": str(item.get("action", "")).left(64),
			"created_at": int(item.get("created_at", 0))
		}
		var audience_roles: Array[String] = []
		var audience_variant = item.get("audience_roles", ["ling", "nai"])
		if audience_variant is Array:
			for audience_role_variant in audience_variant:
				var audience_role := str(audience_role_variant)
				if ROLE_DATA.has(audience_role) and audience_role not in audience_roles:
					audience_roles.append(audience_role)
		if audience_roles.is_empty():
			audience_roles.assign(["ling", "nai"])
		entry["audience_roles"] = audience_roles
		if sender == "ai":
			entry["role_id"] = history_role
			var ai_target_role := str(item.get("target_role", ""))
			if ROLE_DATA.has(ai_target_role):
				entry["target_role"] = ai_target_role
		else:
			entry["role"] = "user"
			# Legacy saves may not have target_role. Omit this optional field unless valid.
			var legacy_target_role := str(item.get("target_role", ""))
			if ROLE_DATA.has(legacy_target_role):
				entry["target_role"] = legacy_target_role
		var entry_size := JSON.stringify(entry).length()
		if transcript.size() >= SHARED_HISTORY_LIMIT or used_characters + entry_size > 6000:
			break
		transcript.push_front(entry)
		used_characters += entry_size
	return transcript

func _register_pending_request(
	request_id: String,
	message_id: String,
	entry: Dictionary,
	role_override := "",
	remaining_roles: Array[String] = []
) -> void:
	var role := role_override if ROLE_DATA.has(role_override) else str(entry.get("target_role", entry.get("role", _current_role)))
	var state := _entry_request_state(entry, role)
	_pending_roles[request_id] = {
		"role": role,
		"history_id": message_id,
		"text": str(entry.get("text", "")),
		"event_type": str(entry.get("event_type", "chat")),
		"state": state,
		"remaining_roles": remaining_roles.duplicate(),
	}
	_network_waiting = true
	_set_history_delivery_status(message_id, "pending", "", true)
	if not Global.update_conversation_entry(message_id, {"request_id": request_id}):
		_show_persistence_failure(Global.get_last_save_error(), "重试信息未保存")
	_conversation_history = Global.conversation_history
	_add_waiting_message(request_id, role)
	_refresh_interaction_state()

func _dispatch_history_entry(message_id: String, preferred_request_id := "") -> bool:
	var entry := _find_history_entry(message_id)
	if entry.is_empty():
		return false
	var reply_roles := _entry_reply_roles(entry)
	if reply_roles.is_empty():
		return false
	_acquire_foreground_scope(message_id)
	var role := reply_roles[0]
	var remaining_roles: Array[String] = []
	for index in range(1, reply_roles.size()):
		remaining_roles.append(reply_roles[index])
	if not preferred_request_id.is_empty() and CompanionCore.retry_request(preferred_request_id):
		_register_pending_request(preferred_request_id, message_id, entry, role, remaining_roles)
		return true
	return _dispatch_history_entry_to_role(message_id, entry, role, remaining_roles)

func _dispatch_history_entry_to_role(
	message_id: String,
	entry: Dictionary,
	role: String,
	remaining_roles: Array[String]
) -> bool:
	var event_type := str(entry.get("event_type", "chat"))
	var state := _entry_request_state(entry, role)
	var request_id := CompanionCore.send_chat(
		role,
		str(entry.get("text", "")),
		_build_shared_history(role, message_id),
		Global.get_active_save_id(),
		event_type,
		state
	)
	if request_id.is_empty():
		_release_foreground_scope(message_id)
		return false
	_register_pending_request(request_id, message_id, entry, role, remaining_roles)
	return true

func _acquire_foreground_scope(message_id: String) -> void:
	if message_id.is_empty() or _foreground_scope_tokens.has(message_id):
		return
	_foreground_scope_tokens[message_id] = MessageScheduler.begin_foreground(
		"game_world",
		message_id
	)

func _release_foreground_scope(message_id: String) -> void:
	if not _foreground_scope_tokens.has(message_id):
		return
	var token := str(_foreground_scope_tokens[message_id])
	_foreground_scope_tokens.erase(message_id)
	MessageScheduler.end_foreground(token)

func _entry_reply_roles(entry: Dictionary) -> Array[String]:
	var result: Array[String] = []
	var raw_roles = entry.get("target_roles", [])
	if raw_roles is Array:
		for role_variant in raw_roles:
			var role := str(role_variant)
			if ROLE_DATA.has(role) and role not in result:
				result.append(role)
	if result.is_empty():
		var fallback := str(entry.get("target_role", entry.get("role", _current_role)))
		if ROLE_DATA.has(fallback):
			result.append(fallback)
	return result

func _trim_chat_nodes() -> void:
	while _chat_list.get_child_count() > UI_MESSAGE_LIMIT:
		var oldest := _chat_list.get_child(0)
		for request_id_variant in _waiting_nodes.keys():
			var request_id := str(request_id_variant)
			var waiting_variant = _waiting_nodes[request_id]
			var waiting_row = (
				(waiting_variant as Dictionary).get("row")
				if waiting_variant is Dictionary
				else waiting_variant
			)
			if waiting_row == oldest:
				_waiting_nodes.erase(request_id)
				break
		for index in range(_message_nodes.size() - 1, -1, -1):
			var item: Dictionary = _message_nodes[index]
			if item.get("row") != oldest:
				continue
			var message_id := str(item.get("message_id", ""))
			if not message_id.is_empty():
				_message_views.erase(message_id)
			_message_nodes.remove_at(index)
			break
		_chat_list.remove_child(oldest)
		oldest.queue_free()

func _send_message() -> void:
	var raw_text := _chat_input.text
	if raw_text.strip_edges().is_empty():
		return
	if _network_waiting:
		_show_network_busy_hint()
		return
	if _typewriter_active or _intro_active:
		return
	LifeSim.note_user_activity()
	var recipient_result: Dictionary = _resolve_recipients(
		raw_text,
		_current_role,
		_latest_ai_speaker_role()
	)
	var reply_roles_variant = recipient_result.get("roles", [_current_role])
	var reply_roles: Array[String] = []
	if reply_roles_variant is Array:
		for role_variant in reply_roles_variant:
			var role := str(role_variant)
			if ROLE_DATA.has(role) and role not in reply_roles:
				reply_roles.append(role)
	if reply_roles.is_empty():
		reply_roles.append(_current_role)
	var reply_role := reply_roles[0]
	var audience_roles: Array[String] = []
	var audience_variant = recipient_result.get("audience_roles", ["ling", "nai"])
	if audience_variant is Array:
		for audience_role_variant in audience_variant:
			var audience_role := str(audience_role_variant)
			if ROLE_DATA.has(audience_role) and audience_role not in audience_roles:
				audience_roles.append(audience_role)
	if audience_roles.is_empty():
		audience_roles.assign(["ling", "nai"])
	var message_id := Global.new_local_id("user")
	var event_type := "chat"
	var action := ""
	var effect_spec: Dictionary = {}
	var effect_specs_by_role: Dictionary = {}
	var natural_match := INTERACTION_RULES.match_natural_action(raw_text)
	if not natural_match.is_empty():
		action = str(natural_match.get("action", ""))
		for target_role in reply_roles:
			var event_id := INTERACTION_RULES.deterministic_event_id(
				Global.get_active_save_id(), message_id, target_role, action
			)
			var target_effect := INTERACTION_RULES.make_effect_spec(
				action,
				target_role,
				str(natural_match.get("source", "natural_keyword")),
				str(natural_match.get("rule_id", "keyword:%s" % action)),
				event_id,
				Settings.get_interaction_overrides(target_role, action),
				float(natural_match.get("intensity_multiplier", 1.0))
			)
			if target_effect.is_empty():
				continue
			target_effect["kind"] = "natural_keyword"
			target_effect["source_message_id"] = message_id
			effect_specs_by_role[target_role] = target_effect
		if effect_specs_by_role.has(reply_role):
			effect_spec = (effect_specs_by_role[reply_role] as Dictionary).duplicate(true)
		if not effect_specs_by_role.is_empty():
			event_type = "action"
	var entry := {
		"id": message_id,
		"sender": "user",
		"role": reply_role,
		"target_role": reply_role,
		"target_roles": reply_roles.duplicate(),
		"audience_roles": audience_roles,
		"recipient_reason": str(recipient_result.get("reason", "selected")),
		"text": raw_text,
		"status": "pending",
		"event_type": event_type,
		"action": action,
		"kind": "natural_action" if event_type == "action" else "chat",
		"retryable": true,
		"created_at": int(Time.get_unix_time_from_system())
	}
	var conversation_route_variant = recipient_result.get("route", {})
	if conversation_route_variant is Dictionary and not conversation_route_variant.is_empty():
		entry["conversation_route"] = (conversation_route_variant as Dictionary).duplicate(true)
	if not effect_spec.is_empty():
		entry["state"] = {"local_effect": effect_spec.duplicate(true)}
	if not effect_specs_by_role.is_empty():
		entry["local_effects_by_role"] = effect_specs_by_role.duplicate(true)
	var committed_entry := _commit_user_entry(entry, reply_role, effect_spec)
	if committed_entry.is_empty():
		return
	for target_role_variant in effect_specs_by_role.keys():
		var target_role := str(target_role_variant)
		if target_role == reply_role:
			continue
		var secondary_effect := effect_specs_by_role[target_role] as Dictionary
		var secondary_result: Dictionary = Global.commit_user_message(
			entry,
			target_role,
			secondary_effect,
			false
		)
		if not bool(secondary_result.get("ok", false)):
			_update_log("%s 的状态效果未保存：%s" % [
				str((ROLE_DATA[target_role] as Dictionary).name),
				str(secondary_result.get("message", "未知错误")),
			])
			continue
		if not bool(secondary_result.get("duplicate", false)):
			_play_committed_effect(
				target_role,
				str(secondary_effect.get("action", action)),
				secondary_result.get("stat_changes", []),
				secondary_result.get("cycle_events", []),
			)
			Global.action_triggered.emit(str(secondary_effect.get("action", action)), target_role)
	_chat_input.clear()
	_update_recipient_hint()
	_dispatch_history_entry(str(committed_entry.get("id", message_id)))

func _apply_action(action: String) -> void:
	if _network_waiting:
		_show_network_busy_hint()
		return
	if _typewriter_active or _intro_active or not INTERACTION_RULES.has_action(action):
		return
	LifeSim.note_user_activity()
	var response_role := _current_role
	var user_message := INTERACTION_RULES.action_message(action)
	var message_id := Global.new_local_id("user")
	var event_id := INTERACTION_RULES.deterministic_event_id(
		Global.get_active_save_id(), message_id, response_role, action
	)
	var effect_spec := INTERACTION_RULES.make_effect_spec(
		action,
		response_role,
		"button",
		"button:%s" % action,
		event_id,
		Settings.get_interaction_overrides(response_role, action)
	)
	effect_spec["kind"] = "button_action"
	effect_spec["source_message_id"] = message_id
	var entry := {
		"id": message_id,
		"sender": "user",
		"role": response_role,
		"target_role": response_role,
		"audience_roles": ["ling", "nai"],
		"text": user_message,
		"status": "pending",
		"kind": "action",
		"action": action,
		"event_type": "action",
		"retryable": true,
		"state": {"local_effect": effect_spec.duplicate(true)},
		"created_at": int(Time.get_unix_time_from_system())
	}
	var committed_entry := _commit_user_entry(entry, response_role, effect_spec)
	if committed_entry.is_empty():
		return
	_dispatch_history_entry(str(committed_entry.get("id", message_id)))

func get_last_local_action_event() -> Dictionary:
	return _last_action_event.duplicate(true)

func _select_reply_role(role: String) -> void:
	if _intro_active or not ROLE_DATA.has(role):
		return
	if _switch_role(role, false, true):
		_role_revision += 1

func _switch_role(role: String, _announce: bool, persist := true) -> bool:
	if not ROLE_DATA.has(role):
		return false
	var changed := role != _current_role
	var previous_role := _current_role
	if not Global.set_current_character(role, persist):
		Global.set_current_character(previous_role, false)
		_show_persistence_failure(Global.get_last_save_error(), "角色切换未保存")
		return false
	_current_role = role
	_ling_button.button_pressed = role == "ling"
	_nai_button.button_pressed = role == "nai"
	_update_role_button_styles()
	_apply_chat_input_theme(ThemeMgr.get_current_theme_data())
	_refresh_sidebar()
	_update_turn_hint()
	_update_command_button_styles()
	if changed:
		Global.role_switched.emit(role)
	return true

func _update_role_button_styles() -> void:
	var data := ThemeMgr.get_current_theme_data()
	for entry in [[_ling_button, "ling"], [_nai_button, "nai"]]:
		var button: Button = entry[0]
		var active := str(entry[1]) == _current_role
		button.add_theme_color_override("font_color", Color.WHITE if active else Color(data.secondary))
		button.add_theme_stylebox_override("normal", _panel_style(Color(data.primary) if active else Color.TRANSPARENT, Color.TRANSPARENT, 16, 3))
		button.add_theme_stylebox_override("pressed", _panel_style(Color(data.primary), Color.TRANSPARENT, 16, 3))

func _intro_sequence() -> void:
	_intro_active = true
	_refresh_interaction_state()
	var intro_lines: Array[Dictionary] = [
		{"role": "ling", "text": "喵～你来了。我在窗台上晒了好一会儿太阳了。"},
		{"role": "nai", "text": "嗯～小玲姐姐！主人来了怎么不叫我！"},
		{"role": "ling", "text": "喵……你急什么，主人又不会跑。"}
	]
	await get_tree().create_timer(0.35).timeout
	for line in intro_lines:
		if _scene_exiting:
			return
		var role := str(line.get("role", "ling"))
		var text := str(line.get("text", ""))
		_switch_role(role, false, false)
		var message_id := _append_history_message(
			"ai", role, text, "sent", {"kind": "intro", "event_type": "intro"}
		)
		var next_role := _other_role(role)
		var next_role_saved := Global.set_current_character(next_role, true)
		if not next_role_saved:
			_show_persistence_failure(Global.get_last_save_error(), "引导轮次未保存")
		_add_message(text, "ai", role, true, message_id, "sent")
		while _typewriter_active and not _scene_exiting:
			await get_tree().process_frame
		if next_role_saved:
			_switch_role(next_role, false, false)
		await get_tree().create_timer(0.25).timeout
	_intro_active = false
	_refresh_interaction_state()

func _retry_failed_message(message_id: String) -> void:
	if _network_waiting:
		_show_network_busy_hint()
		return
	if _typewriter_active or _intro_active:
		return
	var entry := _find_history_entry(message_id)
	if entry.is_empty() or str(entry.get("status", "")) != "failed":
		return
	if not bool(entry.get("retryable", true)):
		return
	var old_request_id := str(entry.get("request_id", ""))
	if not _dispatch_history_entry(message_id, old_request_id):
		_set_history_delivery_status(message_id, "failed", "无法恢复这条请求", false)

func _on_core_health_changed(active: bool, message: String) -> void:
	if active:
		_update_core_status("已连接", Color(ThemeMgr.get_current_theme_data().primary))
	else:
		var detail := message.strip_edges()
		_update_core_status("离线" if detail.is_empty() else "离线 · %s" % detail, Color("#D9534F"))

func _update_core_status(status: String, color: Color) -> void:
	if not _connection_status:
		return
	_connection_status.text = "Core · " + status
	_connection_status.add_theme_color_override("font_color", color)

func _on_memory_status_changed(status: Dictionary) -> void:
	if not is_instance_valid(_memory_status):
		return
	_memory_state = str(status.get("state", "idle"))
	var message := str(status.get("message", "尚无记忆整理记录")).strip_edges()
	var role := str(status.get("role_id", ""))
	var role_name := str((ROLE_DATA[role] as Dictionary).name) if ROLE_DATA.has(role) else ""
	var memory_count := maxi(0, int(status.get("memory_count", 0)))
	var recalled_count := maxi(0, int(status.get("last_recall_count", 0)))
	var color := Color(ThemeMgr.get_current_theme_data().secondary, 0.70)
	match _memory_state:
		"queued":
			_memory_status.text = "🧶 心织排队"
			color = Color("#6EA8D9")
		"processing", "waiting":
			_memory_status.text = "🧶 心织处理中"
			color = Color("#D9A441")
		"success":
			_memory_status.text = "🧶 心织 · 唤起 %d" % recalled_count
			color = Color("#4CAF7D")
		"ready":
			_memory_status.text = "🧶 心织 · %d 条" % memory_count
			color = Color(ThemeMgr.get_current_theme_data().primary, 0.82)
		"skipped":
			_memory_status.text = "🧶 本轮略过"
		"error":
			_memory_status.text = "🧶 心织失败"
			color = Color("#D9534F")
		_:
			_memory_status.text = "🧶 心织记忆 · 待命"
	_memory_status.tooltip_text = "%s%s" % [
		("%s · " % role_name) if not role_name.is_empty() else "",
		message if not message.is_empty() else "尚无记忆整理记录",
	]
	_memory_status.add_theme_color_override("font_color", color)

func _on_core_reply(request_id: String, text: String, _attachments: Array) -> void:
	if not _pending_roles.has(request_id):
		return
	var pending: Dictionary = _pending_roles[request_id]
	_pending_roles.erase(request_id)
	_remove_waiting_message(request_id)
	var role := str(pending.get("role", _current_role))
	var history_id := str(pending.get("history_id", ""))
	if text.strip_edges().is_empty():
		_set_history_delivery_status(history_id, "failed", "Companion Core 返回了空回复", true)
		_release_foreground_scope(history_id)
		return
	var reply_text := text.strip_edges()
	if role == _current_role:
		_sync_portrait_state(reply_text)
	if Multimodal.is_tts_configured():
		Multimodal.call_deferred("synthesize_speech", reply_text, role)
	var remaining_roles: Array[String] = []
	var remaining_variant = pending.get("remaining_roles", [])
	if remaining_variant is Array:
		for role_variant in remaining_variant:
			var remaining_role := str(role_variant)
			if ROLE_DATA.has(remaining_role):
				remaining_roles.append(remaining_role)
	if remaining_roles.is_empty():
		_set_history_delivery_status(history_id, "sent", "", false)
	var event_type := str(pending.get("event_type", "chat"))
	var reply_extra := {
		"in_reply_to": history_id,
		"event_type": event_type,
		"kind": "action_reply" if event_type == "action" else "reply",
		"audience_roles": ["ling", "nai"],
	}
	var reply_target_role := ""
	var pending_state_variant = pending.get("state", {})
	if pending_state_variant is Dictionary:
		var route_variant = (pending_state_variant as Dictionary).get("conversation_route", {})
		if route_variant is Dictionary:
			var route: Dictionary = route_variant
			if int(route.get("turn_index", -1)) == 0:
				reply_target_role = str(route.get("target_role", ""))
			else:
				reply_target_role = str(route.get("origin_role", ""))
	if ROLE_DATA.has(reply_target_role):
		reply_extra["target_role"] = reply_target_role
	var reply_id := _append_history_message("ai", role, reply_text, "sent", reply_extra)
	_add_message(reply_text, "ai", role, true, reply_id, "sent", reply_target_role)
	if not remaining_roles.is_empty():
		var next_role: String = str(remaining_roles.pop_front())
		var source_entry := _find_history_entry(history_id)
		if source_entry.is_empty() or not _dispatch_history_entry_to_role(
			history_id, source_entry, next_role, remaining_roles
		):
			_set_history_delivery_status(history_id, "failed", "无法继续双人回复", true)
			_release_foreground_scope(history_id)
	else:
		_release_foreground_scope(history_id)
	_network_waiting = not _pending_roles.is_empty()
	_refresh_interaction_state()
	while _typewriter_active and not _scene_exiting:
		await get_tree().process_frame

func _on_core_request_failed(request_id: String, message: String, retryable: bool) -> void:
	if not _pending_roles.has(request_id):
		return
	var pending: Dictionary = _pending_roles[request_id]
	_pending_roles.erase(request_id)
	_remove_waiting_message(request_id)
	_network_waiting = not _pending_roles.is_empty()
	var history_id := str(pending.get("history_id", ""))
	_set_history_delivery_status(history_id, "failed", message, retryable)
	_release_foreground_scope(history_id)
	if not retryable:
		CompanionCore.discard_request(request_id)
	_update_core_status("请求失败", Color("#D9534F"))
	_update_log("Companion Core 请求失败：%s" % message)
	_refresh_interaction_state()

func _on_life_stat_changed(role: String, key: String, value: float) -> void:
	_stats_by_role = Global.stats_by_role
	if role != _current_role:
		return
	_sync_portrait_state()
	if not _stat_widgets.has(key):
		return
	var widget: Dictionary = _stat_widgets[key]
	var bar := widget.get("bar") as ProgressBar
	var old_value := float(bar.value) if is_instance_valid(bar) else value
	_animate_stat_value(role, key, old_value, value, key in AFFECTION_STAT_KEYS)

func _on_life_autonomous_action(event: Dictionary) -> void:
	var role := str(event.get("role_id", ""))
	if not ROLE_DATA.has(role):
		return
	var description := str(event.get("description", "")).strip_edges()
	if description.is_empty():
		return
	_update_log("%s · %s" % [
		str((ROLE_DATA[role] as Dictionary).name),
		description.left(120),
	])
	if role == _current_role:
		_refresh_sidebar.call_deferred()

func _on_menstrual_cycle_changed(role: String, _state: Dictionary) -> void:
	if role == _current_role:
		_refresh_sidebar()

func _on_menstrual_phase_changed(role: String, phase: String, _state: Dictionary) -> void:
	if role != _current_role:
		return
	_update_log("%s · %s" % [
		str((ROLE_DATA[role] as Dictionary).name),
		_cycle_phase_label(phase),
	])

func _on_proactive_message(role: String, text: String, message_id: String) -> void:
	if _message_views.has(message_id):
		return
	_conversation_history = Global.conversation_history
	_add_message(text, "ai", role, true, message_id, "sent")
	if role == _current_role:
		_sync_portrait_state(text)
	var entry := _find_history_entry(message_id)
	var attachments = entry.get("attachments", [])
	if attachments is Array and not attachments.is_empty() and attachments[0] is Dictionary:
		var photo: Dictionary = attachments[0]
		if str(photo.get("kind", "")) == "local_photo":
			_add_system_message("📷 本地相册 · %s" % str(photo.get("label", "照片")))
	_update_log("%s主动发来消息" % str((ROLE_DATA.get(role, ROLE_DATA.ling) as Dictionary).name))

func _on_ambient_dialogue_message(
	role: String,
	target_role: String,
	text: String,
	message_id: String,
	_session_id: String
) -> void:
	if _message_views.has(message_id):
		return
	_conversation_history = Global.conversation_history
	_add_message(text, "ai", role, true, message_id, "sent", target_role)
	if role == _current_role:
		_sync_portrait_state(text)
	_update_log("%s正在和%s聊天" % [
		str((ROLE_DATA.get(role, ROLE_DATA.ling) as Dictionary).name),
		str((ROLE_DATA.get(target_role, ROLE_DATA.nai) as Dictionary).name),
	])

func _update_turn_hint() -> void:
	if not _chat_input or not ROLE_DATA.has(_current_role):
		return
	var role: Dictionary = ROLE_DATA[_current_role]
	_chat_input.placeholder_text = "对%s说点什么..." % str(role.name)
	_update_recipient_hint()

func _on_chat_input_changed(_new_text: String) -> void:
	_update_recipient_hint()

func _toggle_voice_input() -> void:
	if _intro_active or VoiceInput.is_transcribing():
		return
	if VoiceInput.is_recording():
		_voice_button.disabled = true
		_set_voice_status("正在转成文字…", Color(ThemeMgr.get_current_theme_data().primary))
		await VoiceInput.stop_and_transcribe("zh")
		_refresh_interaction_state()
		return
	if not CompanionCore.is_provider_configured("asr"):
		_set_voice_status("请先在 AI 服务中启用语音识别", Color("#D9A441"))
		return
	var result: Dictionary = VoiceInput.start_recording()
	if not bool(result.get("ok", false)):
		_set_voice_status(str(result.get("message", "无法开始录音")), Color("#D9534F"))
	_refresh_interaction_state()

func _on_tts_audio_ready(_request_id: String, role: String, audio: PackedByteArray, mime_type: String) -> void:
	if audio.is_empty() or not ROLE_DATA.has(role):
		return
	Audio.play_voice_bytes(audio, mime_type, role)

func _on_voice_recording_changed(recording: bool, duration_seconds: float) -> void:
	if not is_instance_valid(_voice_button):
		return
	if recording:
		_voice_button.text = "⏹"
		_voice_button.tooltip_text = "停止录音并转成文字"
		_voice_button.add_theme_stylebox_override(
			"normal", _panel_style(Color("#D9534F", 0.18), Color("#D9534F", 0.78), 8, 6)
		)
		_set_voice_status("录音 %.1f 秒" % duration_seconds, Color("#D9534F"))
	else:
		_voice_button.text = "🎙️"
		_voice_button.tooltip_text = "开始语音输入"
		var data := ThemeMgr.get_current_theme_data()
		_voice_button.add_theme_stylebox_override(
			"normal", _panel_style(Color(data.text, 0.055), Color(data.text, 0.16), 8, 6)
		)

func _on_voice_transcription_started() -> void:
	_set_voice_status("正在转成文字…", Color(ThemeMgr.get_current_theme_data().primary))
	_refresh_interaction_state()

func _on_voice_transcription_ready(text: String, _language: String) -> void:
	if not is_instance_valid(_chat_input):
		return
	var caret := clampi(_chat_input.caret_column, 0, _chat_input.text.length())
	var before := _chat_input.text.left(caret)
	var after := _chat_input.text.substr(caret)
	var prefix := "" if before.is_empty() or before.ends_with(" ") else " "
	var suffix := "" if after.is_empty() or after.begins_with(" ") else " "
	var insertion := prefix + text.strip_edges() + suffix
	_chat_input.text = before + insertion + after
	_chat_input.caret_column = caret + insertion.length()
	_chat_input.grab_focus()
	_update_recipient_hint()
	_set_voice_status("已转写，确认后发送", Color("#4CAF7D"))
	_refresh_interaction_state()

func _on_voice_transcription_failed(message: String, _retryable: bool) -> void:
	_set_voice_status(message, Color("#D9534F"))
	_refresh_interaction_state()

func _set_voice_status(message: String, color: Color) -> void:
	if not is_instance_valid(_voice_status):
		return
	_voice_status.text = message
	_voice_status.tooltip_text = message
	_voice_status.add_theme_color_override("font_color", color)

func _update_recipient_hint() -> void:
	if not is_instance_valid(_recipient_hint) or not is_instance_valid(_chat_input):
		return
	var resolved: Dictionary = _resolve_recipients(_chat_input.text, _current_role)
	var roles_variant = resolved.get("roles", [_current_role])
	var names: Array[String] = []
	if roles_variant is Array:
		for role_variant in roles_variant:
			var role := str(role_variant)
			if ROLE_DATA.has(role):
				names.append(str((ROLE_DATA[role] as Dictionary).name))
	var audience_names: Array[String] = []
	var audience_variant = resolved.get("audience_roles", ["ling", "nai"])
	if audience_variant is Array:
		for role_variant in audience_variant:
			var role := str(role_variant)
			if ROLE_DATA.has(role):
				audience_names.append(str((ROLE_DATA[role] as Dictionary).name))
	_recipient_hint.text = "将由 %s 回复 · %s均可见" % [
		"、".join(names),
		"、".join(audience_names),
	]

func _resolve_recipients(
	text: String,
	selected_role: String,
	conversational_role := ""
) -> Dictionary:
	var resolved: Dictionary = RECIPIENT_RESOLVER.resolve(
		text, selected_role, conversational_role
	)
	if resolved.has("route"):
		return resolved
	var reason := str(resolved.get("reason", "selected"))
	var should_reply_together := (
		reason == "selected"
		and (
			str(Settings.get_runtime_tuning_value("default_reply_mode", "selected")) == "both"
			or (
				bool(Settings.get_runtime_tuning_value("both_names_trigger_dual", false))
				and _message_mentions_both_roles(text)
			)
		)
	)
	if should_reply_together:
		resolved["roles"] = [selected_role, _other_role(selected_role)]
		resolved["reason"] = "developer_dual"
	return resolved

func _message_mentions_both_roles(text: String) -> bool:
	for role in ["ling", "nai"]:
		var mentioned := false
		for alias_variant in RECIPIENT_RESOLVER.ROLE_ALIASES[role]:
			if text.findn(str(alias_variant)) >= 0:
				mentioned = true
				break
		if not mentioned:
			return false
	return true

func _other_role(role: String) -> String:
	return "nai" if role == "ling" else "ling"

func _add_waiting_message(request_id: String, role: String) -> void:
	_remove_waiting_message(request_id)
	var role_data: Dictionary = ROLE_DATA.get(role, ROLE_DATA.ling)
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var bubble := PanelContainer.new()
	var thinking_colors := _thinking_colors(ThemeMgr.get_current_theme_data())
	var thinking_a: Color = thinking_colors[0]
	var thinking_b: Color = thinking_colors[1]
	var bubble_style := _panel_style(
		Color(thinking_a, 0.11),
		Color(thinking_b, 0.54),
		14,
		9
	)
	bubble.add_theme_stylebox_override("panel", bubble_style)
	row.add_child(bubble)
	var label := Label.new()
	label.name = "Waiting_%s" % request_id.validate_node_name()
	label.text = "%s  %s正在思考 %s" % [
		str(role_data.icon), str(role_data.name), _thinking_dots()
	]
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", thinking_a.lerp(Color(ThemeMgr.get_current_theme_data().text), 0.38))
	label.custom_minimum_size = Vector2(0, 24)
	bubble.add_child(label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	_chat_list.add_child(row)
	_waiting_nodes[request_id] = {
		"row": row, "label": label, "role": role, "style": bubble_style,
	}
	_trim_chat_nodes()
	_scroll_to_bottom()
	_update_thinking_indicators()

func _remove_waiting_message(request_id := "") -> void:
	if not request_id.is_empty():
		var waiting_variant = _waiting_nodes.get(request_id)
		_waiting_nodes.erase(request_id)
		var row = (
			(waiting_variant as Dictionary).get("row")
			if waiting_variant is Dictionary
			else waiting_variant
		)
		if is_instance_valid(row):
			row.queue_free()
		return
	for waiting_variant in _waiting_nodes.values():
		var row = (
			(waiting_variant as Dictionary).get("row")
			if waiting_variant is Dictionary
			else waiting_variant
		)
		if is_instance_valid(row):
			row.queue_free()
	_waiting_nodes.clear()

func _scroll_to_bottom() -> void:
	await get_tree().process_frame
	if is_instance_valid(_chat_scroll):
		_chat_scroll.scroll_vertical = int(_chat_scroll.get_v_scroll_bar().max_value)

func _update_log(text: String) -> void:
	_log_label.text = "📋   " + text
	_log_label.modulate.a = 1.0
	var tween := create_tween()
	tween.tween_property(_log_label, "modulate:a", 0.90, 2.0)

func _thinking_colors(data: Dictionary) -> Array[Color]:
	var primary := Color(data.primary)
	var accent := Color(data.accent)
	var text := Color(data.text)
	return [primary.lerp(text, 0.18), accent.lerp(primary, 0.34)]

func _show_network_busy_hint() -> void:
	var role_id := _pending_response_role()
	var role_name := str((ROLE_DATA.get(role_id, ROLE_DATA.ling) as Dictionary).name)
	_update_log("%s仍在思考；草稿和收件人选择已保留。" % role_name)

func _message_bubble_width(text: String) -> float:
	var viewport_width := maxf(240.0, get_viewport_rect().size.x)
	var chat_width := viewport_width
	if is_instance_valid(_chat_area) and _chat_area.size.x > 1.0:
		chat_width = _chat_area.size.x
	var width_ratio := 0.88 if viewport_width <= 820.0 else 0.90
	var maximum := minf(920.0, maxf(130.0, chat_width * width_ratio))
	var longest_line := 0
	for line in text.split("\n"):
		longest_line = maxi(longest_line, str(line).length())
	var estimated := float(longest_line) * 13.0 + 8.0
	return clampf(estimated, minf(112.0, maximum), maximum)

func _update_message_bubble_widths() -> void:
	for item in _message_nodes:
		var label := item.get("label") as Label
		if not is_instance_valid(label):
			continue
		label.custom_minimum_size.x = _message_bubble_width(str(item.get("text", "")))

func _on_viewport_size_changed() -> void:
	_apply_responsive_layout()
	_update_message_bubble_widths()

func _apply_responsive_layout() -> void:
	if not _main_layout:
		return
	var width := get_viewport_rect().size.x
	var compact := width <= 820.0
	var narrow := width <= 480.0
	_main_layout.vertical = compact
	_brand.visible = not narrow
	_connection_status.visible = width > 600.0
	_memory_status.visible = width > 720.0
	_explore_button.visible = width > 560.0
	_ling_button.custom_minimum_size = Vector2(70 if narrow else 84, 28)
	_nai_button.custom_minimum_size = Vector2(70 if narrow else 84, 28)
	_settings_button.custom_minimum_size = Vector2(32 if narrow else 38, 34)
	_archive_button.custom_minimum_size = Vector2(32 if narrow else 38, 34)
	_memory_network_button.custom_minimum_size = Vector2(32 if narrow else 38, 34)
	_menu_button.custom_minimum_size = Vector2(32 if narrow else 38, 34)
	if compact:
		_sidebar.custom_minimum_size = Vector2(0, 180 if width > 480.0 else 140)
		_sidebar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_sidebar.size_flags_vertical = Control.SIZE_FILL
		_brand.add_theme_font_size_override("font_size", 12)
	else:
		_sidebar.custom_minimum_size = Vector2(340, 0)
		_sidebar.size_flags_horizontal = Control.SIZE_FILL
		_sidebar.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_brand.add_theme_font_size_override("font_size", 14)
	_apply_sidebar_card_widths()
	_glow.position = get_viewport_rect().size / 2.0 - _glow.size / 2.0
	call_deferred("_update_message_bubble_widths")

func _apply_sidebar_card_widths() -> void:
	if not _sidebar_content:
		return
	var width := get_viewport_rect().size.x
	var card_width := 310.0
	var profile_width := 310.0
	if width <= 820.0:
		card_width = 170.0 if width > 480.0 else 128.0
		profile_width = maxf(280.0, width - 54.0)
	for index in _sidebar_content.get_child_count():
		var card := _sidebar_content.get_child(index) as Control
		if card:
			card.custom_minimum_size.x = profile_width if bool(card.get_meta("sidebar_full_width", false)) else card_width

func _apply_chat_input_theme(data: Dictionary) -> void:
	if not is_instance_valid(_chat_input):
		return
	var role_color := Color(str((ROLE_DATA.get(_current_role, ROLE_DATA.ling) as Dictionary).color))
	var caret_color := role_color.lightened(0.28) if bool(data.is_dark) else role_color.darkened(0.22)
	_chat_input.add_theme_color_override("caret_color", caret_color)
	_chat_input.add_theme_color_override("selection_color", Color(role_color, 0.42))
	_chat_input.add_theme_color_override(
		"font_selected_color",
		Color.WHITE if bool(data.is_dark) else Color(data.text)
	)
	_chat_input.add_theme_constant_override("caret_width", 3)

func _on_theme_changed(_data: Dictionary) -> void:
	var data := ThemeMgr.get_current_theme_data()
	_glow.material.set_shader_parameter("glow_color", Color(data.primary, 0.09))
	_nav.add_theme_stylebox_override("panel", _panel_style(Color(1, 1, 1, 0.035), Color(data.text, 0.08), 0, 0))
	_input_panel_style = _panel_style(Color(1, 1, 1, 0.035), Color(data.text, 0.08), 0, 0)
	_input_panel.add_theme_stylebox_override("panel", _input_panel_style)
	_log_bar.add_theme_stylebox_override("panel", _panel_style(Color(1, 1, 1, 0.045), Color(data.text, 0.10), 0, 0))
	_sidebar.add_theme_stylebox_override("panel", _panel_style(Color(1, 1, 1, 0.025), Color(data.text, 0.08), 0, 0))
	_nav.material = _glass_material(data, 2.0)
	_input_panel.material = _glass_material(data, 1.8)
	_sidebar.material = _glass_material(data, 2.0)
	_log_bar.material = _glass_material(data, 1.4)
	_role_switch_panel.add_theme_stylebox_override("panel", _panel_style(Color(1, 1, 1, 0.045), Color(data.text, 0.08), 18, 3))
	_brand.add_theme_color_override("font_color", Color(data.primary))
	_log_label.add_theme_color_override("font_color", Color(data.text, 0.92))
	_recipient_hint.add_theme_color_override("font_color", Color(data.text, 0.72))
	_send_button.add_theme_stylebox_override("normal", _filled_button_style(false))
	_send_button.add_theme_stylebox_override("hover", _filled_button_style(true))
	_apply_chat_input_theme(data)
	_update_role_button_styles()
	_refresh_message_styles(data)
	_refresh_sidebar()
	_refresh_interaction_state()
	queue_redraw()

func _refresh_message_styles(data: Dictionary) -> void:
	for item in _message_nodes:
		var bubble: PanelContainer = item.bubble
		var label: Label = item.label
		var meta: Label = item.meta
		if not is_instance_valid(bubble) or not is_instance_valid(label) or not is_instance_valid(meta):
			continue
		var sender := str(item.sender)
		var bubble_color := Color(data.primary, 0.12) if sender == "ai" else Color(data.accent, 0.10)
		bubble.add_theme_stylebox_override("panel", _panel_style(bubble_color, Color(data.text, 0.08), 14, 10))
		label.add_theme_color_override("font_color", Color(data.text, 0.92))
		meta.add_theme_color_override("font_color", Color(data.secondary, 0.55))

func _on_font_size_changed(size: int) -> void:
	_chat_input.add_theme_font_size_override("font_size", maxi(13, size - 1))
	_send_button.add_theme_font_size_override("font_size", maxi(13, size - 1))
	_refresh_sidebar()

func _back_to_menu() -> void:
	UI.switch_scene("res://scenes/MainMenu/MainMenu.tscn")

func _open_exploration() -> void:
	if _interaction_locked():
		_update_log("请等待当前回复或文字动画结束后再进入 3D 探索。")
		return
	if not ResourceLoader.exists(EXPLORATION_SCENE_PATH):
		_update_log("3D 探索场景尚未就绪。")
		return
	UI.switch_scene(EXPLORATION_SCENE_PATH)

func _panel_style(background: Color, border: Color, radius: int, margin: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	if border.a > 0.0:
		style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.content_margin_left = margin
	style.content_margin_right = margin
	style.content_margin_top = margin
	style.content_margin_bottom = margin
	return style

func _filled_button_style(hover: bool) -> StyleBoxFlat:
	var data := ThemeMgr.get_current_theme_data()
	var color := Color(data.primary)
	return _panel_style(Color(color, 1.0 if not hover else 0.86), Color(color), 22, 9)

func _glass_material(data: Dictionary, blur: float) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = GLASS_SHADER
	material.set_shader_parameter("tint_color", Color(data.bg))
	material.set_shader_parameter("tint_strength", 0.24 if bool(data.is_dark) else 0.16)
	material.set_shader_parameter("blur_lod", blur)
	return material

func _is_warning(key: String, value: float) -> bool:
	var definition: Dictionary = STAT_DEFS[key]
	return value < float(definition.threshold) if definition.warning == "low" else value > float(definition.threshold)

func _is_discreet_stat(key: String) -> bool:
	return key in ["arousal", "fertility", "implantation"]

func _stat_display_text(key: String, value: float) -> String:
	match key:
		"arousal":
			if value >= 100.0:
				return "满溢"
			if value >= 85.0:
				return "炽热"
			if value >= 55.0:
				return "升温"
			if value >= 25.0:
				return "微热"
			return "平静"
		"fertility":
			if value >= 80.0:
				return "容受窗"
			if value >= 50.0:
				return "较高"
			if value >= 20.0:
				return "建立中"
			return "低"
		"implantation":
			if value >= 4.0:
				return "低"
			if value >= 2.0:
				return "很低"
			return "极低"
		_:
			return "%d%%" % int(round(value))

func _life_event_label(event_key: String) -> String:
	var normalized := event_key.strip_edges()
	if normalized.is_empty():
		return ""
	if normalized.begins_with("personality:"):
		var action := normalized.trim_prefix("personality:")
		var spec := LIFE_PERSONALITY.action_spec(_current_role, action)
		return str(spec.get("description", "")).strip_edges()
	if normalized.begins_with("cycle:"):
		return "%s进入了%s" % [
			str((ROLE_DATA[_current_role] as Dictionary).name),
			_cycle_phase_label(normalized.trim_prefix("cycle:")),
		]
	if normalized in ["drink", "eat", "toilet", "rest"]:
		return LIFE_PERSONALITY.self_care_description(_current_role, normalized)
	return ""

func _day_period_label(hour: int) -> String:
	if hour >= 5 and hour < 11:
		return "清晨时光"
	if hour >= 11 and hour < 14:
		return "午间时光"
	if hour >= 14 and hour < 18:
		return "午后时光"
	if hour >= 18 and hour < 23:
		return "晚间时光"
	return "夜深时光"

func _life_cadence_label(role_runtime: Dictionary) -> String:
	var intent_variant = role_runtime.get("current_intent", {})
	if intent_variant is Dictionary and str((intent_variant as Dictionary).get("status", "")) in [
		"planned", "executing"
	]:
		return "自主安排进行中"
	var last_activity := maxi(
		int(role_runtime.get("last_self_care_unix", 0)),
		int(role_runtime.get("last_personality_action_unix", 0))
	)
	var elapsed := int(Time.get_unix_time_from_system()) - last_activity
	if last_activity > 0 and elapsed < 5 * 60:
		return "刚刚有过生活动静"
	if last_activity > 0 and elapsed < 60 * 60:
		return "%d 分钟前有过生活动静" % maxi(1, elapsed / 60)
	return "安静陪伴中"

func _update_life_status_time() -> void:
	if not is_instance_valid(_life_status_clock) or not is_instance_valid(_life_status_cadence):
		return
	var local_time := Time.get_datetime_dict_from_system()
	var hour := int(local_time.get("hour", 0))
	_life_status_clock.text = "%02d:%02d" % [hour, int(local_time.get("minute", 0))]
	var roles_runtime = Global.life_runtime.get("roles", {})
	var role_runtime: Dictionary = (
		(roles_runtime as Dictionary).get(_current_role, {})
		if roles_runtime is Dictionary
		else {}
	)
	_life_status_cadence.text = "%s · %s" % [
		_day_period_label(hour),
		_life_cadence_label(role_runtime),
	]

func _cycle_phase_label(phase: String) -> String:
	return {
		"menstrual": "经期",
		"follicular": "卵泡期",
		"ovulation": "排卵窗口",
		"luteal": "黄体期",
	}.get(phase, "周期状态")

func _bleeding_label(level: String) -> String:
	return {
		"none": "无",
		"light": "较少",
		"moderate": "中等",
		"heavy": "较多",
	}.get(level, "未知")

func _cramps_label(level: String) -> String:
	return {
		"none": "无",
		"mild": "轻微",
		"moderate": "中等",
		"strong": "较明显",
	}.get(level, "未知")

func _stat_color(key: String, value: float) -> Color:
	match key:
		"health":
			return Color("#4CAF50") if value > 60 else Color("#FFA726") if value > 30 else Color("#EF5350")
		"hunger":
			return Color("#EF5350") if value > 75 else Color("#FFA726") if value > 50 else Color("#8D8D8D")
		"thirst":
			return Color("#EF5350") if value > 75 else Color("#42A5F5") if value > 50 else Color("#8D8D8D")
		"awake":
			return Color("#FFD54F") if value > 60 else Color("#FFA726") if value > 30 else Color("#78909C")
		"urine":
			return Color("#FF7043") if value > 80 else Color("#FFCA28") if value > 50 else Color("#8D8D8D")
		"stress":
			return Color("#EF5350") if value > 70 else Color("#AB47BC") if value > 40 else Color("#8D8D8D")
		"fertility":
			return Color("#E91E63") if value > 60 else Color("#F06292") if value > 30 else Color("#F8BBD0")
		"implantation":
			return Color("#7E9BB9") if value >= 4.0 else Color("#91AFC7") if value >= 2.0 else Color("#AFC6D8")
		"climax":
			return Color("#FF80AB") if value > 85 else Color("#F8BBD0")
		"intimacy", "arousal":
			return Color.from_hsv(0.94 - value * 0.0012, 0.62, 0.92)
		_:
			return Color.from_hsv(0.07, 0.72, 0.62 + value * 0.003)
