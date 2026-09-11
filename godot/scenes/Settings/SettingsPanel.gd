extends Control

signal closed

const GLASS_SHADER := preload("res://shaders/glass.gdshader")
const INTERACTION_RULES := preload("res://scripts/domain/InteractionRules.gd")
const RUNTIME_TUNING := preload("res://scripts/domain/DeveloperRuntimeTuning.gd")
const PLAYTEST_DIAGNOSTICS := preload("res://scripts/domain/PlaytestDiagnostics.gd")
const DEVELOPER_ROLES := ["ling", "nai"]
const SETTINGS_CATEGORIES := [
	{"id": "general", "icon": "🎨", "label": "体验"},
	{"id": "ai", "icon": "✨", "label": "AI 服务"},
	{"id": "knowledge", "icon": "📚", "label": "记忆与知识"},
	{"id": "life", "icon": "🌿", "label": "生活与世界"},
	{"id": "advanced", "icon": "🧰", "label": "高级"},
]
const SETTINGS_SUBCATEGORIES := {
	"general": [
		{"id": "appearance", "label": "主题与颜色"},
		{"id": "window_audio", "label": "窗口与声音"},
		{"id": "readability", "label": "字体与可读性"},
	],
	"ai": [
		{"id": "chat", "label": "对话模型"},
		{"id": "capabilities", "label": "能力模型"},
		{"id": "fallbacks", "label": "备用模型"},
		{"id": "network", "label": "网络与代理"},
	],
	"knowledge": [
		{"id": "retrieval", "label": "检索设置"},
		{"id": "documents", "label": "文档管理"},
		{"id": "editor", "label": "文档编辑"},
		{"id": "test", "label": "检索测试"},
	],
	"life": [
		{"id": "autonomy", "label": "自主生活"},
		{"id": "presentation", "label": "2D 舞台"},
	],
	"advanced": [
		{"id": "reliability", "label": "可靠性"},
		{"id": "state", "label": "当前状态"},
		{"id": "runtime", "label": "运行参数"},
		{"id": "interaction", "label": "互动数值"},
	],
}
const DEFAULT_SETTINGS_SUBCATEGORIES := {
	"general": "appearance",
	"ai": "chat",
	"knowledge": "retrieval",
	"life": "autonomy",
	"advanced": "reliability",
}
const PROVIDER_CAPABILITY_LABELS := {
	"chat": "对话",
	"vision": "视觉",
	"embedding": "嵌入",
	"rerank": "重排",
	"asr": "语音识别",
	"tts": "语音合成",
}
const PROVIDER_PRESETS := {
	"OpenAI": {"base_url": "https://api.openai.com/v1", "model": "gpt-4.1-mini"},
	"DeepSeek": {"base_url": "https://api.deepseek.com/v1", "model": "deepseek-chat"},
	"LM Studio": {"base_url": "http://127.0.0.1:1234/v1", "model": "local-model"},
}
const CAPABILITY_PROVIDER_UI := {
	"vision": {
		"label": "视觉模型",
		"description": "用于场景截图、视频通话和桌面视觉转述",
		"base_url": "https://api.openai.com/v1",
		"model": "gpt-4.1-mini",
		"protocols": {"openai_chat_vision": "OpenAI 视觉对话"},
	},
	"embedding": {
		"label": "嵌入模型",
		"description": "把知识片段转换为向量，用于语义召回",
		"base_url": "https://api.openai.com/v1",
		"model": "text-embedding-3-small",
		"protocols": {"openai_embeddings": "OpenAI Embeddings"},
	},
	"rerank": {
		"label": "重排序模型",
		"description": "对初步召回结果再次排序，提高 RAG 精度",
		"base_url": "https://api.jina.ai/v1",
		"model": "jina-reranker-v2-base-multilingual",
		"protocols": {"jina_v1": "Jina /rerank", "cohere_v2": "Cohere v2 /rerank"},
	},
	"asr": {
		"label": "语音识别模型",
		"description": "把麦克风录音转成文字；文字确认发送后复用完整互动与状态链路",
		"base_url": "http://127.0.0.1:12393",
		"model": "whisper-1",
		"protocols": {
			"openai_transcriptions": "OpenAI /audio/transcriptions",
		},
	},
	"tts": {
		"label": "语音合成模型",
		"description": "把角色回复转换成语音；可接 Voicebox、OpenAI-compatible TTS 或 GPT-SoVITS",
		"base_url": "http://127.0.0.1:8880/v1",
		"model": "kokoro",
		"protocols": {
			"openai_speech": "OpenAI-compatible /audio/speech",
			"gpt_sovits_get": "GPT-SoVITS /tts"
		},
	},
}
const STAT_LABELS := {
	"health": "健康", "stamina": "体力", "hunger": "饥饿", "thirst": "口渴",
	"awake": "清醒", "urine": "尿液", "intimacy": "好感度", "mood": "心情",
	"stress": "压力", "fertility": "内膜容受性", "implantation": "服药后着床倾向"
}

var _scrim: ColorRect
var _panel: PanelContainer
var _content: VBoxContainer
var _bg_picker: ColorPickerButton
var _primary_picker: ColorPickerButton
var _accent_picker: ColorPickerButton
var _readability_panel: PanelContainer
var _readability_row: HBoxContainer
var _resolution_select: OptionButton
var _fullscreen_toggle: CheckBox
var _developer_role_select: OptionButton
var _developer_action_select: OptionButton
var _developer_delta_rows: VBoxContainer
var _developer_status: Label
var _developer_scope_label: Label
var _developer_spinboxes: Dictionary = {}
var _developer_role := "ling"
var _developer_action := "hug"
var _developer_scope_save_id := ""
var _developer_reset_all_dialog: ConfirmationDialog
var _developer_discard_dialog: ConfirmationDialog
var _developer_dirty := false
var _developer_loaded_values: Dictionary = {}
var _ambient_controls: Dictionary = {}
var _ambient_status: Label
var _ambient_dirty := false
var _ambient_loaded_values: Dictionary = {}
var _runtime_controls: Dictionary = {}
var _runtime_loaded_values: Dictionary = {}
var _runtime_status: Label
var _runtime_dirty := false
var _runtime_group_reset_buttons: Dictionary = {}
var _stat_role := "ling"
var _stat_role_select: OptionButton
var _stat_controls: Dictionary = {}
var _stat_loaded_values: Dictionary = {}
var _stat_status: Label
var _stat_dirty := false
var _provider_base_url_input: LineEdit
var _provider_model_input: LineEdit
var _provider_api_key_input: LineEdit
var _provider_preset_select: OptionButton
var _provider_show_key: CheckBox
var _provider_save_button: Button
var _provider_clear_button: Button
var _provider_diagnose_button: Button
var _provider_status: Label
var _provider_clear_dialog: ConfirmationDialog
var _provider_http_confirmation_dialog: ConfirmationDialog
var _provider_http_confirmation_target := ""
var _provider_status_data: Dictionary = {}
var _provider_loaded_values := {
	"base_url": "https://api.deepseek.com/v1",
	"model": "deepseek-chat",
}
var _provider_dirty := false
var _provider_busy := false
var _provider_write_in_flight := false
var _provider_suppress_dirty := false
var _provider_request_generation := 0
var _maintenance_status_label: Label
var _maintenance_run_button: Button
var _maintenance_backup_list: VBoxContainer
var _maintenance_backup_status: Label
var _diagnostic_bundle_button: Button
var _diagnostic_open_button: Button
var _diagnostic_bundle_status: Label
var _last_diagnostic_bundle_path := ""
var _provider_profile_controls: Dictionary = {}
var _provider_profile_loaded: Dictionary = {}
var _provider_profile_dirty: Dictionary = {}
var _provider_fallback_controls: Dictionary = {}
var _provider_fallback_loaded: Dictionary = {}
var _provider_fallback_drafts: Dictionary = {}
var _provider_fallback_dirty: Dictionary = {}
var _provider_proxy_controls: Dictionary = {}
var _provider_proxy_loaded := {"mode": "direct", "url": ""}
var _provider_proxy_dirty := false
var _provider_rag_controls: Dictionary = {}
var _provider_rag_loaded: Dictionary = {}
var _provider_rag_dirty := false
var _provider_clear_target := "chat"
var _settings_category := "general"
var _settings_subcategory := "appearance"
var _settings_subcategory_by_category: Dictionary = DEFAULT_SETTINGS_SUBCATEGORIES.duplicate(true)
var _provider_capability_focus := "vision"
var _provider_fallback_focus := "chat"
var _category_drafts: Dictionary = {}
var _category_buttons: Dictionary = {}
var _subcategory_buttons: Dictionary = {}
var _rag_document_title: LineEdit
var _rag_document_text: TextEdit
var _rag_document_scope: OptionButton
var _rag_document_source: LineEdit
var _rag_document_status: Label
var _rag_document_id := ""
var _rag_document_dirty := false
var _rag_library_status: Label
var _rag_document_filter: LineEdit
var _rag_scope_filter: OptionButton
var _rag_document_list: VBoxContainer
var _rag_documents: Array = []
var _rag_selected_document_ids: Dictionary = {}
var _rag_batch_scope: OptionButton
var _rag_batch_controls: Dictionary = {}
var _rag_url_input: LineEdit
var _rag_import_scope: OptionButton
var _rag_search_query: LineEdit
var _rag_search_role: OptionButton
var _rag_search_results: VBoxContainer
var _rag_file_dialog: FileDialog
var _rag_delete_dialog: ConfirmationDialog
var _rag_pending_delete_ids: Array[String] = []
var _rag_operation_busy := false

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_shell()
	_build_developer_dialog()
	_build_developer_discard_dialog()
	_build_provider_clear_dialog()
	_build_provider_http_confirmation_dialog()
	_build_rag_dialogs()
	get_viewport().size_changed.connect(_update_panel_size)
	hide()
	Global.theme_changed.connect(_on_theme_changed)

func show_panel(initial_category: String = "") -> void:
	if initial_category == "interaction":
		_settings_category = "advanced"
		_settings_subcategory_by_category["advanced"] = "interaction"
	elif initial_category in DEFAULT_SETTINGS_SUBCATEGORIES:
		_settings_category = initial_category
	_settings_subcategory = str(_settings_subcategory_by_category.get(
		_settings_category, DEFAULT_SETTINGS_SUBCATEGORIES.get(_settings_category, "")
	))
	_developer_scope_save_id = Settings.get_interaction_scope_save_id()
	_developer_dirty = false
	_ambient_dirty = false
	_runtime_dirty = false
	_stat_dirty = false
	_provider_dirty = false
	_provider_profile_dirty.clear()
	_provider_proxy_dirty = false
	_provider_rag_dirty = false
	_provider_busy = false
	_provider_write_in_flight = false
	_provider_http_confirmation_target = ""
	_rag_document_dirty = false
	_rag_operation_busy = false
	_category_drafts.clear()
	_provider_request_generation += 1
	_rebuild_content()
	show()
	_refresh_provider_status.call_deferred()
	modulate.a = 0.0
	_panel.scale = Vector2(0.97, 0.97)
	_panel.pivot_offset = _panel.size / 2.0
	var tween := create_tween().set_parallel(true)
	tween.tween_property(self, "modulate:a", 1.0, 0.24).set_ease(Tween.EASE_OUT)
	tween.tween_property(_panel, "scale", Vector2.ONE, 0.32).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)

func close_panel() -> void:
	_provider_request_generation += 1
	_provider_busy = false
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 0.18)
	await tween.finished
	hide()
	closed.emit()

func _build_shell() -> void:
	_scrim = ColorRect.new()
	_scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scrim.color = Color(0, 0, 0, 0.58)
	_scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	_scrim.gui_input.connect(_on_scrim_input)
	add_child(_scrim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(880, 540)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 22)
	margin.add_theme_constant_override("margin_bottom", 22)
	_panel.add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)

	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 12)
	scroll.add_child(_content)
	_apply_panel_style()
	_update_panel_size()

func _build_developer_dialog() -> void:
	_developer_reset_all_dialog = ConfirmationDialog.new()
	_developer_reset_all_dialog.title = "恢复当前旅程的全部互动默认值"
	_developer_reset_all_dialog.ok_button_text = "全部恢复默认"
	_developer_reset_all_dialog.cancel_button_text = "取消"
	_developer_reset_all_dialog.confirmed.connect(_reset_all_developer_interactions)
	add_child(_developer_reset_all_dialog)

func _build_developer_discard_dialog() -> void:
	_developer_discard_dialog = ConfirmationDialog.new()
	_developer_discard_dialog.title = "放弃未保存的设置？"
	_developer_discard_dialog.dialog_text = "关闭设置会丢弃当前尚未保存的模型连接、运行参数、角色属性、后台生活或互动数值修改。"
	_developer_discard_dialog.ok_button_text = "放弃并关闭"
	_developer_discard_dialog.cancel_button_text = "继续编辑"
	_developer_discard_dialog.confirmed.connect(func():
		_developer_dirty = false
		_ambient_dirty = false
		_runtime_dirty = false
		_stat_dirty = false
		_provider_dirty = false
		_provider_profile_dirty.clear()
		_provider_proxy_dirty = false
		_provider_rag_dirty = false
		_rag_document_dirty = false
		_category_drafts.clear()
		close_panel()
	)
	add_child(_developer_discard_dialog)

func _build_provider_clear_dialog() -> void:
	_provider_clear_dialog = ConfirmationDialog.new()
	_provider_clear_dialog.title = "清除已保存的 API Key？"
	_provider_clear_dialog.dialog_text = "这会删除由当前 Windows 用户加密保存的模型密钥。环境变量中的密钥不会被删除。"
	_provider_clear_dialog.ok_button_text = "清除已保存 Key"
	_provider_clear_dialog.cancel_button_text = "取消"
	_provider_clear_dialog.confirmed.connect(_clear_provider_api_key)
	add_child(_provider_clear_dialog)

func _build_provider_http_confirmation_dialog() -> void:
	_provider_http_confirmation_dialog = ConfirmationDialog.new()
	_provider_http_confirmation_dialog.title = "允许公网 HTTP 中转？"
	_provider_http_confirmation_dialog.dialog_text = "这个模型地址使用公网 HTTP。继续后，API Key、截图、提示词和模型回复都可能在网络中以明文传输。仅在你信任该中转站和网络链路时继续。"
	_provider_http_confirmation_dialog.ok_button_text = "允许 HTTP 并保存"
	_provider_http_confirmation_dialog.cancel_button_text = "取消"
	_provider_http_confirmation_dialog.confirmed.connect(_confirm_provider_insecure_http)
	_provider_http_confirmation_dialog.canceled.connect(_cancel_provider_insecure_http)
	add_child(_provider_http_confirmation_dialog)

func _build_rag_dialogs() -> void:
	_rag_file_dialog = FileDialog.new()
	_rag_file_dialog.title = "导入知识库文档"
	_rag_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	_rag_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_rag_file_dialog.filters = PackedStringArray([
		"*.txt,*.md,*.markdown ; 文本与 Markdown",
		"*.json,*.jsonl,*.csv,*.tsv ; 结构化文本",
		"*.html,*.htm ; 网页文件",
		"*.docx,*.pdf ; Office 与 PDF",
	])
	_rag_file_dialog.files_selected.connect(_import_rag_files)
	add_child(_rag_file_dialog)
	_rag_delete_dialog = ConfirmationDialog.new()
	_rag_delete_dialog.title = "删除知识文档？"
	_rag_delete_dialog.dialog_text = "文档与全部检索分块将被永久删除。"
	_rag_delete_dialog.ok_button_text = "删除文档"
	_rag_delete_dialog.cancel_button_text = "取消"
	_rag_delete_dialog.confirmed.connect(_confirm_delete_rag_document)
	add_child(_rag_delete_dialog)

func _rebuild_content() -> void:
	_clear_rebuilt_control_references()
	for child in _content.get_children():
		_content.remove_child(child)
		child.queue_free()
	var data := ThemeMgr.get_current_theme_data()
	_build_header(data)
	_build_category_navigation(data)
	_build_subcategory_navigation(data)
	match _settings_category:
		"ai":
			_build_ai_provider_section(data)
		"knowledge":
			_build_knowledge_management_section(data)
		"life":
			_build_life_settings_pages(data)
		"advanced":
			_build_advanced_settings_pages(data)
		_:
			_build_general_settings_pages(data)
	_apply_settings_content_readability(_content, data)

func _apply_settings_content_readability(node: Node, data: Dictionary) -> void:
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
		_apply_settings_content_readability(child, data)

func _clear_rebuilt_control_references() -> void:
	# Core and maintenance requests can finish after the user switches category.
	# Keep their cached data, but never let callbacks address controls from the old tree.
	_bg_picker = null
	_primary_picker = null
	_accent_picker = null
	_readability_panel = null
	_readability_row = null
	_resolution_select = null
	_fullscreen_toggle = null
	_category_buttons.clear()
	_subcategory_buttons.clear()
	_developer_role_select = null
	_developer_action_select = null
	_developer_delta_rows = null
	_developer_status = null
	_developer_scope_label = null
	_developer_spinboxes.clear()
	_ambient_controls.clear()
	_ambient_status = null
	_runtime_controls.clear()
	_runtime_status = null
	_runtime_group_reset_buttons.clear()
	_stat_role_select = null
	_stat_controls.clear()
	_stat_status = null
	_provider_base_url_input = null
	_provider_model_input = null
	_provider_api_key_input = null
	_provider_preset_select = null
	_provider_show_key = null
	_provider_save_button = null
	_provider_clear_button = null
	_provider_diagnose_button = null
	_provider_status = null
	_provider_profile_controls.clear()
	_provider_proxy_controls.clear()
	_provider_rag_controls.clear()
	_maintenance_status_label = null
	_maintenance_run_button = null
	_maintenance_backup_list = null
	_maintenance_backup_status = null
	_diagnostic_bundle_button = null
	_diagnostic_open_button = null
	_diagnostic_bundle_status = null
	_rag_document_title = null
	_rag_document_text = null
	_rag_document_scope = null
	_rag_document_source = null
	_rag_document_status = null
	_rag_library_status = null
	_rag_document_filter = null
	_rag_scope_filter = null
	_rag_document_list = null
	_rag_batch_scope = null
	_rag_batch_controls.clear()
	_rag_url_input = null
	_rag_import_scope = null
	_rag_search_query = null
	_rag_search_role = null
	_rag_search_results = null

func _build_core_reliability_section(data: Dictionary) -> void:
	_content.add_child(_section_label("Companion Core 与数据可靠性", data))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_content.add_child(row)
	_maintenance_status_label = Label.new()
	_maintenance_status_label.text = "正在读取 Core 与 SQLite 状态…"
	_maintenance_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_maintenance_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_maintenance_status_label.add_theme_font_size_override("font_size", 11)
	_maintenance_status_label.add_theme_color_override("font_color", Color(data.secondary, 0.96))
	row.add_child(_maintenance_status_label)
	_maintenance_run_button = Button.new()
	_maintenance_run_button.text = "检查并备份"
	_maintenance_run_button.tooltip_text = "在线检查两个 SQLite、执行 WAL checkpoint，并创建一致性备份"
	_maintenance_run_button.pressed.connect(_run_storage_maintenance)
	row.add_child(_maintenance_run_button)
	var refresh_backups := Button.new()
	refresh_backups.text = "查看备份"
	refresh_backups.tooltip_text = "列出 Core 创建的一致性 SQLite 备份"
	refresh_backups.pressed.connect(_refresh_storage_backups)
	row.add_child(refresh_backups)
	_maintenance_backup_status = Label.new()
	_maintenance_backup_status.text = ""
	_maintenance_backup_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_maintenance_backup_status.add_theme_font_size_override("font_size", 10)
	_maintenance_backup_status.add_theme_color_override("font_color", Color(data.secondary, 0.92))
	_content.add_child(_maintenance_backup_status)
	_maintenance_backup_list = VBoxContainer.new()
	_maintenance_backup_list.add_theme_constant_override("separation", 5)
	_content.add_child(_maintenance_backup_list)
	var diagnostics_row := HBoxContainer.new()
	diagnostics_row.add_theme_constant_override("separation", 10)
	_content.add_child(diagnostics_row)
	_diagnostic_bundle_button = Button.new()
	_diagnostic_bundle_button.text = "🧰 生成脱敏诊断包"
	_diagnostic_bundle_button.tooltip_text = "导出运行状态和日志清单，不包含聊天正文、Persona、知识库、数据库或密钥"
	_diagnostic_bundle_button.pressed.connect(_create_playtest_diagnostic_bundle, CONNECT_DEFERRED)
	diagnostics_row.add_child(_diagnostic_bundle_button)
	_diagnostic_open_button = Button.new()
	_diagnostic_open_button.text = "📂 打开目录"
	_diagnostic_open_button.tooltip_text = "打开本机诊断包目录"
	_diagnostic_open_button.disabled = _last_diagnostic_bundle_path.is_empty()
	_diagnostic_open_button.pressed.connect(_open_playtest_diagnostic_directory, CONNECT_DEFERRED)
	diagnostics_row.add_child(_diagnostic_open_button)
	_diagnostic_bundle_status = Label.new()
	_diagnostic_bundle_status.text = "默认仅导出脱敏状态，不收集日志正文"
	_diagnostic_bundle_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_diagnostic_bundle_status.add_theme_font_size_override("font_size", 10)
	_diagnostic_bundle_status.add_theme_color_override("font_color", Color(data.secondary, 0.94))
	_content.add_child(_diagnostic_bundle_status)
	_refresh_maintenance_status.call_deferred()
	_refresh_storage_backups.call_deferred()

func _refresh_maintenance_status() -> void:
	if not is_instance_valid(_maintenance_status_label):
		return
	var managed := CompanionCore.get_managed_core_status()
	var process_text := "Core 由项目托管" if bool(managed.get("owned", false)) else "Core 为外部或手动进程"
	var result: Dictionary = await CompanionCore.get_maintenance_status()
	if not is_instance_valid(_maintenance_status_label):
		return
	if not bool(result.get("ok", false)):
		_maintenance_status_label.text = "%s · 维护状态不可用：%s" % [process_text, str(result.get("message", "Core 离线"))]
		_maintenance_status_label.add_theme_color_override("font_color", Color("#D9A441"))
		return
	var status = result.get("data", {})
	if not status is Dictionary:
		return
	var state := str((status as Dictionary).get("state", "idle"))
	var last_backup_at := int((status as Dictionary).get("last_backup_at", 0))
	var backup_text := "尚未创建自动备份"
	if last_backup_at > 0:
		backup_text = "上次备份 %s" % Time.get_datetime_string_from_unix_time(last_backup_at, true)
	_maintenance_status_label.text = "%s · 存储维护 %s · %s" % [process_text, state, backup_text]
	_maintenance_status_label.add_theme_color_override(
		"font_color", Color("#4CAF7D") if state != "error" else Color("#D9534F")
	)

func _run_storage_maintenance() -> void:
	if not is_instance_valid(_maintenance_run_button) or _maintenance_run_button.disabled:
		return
	_maintenance_run_button.disabled = true
	_maintenance_status_label.text = "正在在线检查并创建一致性备份…"
	var result: Dictionary = await CompanionCore.run_storage_maintenance(true)
	_maintenance_run_button.disabled = false
	if not bool(result.get("ok", false)):
		_maintenance_status_label.text = "维护失败：%s" % str(result.get("message", "Core 不可用"))
		_maintenance_status_label.add_theme_color_override("font_color", Color("#D9534F"))
		return
	await _refresh_maintenance_status()
	await _refresh_storage_backups()

func _refresh_storage_backups() -> void:
	if not is_instance_valid(_maintenance_backup_list) or not is_instance_valid(_maintenance_backup_status):
		return
	for child in _maintenance_backup_list.get_children():
		_maintenance_backup_list.remove_child(child)
		child.queue_free()
	_maintenance_backup_status.text = "正在读取备份清单…"
	var result: Dictionary = await CompanionCore.list_storage_backups()
	if not is_instance_valid(_maintenance_backup_list) or not is_instance_valid(_maintenance_backup_status):
		return
	if not bool(result.get("ok", false)):
		_maintenance_backup_status.text = "备份清单不可用：%s" % str(result.get("message", "Core 离线"))
		_maintenance_backup_status.add_theme_color_override("font_color", Color("#D9A441"))
		return
	var data_variant = result.get("data", {})
	var backups_variant = (data_variant as Dictionary).get("backups", []) if data_variant is Dictionary else []
	if not backups_variant is Array or backups_variant.is_empty():
		_maintenance_backup_status.text = "尚未创建备份"
		return
	_maintenance_backup_status.text = "最近 %d 份备份，可逐份校验哈希与 SQLite 完整性" % backups_variant.size()
	_maintenance_backup_status.add_theme_color_override("font_color", Color(ThemeMgr.get_current_theme_data().secondary, 0.96))
	for index in mini(6, backups_variant.size()):
		var backup_variant = backups_variant[index]
		if not backup_variant is Dictionary:
			continue
		var backup: Dictionary = backup_variant
		var backup_name := str(backup.get("name", ""))
		var backup_row := HBoxContainer.new()
		backup_row.add_theme_constant_override("separation", 8)
		_maintenance_backup_list.add_child(backup_row)
		var label := Label.new()
		label.text = "%s · %s · %.2f MB" % [
			backup_name,
			Time.get_datetime_string_from_unix_time(int(backup.get("created_at", 0)), true),
			float(backup.get("total_bytes", 0)) / 1048576.0,
		]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.add_theme_font_size_override("font_size", 10)
		label.add_theme_color_override(
			"font_color",
			Color(ThemeMgr.get_current_theme_data().text, 0.90)
			if bool(backup.get("manifest_valid", false))
			else Color("#D9534F")
		)
		backup_row.add_child(label)
		var verify := Button.new()
		verify.text = "校验"
		verify.tooltip_text = "只读校验 SHA-256 与 SQLite quick_check，不会恢复或改写数据"
		verify.pressed.connect(
			func(): _verify_storage_backup(backup_name),
			CONNECT_DEFERRED
		)
		backup_row.add_child(verify)

func _verify_storage_backup(backup_name: String) -> void:
	if not is_instance_valid(_maintenance_backup_status):
		return
	_maintenance_backup_status.text = "正在校验 %s…" % backup_name
	var result: Dictionary = await CompanionCore.verify_storage_backup(backup_name)
	if not is_instance_valid(_maintenance_backup_status):
		return
	if not bool(result.get("ok", false)):
		_maintenance_backup_status.text = "备份校验失败：%s" % str(result.get("message", "未知错误"))
		_maintenance_backup_status.add_theme_color_override("font_color", Color("#D9534F"))
		return
	var data_variant = result.get("data", {})
	var verified := data_variant is Dictionary and bool((data_variant as Dictionary).get("ok", false))
	_maintenance_backup_status.text = "%s · %s" % [
		backup_name,
		"哈希与 SQLite 完整性均通过" if verified else "校验未通过，请保留当前运行库并检查日志",
	]
	_maintenance_backup_status.add_theme_color_override(
		"font_color", Color("#4CAF7D") if verified else Color("#D9534F")
	)

func _create_playtest_diagnostic_bundle() -> void:
	if not is_instance_valid(_diagnostic_bundle_button) or _diagnostic_bundle_button.disabled:
		return
	_diagnostic_bundle_button.disabled = true
	if is_instance_valid(_diagnostic_bundle_status):
		_diagnostic_bundle_status.text = "正在收集脱敏运行状态…"
		_diagnostic_bundle_status.add_theme_color_override(
			"font_color", Color(ThemeMgr.get_current_theme_data().primary)
		)
	var result: Dictionary = await PLAYTEST_DIAGNOSTICS.create_bundle(
		CompanionCore,
		_diagnostic_settings_summary(),
		_diagnostic_state_summary(),
		{"include_sanitized_logs": false}
	)
	if not is_instance_valid(_diagnostic_bundle_button):
		return
	_diagnostic_bundle_button.disabled = false
	if not bool(result.get("ok", false)):
		if is_instance_valid(_diagnostic_bundle_status):
			_diagnostic_bundle_status.text = "诊断包生成失败：%s" % str(result.get("message", "未知错误"))
			_diagnostic_bundle_status.add_theme_color_override("font_color", Color("#D9534F"))
		return
	_last_diagnostic_bundle_path = str(result.get("path", ""))
	if is_instance_valid(_diagnostic_open_button):
		_diagnostic_open_button.disabled = _last_diagnostic_bundle_path.is_empty()
	if is_instance_valid(_diagnostic_bundle_status):
		_diagnostic_bundle_status.text = "诊断包已生成 · %d 个脱敏条目" % int(result.get("entry_count", 0))
		_diagnostic_bundle_status.add_theme_color_override("font_color", Color("#4CAF7D"))

func _open_playtest_diagnostic_directory() -> void:
	var directory := ProjectSettings.globalize_path("user://SpringHaven/diagnostics").simplify_path()
	if not DirAccess.dir_exists_absolute(directory):
		if is_instance_valid(_diagnostic_bundle_status):
			_diagnostic_bundle_status.text = "尚未生成诊断包"
		return
	var open_error := OS.shell_open(directory)
	if open_error != OK and is_instance_valid(_diagnostic_bundle_status):
		_diagnostic_bundle_status.text = "无法打开诊断目录：%s" % error_string(open_error)
		_diagnostic_bundle_status.add_theme_color_override("font_color", Color("#D9534F"))

func _diagnostic_settings_summary() -> Dictionary:
	var display = Settings.settings.get("display", {})
	var ui = Settings.settings.get("ui", {})
	return {
		"display": {
			"view_mode": str((display as Dictionary).get("view_mode", "")) if display is Dictionary else "",
			"resolution": str((display as Dictionary).get("resolution", "")) if display is Dictionary else "",
			"fullscreen": bool((display as Dictionary).get("fullscreen", false)) if display is Dictionary else false,
			"vsync": bool((display as Dictionary).get("vsync", true)) if display is Dictionary else true,
		},
		"ui": {
			"theme": str((ui as Dictionary).get("theme", "")) if ui is Dictionary else "",
			"font_size": int((ui as Dictionary).get("font_size", 15)) if ui is Dictionary else 15,
			"font_family": str((ui as Dictionary).get("font_family", "")) if ui is Dictionary else "",
			"language": str((ui as Dictionary).get("language", "")) if ui is Dictionary else "",
		},
		"ambient_dialogue": Settings.get_ambient_dialogue_settings(),
		"runtime_tuning": Settings.get_runtime_tuning(),
		"settings_last_error": Settings.last_save_error,
	}

func _diagnostic_state_summary() -> Dictionary:
	var role_ids: Array[String] = []
	var stat_fields_by_role := {}
	for role_variant in Global.stats_by_role:
		var role_id := str(role_variant)
		role_ids.append(role_id)
		var role_stats = Global.stats_by_role[role_variant]
		var fields: Array[String] = []
		if role_stats is Dictionary:
			for field_variant in (role_stats as Dictionary):
				fields.append(str(field_variant))
			fields.sort()
		stat_fields_by_role[role_id] = fields
	role_ids.sort()
	var life_sections: Array[String] = []
	for section_variant in Global.life_runtime:
		life_sections.append(str(section_variant))
	life_sections.sort()
	return {
		"state_loaded": Global.is_state_loaded(),
		"save_schema_version": Global.SAVE_VERSION,
		"selected_role": Global.current_character,
		"role_ids": role_ids,
		"stat_fields_by_role": stat_fields_by_role,
		"conversation_message_count": Global.conversation_history.size(),
		"life_runtime_sections": life_sections,
	}

func _build_header(data: Dictionary) -> void:
	var header := HBoxContainer.new()
	_content.add_child(header)
	var title := Label.new()
	title.text = "⚙️ 设置"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(data.text))
	header.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var close_button := Button.new()
	close_button.text = "✕"
	close_button.flat = true
	close_button.tooltip_text = "关闭"
	close_button.custom_minimum_size = Vector2(36, 36)
	close_button.add_theme_color_override("font_color", Color(data.text))
	close_button.add_theme_color_override("font_hover_color", Color(data.primary))
	close_button.pressed.connect(_request_close_panel)
	header.add_child(close_button)

func _build_category_navigation(data: Dictionary) -> void:
	_category_buttons.clear()
	var navigation := HFlowContainer.new()
	navigation.add_theme_constant_override("h_separation", 7)
	navigation.add_theme_constant_override("v_separation", 7)
	_content.add_child(navigation)
	for category_variant in SETTINGS_CATEGORIES:
		var category: Dictionary = category_variant
		var category_id := str(category.id)
		var button := Button.new()
		button.text = "%s  %s" % [str(category.icon), str(category.label)]
		button.toggle_mode = true
		button.button_pressed = category_id == _settings_category
		button.custom_minimum_size = Vector2(128, 38)
		button.add_theme_color_override("font_color", Color(data.text, 0.88))
		button.add_theme_color_override("font_hover_color", Color(data.text))
		button.add_theme_stylebox_override(
			"normal", _style(Color(data.text, 0.045), Color(data.text, 0.11), 7, 7)
		)
		button.add_theme_stylebox_override(
			"hover", _style(Color(data.primary, 0.10), Color(data.primary, 0.42), 7, 7)
		)
		if category_id == _settings_category:
			var selected_style := _style(Color(data.primary, 0.19), Color(data.primary, 0.78), 7, 7)
			button.add_theme_stylebox_override("normal", selected_style)
			button.add_theme_stylebox_override("pressed", selected_style)
			button.add_theme_color_override("font_pressed_color", Color(data.text))
		var selected_id := category_id
		button.pressed.connect(
			func(): _switch_settings_category(selected_id),
			CONNECT_DEFERRED
		)
		navigation.add_child(button)
		_category_buttons[category_id] = button

func _build_subcategory_navigation(data: Dictionary) -> void:
	_subcategory_buttons.clear()
	var definitions = SETTINGS_SUBCATEGORIES.get(_settings_category, [])
	if not definitions is Array or (definitions as Array).is_empty():
		return
	var navigation := HFlowContainer.new()
	navigation.add_theme_constant_override("h_separation", 5)
	navigation.add_theme_constant_override("v_separation", 5)
	_content.add_child(navigation)
	for definition_variant in definitions:
		var definition: Dictionary = definition_variant
		var subcategory_id := str(definition.id)
		var button := Button.new()
		button.text = str(definition.label)
		button.toggle_mode = true
		button.button_pressed = subcategory_id == _settings_subcategory
		button.custom_minimum_size = Vector2(112, 32)
		button.add_theme_color_override("font_color", Color(data.text, 0.82))
		button.add_theme_color_override("font_hover_color", Color(data.text))
		button.add_theme_stylebox_override(
			"normal", _style(Color(data.text, 0.025), Color(data.text, 0.09), 7, 6)
		)
		button.add_theme_stylebox_override(
			"hover", _style(Color(data.accent, 0.09), Color(data.accent, 0.36), 7, 6)
		)
		if subcategory_id == _settings_subcategory:
			var selected_style := _style(Color(data.accent, 0.16), Color(data.accent, 0.66), 7, 6)
			button.add_theme_stylebox_override("normal", selected_style)
			button.add_theme_stylebox_override("pressed", selected_style)
			button.add_theme_color_override("font_pressed_color", Color(data.text))
		var selected_id := subcategory_id
		button.pressed.connect(
			func(): _switch_settings_subcategory(selected_id),
			CONNECT_DEFERRED
		)
		navigation.add_child(button)
		_subcategory_buttons[subcategory_id] = button

func _switch_settings_category(category_id: String) -> void:
	if category_id == "interaction":
		category_id = "advanced"
		_settings_subcategory_by_category["advanced"] = "interaction"
	if category_id == _settings_category:
		return
	_capture_visible_category_draft()
	_settings_category = category_id
	_settings_subcategory = str(_settings_subcategory_by_category.get(
		category_id, DEFAULT_SETTINGS_SUBCATEGORIES.get(category_id, "")
	))
	_rebuild_content()
	_restore_visible_category_draft()
	if category_id == "ai" and _provider_status_data.is_empty():
		_refresh_provider_status.call_deferred()

func _switch_settings_subcategory(subcategory_id: String) -> void:
	if subcategory_id == _settings_subcategory:
		return
	var definitions = SETTINGS_SUBCATEGORIES.get(_settings_category, [])
	var valid := false
	if definitions is Array:
		for definition_variant in definitions:
			if definition_variant is Dictionary and str((definition_variant as Dictionary).get("id", "")) == subcategory_id:
				valid = true
				break
	if not valid:
		return
	_capture_visible_category_draft()
	_settings_subcategory = subcategory_id
	_settings_subcategory_by_category[_settings_category] = subcategory_id
	_rebuild_content()
	_restore_visible_category_draft()

func _set_content_children_visible(start_index: int, visible: bool) -> void:
	for index in range(start_index, _content.get_child_count()):
		(_content.get_child(index) as CanvasItem).visible = visible

func _show_settings_page(pages: Dictionary) -> void:
	for page_id_variant in pages:
		var page = pages[page_id_variant]
		if page is CanvasItem:
			(page as CanvasItem).visible = str(page_id_variant) == _settings_subcategory

func _build_general_settings_pages(data: Dictionary) -> void:
	var start := _content.get_child_count()
	_build_theme_section(data)
	_build_custom_color_section(data)
	_set_content_children_visible(start, _settings_subcategory == "appearance")
	start = _content.get_child_count()
	_build_display_section(data)
	_build_audio_section(data)
	_set_content_children_visible(start, _settings_subcategory == "window_audio")
	start = _content.get_child_count()
	_build_readability(data)
	_build_size_section(data)
	_build_font_section(data)
	_set_content_children_visible(start, _settings_subcategory == "readability")

func _build_life_settings_pages(data: Dictionary) -> void:
	var start := _content.get_child_count()
	_build_developer_ambient_section(data)
	_set_content_children_visible(start, _settings_subcategory == "autonomy")
	start = _content.get_child_count()
	_build_2d_presentation_section(data)
	_set_content_children_visible(start, _settings_subcategory == "presentation")

func _build_advanced_settings_pages(data: Dictionary) -> void:
	var start := _content.get_child_count()
	_build_core_reliability_section(data)
	_set_content_children_visible(start, _settings_subcategory == "reliability")
	start = _content.get_child_count()
	_build_current_stats_editor(data)
	_set_content_children_visible(start, _settings_subcategory == "state")
	start = _content.get_child_count()
	_build_developer_runtime_section(data, false)
	_set_content_children_visible(start, _settings_subcategory == "runtime")
	start = _content.get_child_count()
	_build_developer_interaction_section(data)
	_set_content_children_visible(start, _settings_subcategory == "interaction")

func _build_2d_presentation_section(data: Dictionary) -> void:
	_content.add_child(_section_label("角色表现层", data))
	var card := PanelContainer.new()
	card.add_theme_stylebox_override(
		"panel", _style(Color(data.primary, 0.055), Color(data.text, 0.12), 8, 12)
	)
	_content.add_child(card)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 9)
	card.add_child(column)
	var title := Label.new()
	title.text = "🎭 2D 对话舞台"
	title.add_theme_font_size_override("font_size", 15)
	title.add_theme_color_override("font_color", Color(data.primary))
	column.add_child(title)
	var summary := Label.new()
	summary.text = "对话、记忆、生活状态与互动规则由 Companion Core 统一驱动；立绘、分层动画与未来 Live2D 只负责表现。"
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	summary.add_theme_font_size_override("font_size", 11)
	summary.add_theme_color_override("font_color", Color(data.secondary, 0.96))
	column.add_child(summary)
	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 7)
	column.add_child(mode_row)
	var mode_label := Label.new()
	mode_label.text = "默认入口"
	mode_label.custom_minimum_size = Vector2(92, 0)
	mode_row.add_child(mode_label)
	var current_mode := str(Settings.settings.display.get("view_mode", "2d"))
	var mode_group := ButtonGroup.new()
	mode_group.allow_unpress = false
	for mode in [
		{"id": "2d", "label": "2D 对话舞台"},
		{"id": "3d", "label": "3D 探索实验"},
	]:
		var button := Button.new()
		button.text = str(mode.label)
		button.toggle_mode = true
		button.button_group = mode_group
		button.button_pressed = current_mode == str(mode.id)
		button.custom_minimum_size = Vector2(148, 34)
		var mode_id := str(mode.id)
		button.pressed.connect(func(): Settings.set_setting("display", "view_mode", mode_id))
		mode_row.add_child(button)
	var adapter_status := Label.new()
	adapter_status.text = "当前渲染器：分层立绘适配器 · 已支持眨眼、视线、呼吸、口型、思考与情绪状态"
	adapter_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	adapter_status.add_theme_font_size_override("font_size", 10)
	adapter_status.add_theme_color_override("font_color", Color(data.text, 0.88))
	column.add_child(adapter_status)

func _build_display_section(data: Dictionary) -> void:
	_content.add_child(_section_label("显示", data))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_content.add_child(row)

	_resolution_select = OptionButton.new()
	_resolution_select.custom_minimum_size = Vector2(220, 36)
	_resolution_select.tooltip_text = "窗口分辨率"
	var current_resolution := Settings.get_resolution()
	var selected_index := 0
	for key in Settings.RESOLUTIONS.keys():
		var index := _resolution_select.item_count
		_resolution_select.add_item(str(key))
		_resolution_select.set_item_metadata(index, str(key))
		if str(key) == current_resolution:
			selected_index = index
	_resolution_select.select(selected_index)
	_resolution_select.disabled = bool(Settings.settings.display.fullscreen)
	_resolution_select.item_selected.connect(_on_resolution_selected)
	var resolution_popup := _resolution_select.get_popup()
	resolution_popup.add_theme_color_override("font_color", Color(data.text))
	resolution_popup.add_theme_color_override("font_hover_color", Color(data.text))
	resolution_popup.add_theme_stylebox_override("panel", _style(Color(data.bg), Color(data.text, 0.22), 10, 8))
	resolution_popup.add_theme_stylebox_override("hover", _style(Color(data.primary, 0.16), Color(data.primary), 7, 8))
	row.add_child(_resolution_select)

	_fullscreen_toggle = CheckBox.new()
	_fullscreen_toggle.text = "全屏"
	_fullscreen_toggle.button_pressed = bool(Settings.settings.display.fullscreen)
	_fullscreen_toggle.toggled.connect(_on_fullscreen_toggled)
	row.add_child(_fullscreen_toggle)

	var vsync_toggle := CheckBox.new()
	vsync_toggle.text = "垂直同步"
	vsync_toggle.button_pressed = bool(Settings.settings.display.vsync)
	vsync_toggle.toggled.connect(_on_vsync_toggled)
	row.add_child(vsync_toggle)

func _build_theme_section(data: Dictionary) -> void:
	_content.add_child(_section_label("预设主题", data))
	var grid := GridContainer.new()
	var viewport_width := get_viewport_rect().size.x
	grid.columns = 3 if viewport_width <= 520.0 else 4 if viewport_width <= 820.0 else 6
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	_content.add_child(grid)
	for key in ThemeMgr.get_theme_keys():
		var item_data := ThemeMgr.get_theme_data(str(key))
		var button := Button.new()
		button.text = ""
		button.custom_minimum_size = Vector2(88, 48)
		var style := _style(Color(1, 1, 1, 0.025), Color(item_data.primary) if str(key) == ThemeMgr.current_theme_name else Color(data.text, 0.10), 10, 5)
		button.add_theme_stylebox_override("normal", style)
		var hover := style.duplicate()
		hover.border_color = Color(item_data.primary)
		button.add_theme_stylebox_override("hover", hover)
		var center := CenterContainer.new()
		center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		center.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.add_child(center)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		center.add_child(row)
		var dot := PanelContainer.new()
		dot.custom_minimum_size = Vector2(18, 18)
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dot.add_theme_stylebox_override("panel", _style(Color(item_data.primary), Color(item_data.bg), 9, 0))
		row.add_child(dot)
		var name := Label.new()
		name.text = str(key).capitalize()
		name.add_theme_font_size_override("font_size", 9)
		name.add_theme_color_override("font_color", Color(data.text))
		name.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(name)
		var theme_key := str(key)
		button.pressed.connect(func():
			Settings.settings.ui.theme = theme_key
			Settings.save()
			ThemeMgr.apply_theme(theme_key)
		)
		grid.add_child(button)

func _build_audio_section(data: Dictionary) -> void:
	_content.add_child(_section_label("声音", data))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_content.add_child(row)

	var label := Label.new()
	label.text = "背景音乐"
	label.custom_minimum_size = Vector2(76, 0)
	row.add_child(label)

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.value = Audio.get_music_volume()
	slider.custom_minimum_size = Vector2(230, 32)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(slider)

	var value_label := Label.new()
	value_label.text = "%d%%" % roundi(slider.value * 100.0)
	value_label.custom_minimum_size = Vector2(48, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value_label)

	var mute_button := Button.new()
	mute_button.text = "静音" if slider.value > 0.0 else "恢复"
	mute_button.custom_minimum_size = Vector2(70, 32)
	row.add_child(mute_button)

	slider.value_changed.connect(func(value: float):
		Audio.set_music_volume(value)
		value_label.text = "%d%%" % roundi(value * 100.0)
		mute_button.text = "静音" if value > 0.0 else "恢复"
	)
	mute_button.pressed.connect(func():
		slider.value = 0.0 if slider.value > 0.0 else 0.7
	)
func _build_custom_color_section(data: Dictionary) -> void:
	_content.add_child(_section_label("自定义颜色", data))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	_content.add_child(row)
	_bg_picker = _color_picker("背景", Color(data.bg), row)
	_primary_picker = _color_picker("主色", Color(data.primary), row)
	_accent_picker = _color_picker("强调", Color(data.accent), row)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var apply_button := Button.new()
	apply_button.text = "应用"
	apply_button.custom_minimum_size = Vector2(76, 34)
	apply_button.pressed.connect(_apply_custom_colors)
	row.add_child(apply_button)

func _build_readability(data: Dictionary) -> void:
	_readability_panel = PanelContainer.new()
	_content.add_child(_readability_panel)
	_readability_row = HBoxContainer.new()
	_readability_row.add_theme_constant_override("separation", 8)
	_readability_panel.add_child(_readability_row)
	_update_readability(data)

func _build_size_section(data: Dictionary) -> void:
	_content.add_child(_section_label("界面字号", data))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	_content.add_child(row)
	var labels := {13: "小", 15: "默认", 17: "大", 19: "特大", 21: "超大"}
	for size in labels:
		var button := Button.new()
		button.text = labels[size]
		button.custom_minimum_size = Vector2(74, 34)
		if int(Settings.settings.ui.font_size) == size:
			button.add_theme_stylebox_override("normal", _style(Color(data.primary, 0.24), Color(data.primary), 17, 5))
		var selected_size: int = size
		button.pressed.connect(func():
			Settings.settings.ui.font_size = selected_size
			Settings.save()
			ThemeMgr.apply_theme(str(Settings.settings.ui.theme))
			Global.font_size_changed.emit(selected_size)
		)
		row.add_child(button)

func _build_font_section(data: Dictionary) -> void:
	_content.add_child(_section_label("界面字体", data))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	_content.add_child(row)
	var fonts := {"system": "系统", "serif": "宋体", "modern": "现代", "mono": "等宽"}
	for family in fonts:
		var button := Button.new()
		button.text = fonts[family]
		button.custom_minimum_size = Vector2(82, 34)
		if str(Settings.settings.ui.font_family) == family:
			button.add_theme_stylebox_override("normal", _style(Color(data.primary, 0.24), Color(data.primary), 17, 5))
		var selected_family := str(family)
		button.pressed.connect(func():
			Settings.settings.ui.font_family = selected_family
			Settings.save()
			ThemeMgr.apply_theme(str(Settings.settings.ui.theme))
			Global.font_size_changed.emit(int(Settings.settings.ui.font_size))
		)
		row.add_child(button)

func _build_ai_provider_section(data: Dictionary) -> void:
	_provider_profile_controls.clear()
	_provider_fallback_controls.clear()
	_content.add_child(_section_label("AI 模型连接", data))
	var card := PanelContainer.new()
	card.add_theme_stylebox_override(
		"panel",
		_style(Color(data.primary, 0.055), Color(data.text, 0.12), 12, 12)
	)
	_content.add_child(card)
	var page_stack := VBoxContainer.new()
	page_stack.add_theme_constant_override("separation", 0)
	card.add_child(page_stack)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 9)
	page_stack.add_child(column)
	var pages := {"chat": column}

	var notice := Label.new()
	notice.text = "支持 OpenAI、DeepSeek 与 LM Studio 等 OpenAI-compatible 接口。API Key 不会回显，并由 Windows 当前用户加密保存。"
	notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	notice.add_theme_font_size_override("font_size", 11)
	notice.add_theme_color_override("font_color", Color(data.secondary, 0.96))
	column.add_child(notice)
	var preset_row := HBoxContainer.new()
	preset_row.add_theme_constant_override("separation", 8)
	column.add_child(preset_row)
	var preset_label := Label.new()
	preset_label.text = "快速填写"
	preset_label.custom_minimum_size = Vector2(88, 0)
	preset_row.add_child(preset_label)
	_provider_preset_select = OptionButton.new()
	_provider_preset_select.custom_minimum_size = Vector2(180, 34)
	_provider_preset_select.add_item("选择服务预设…")
	for preset_name in PROVIDER_PRESETS:
		var preset_index := _provider_preset_select.item_count
		_provider_preset_select.add_item(str(preset_name))
		_provider_preset_select.set_item_metadata(
			preset_index,
			(PROVIDER_PRESETS[preset_name] as Dictionary).duplicate(true)
		)
	_provider_preset_select.select(0)
	_provider_preset_select.item_selected.connect(_on_provider_preset_selected)
	preset_row.add_child(_provider_preset_select)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 8)
	column.add_child(grid)

	var base_label := Label.new()
	base_label.text = "Base URL"
	base_label.custom_minimum_size = Vector2(88, 0)
	grid.add_child(base_label)
	_provider_base_url_input = LineEdit.new()
	_provider_base_url_input.text = str(_provider_loaded_values.get("base_url", ""))
	_provider_base_url_input.placeholder_text = "https://api.openai.com/v1"
	_provider_base_url_input.tooltip_text = "远程服务必须使用 HTTPS；本机 localhost 可以使用 HTTP。"
	_provider_base_url_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_provider_base_url_input.text_changed.connect(func(_value: String):
		_update_provider_dirty_state()
	)
	grid.add_child(_provider_base_url_input)

	var model_label := Label.new()
	model_label.text = "模型名称"
	grid.add_child(model_label)
	_provider_model_input = LineEdit.new()
	_provider_model_input.text = str(_provider_loaded_values.get("model", ""))
	_provider_model_input.placeholder_text = "gpt-4.1-mini"
	_provider_model_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_provider_model_input.text_changed.connect(func(_value: String):
		_update_provider_dirty_state()
	)
	grid.add_child(_provider_model_input)

	var key_label := Label.new()
	key_label.text = "API Key"
	grid.add_child(key_label)
	var key_row := HBoxContainer.new()
	key_row.add_theme_constant_override("separation", 7)
	grid.add_child(key_row)
	_provider_api_key_input = LineEdit.new()
	_provider_api_key_input.secret = true
	_provider_api_key_input.placeholder_text = "留空则保持当前 Key"
	_provider_api_key_input.tooltip_text = "密钥不会从 Companion Core 回传到界面。"
	_provider_api_key_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_provider_api_key_input.text_changed.connect(func(_value: String):
		_update_provider_dirty_state()
	)
	key_row.add_child(_provider_api_key_input)
	_provider_show_key = CheckBox.new()
	_provider_show_key.text = "显示"
	_provider_show_key.tooltip_text = "只显示本次新输入的内容，已保存的密钥永不回显。"
	_provider_show_key.toggled.connect(func(show_key: bool):
		if is_instance_valid(_provider_api_key_input):
			_provider_api_key_input.secret = not show_key
	)
	key_row.add_child(_provider_show_key)

	var command_row := HBoxContainer.new()
	command_row.add_theme_constant_override("separation", 8)
	column.add_child(command_row)
	_provider_save_button = Button.new()
	_provider_save_button.text = "保存并立即应用"
	_provider_save_button.custom_minimum_size = Vector2(150, 34)
	_provider_save_button.pressed.connect(_save_provider_settings)
	command_row.add_child(_provider_save_button)
	_provider_clear_button = Button.new()
	_provider_clear_button.text = "清除已保存 Key"
	_provider_clear_button.custom_minimum_size = Vector2(132, 34)
	_provider_clear_button.pressed.connect(_request_clear_provider_api_key)
	command_row.add_child(_provider_clear_button)
	_provider_diagnose_button = Button.new()
	_provider_diagnose_button.text = "测试连接"
	_provider_diagnose_button.tooltip_text = "发送最小请求，检查模型、代理、延迟与令牌统计"
	_provider_diagnose_button.pressed.connect(func(): _diagnose_provider("chat"))
	command_row.add_child(_provider_diagnose_button)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	command_row.add_child(spacer)
	_provider_status = Label.new()
	_provider_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_provider_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_provider_status.custom_minimum_size = Vector2(190, 0)
	_provider_status.add_theme_font_size_override("font_size", 11)
	command_row.add_child(_provider_status)
	_render_provider_status()
	_sync_provider_buttons()
	var capabilities_page := VBoxContainer.new()
	capabilities_page.add_theme_constant_override("separation", 9)
	page_stack.add_child(capabilities_page)
	pages["capabilities"] = capabilities_page
	var capability_nav := HFlowContainer.new()
	capability_nav.add_theme_constant_override("h_separation", 5)
	capabilities_page.add_child(capability_nav)
	var capability_group := ButtonGroup.new()
	var capability_pages := {}
	for capability_variant in CAPABILITY_PROVIDER_UI:
		var capability := str(capability_variant)
		_add_provider_focus_button(
			capability_nav,
			capability_group,
			capability,
			str(PROVIDER_CAPABILITY_LABELS.get(capability, capability)),
			capability == _provider_capability_focus,
			Callable(self, "_switch_provider_capability_focus"),
			data
		)
		var capability_page := VBoxContainer.new()
		capability_page.add_theme_constant_override("separation", 9)
		capabilities_page.add_child(capability_page)
		capability_pages[capability] = capability_page
		_build_capability_provider_editor(capability_page, capability, data, false)
	for capability_variant in capability_pages:
		(capability_pages[capability_variant] as CanvasItem).visible = str(capability_variant) == _provider_capability_focus
	var fallback_page := VBoxContainer.new()
	fallback_page.add_theme_constant_override("separation", 12)
	page_stack.add_child(fallback_page)
	pages["fallbacks"] = fallback_page
	var fallback_nav := HFlowContainer.new()
	fallback_nav.add_theme_constant_override("h_separation", 5)
	fallback_page.add_child(fallback_nav)
	var fallback_group := ButtonGroup.new()
	var fallback_pages := {}
	for capability in ["chat", "vision", "embedding", "rerank", "asr", "tts"]:
		_add_provider_focus_button(
			fallback_nav,
			fallback_group,
			capability,
			str(PROVIDER_CAPABILITY_LABELS.get(capability, capability)),
			capability == _provider_fallback_focus,
			Callable(self, "_switch_provider_fallback_focus"),
			data
		)
		var capability_page := VBoxContainer.new()
		capability_page.add_theme_constant_override("separation", 7)
		fallback_page.add_child(capability_page)
		fallback_pages[capability] = capability_page
		var fallback_title := Label.new()
		fallback_title.text = "%s模型候选链" % str(PROVIDER_CAPABILITY_LABELS.get(capability, capability))
		fallback_title.add_theme_font_size_override("font_size", 13)
		fallback_title.add_theme_color_override("font_color", Color(data.primary))
		capability_page.add_child(fallback_title)
		_build_provider_fallback_editor(capability_page, capability, data)
	for capability_variant in fallback_pages:
		(fallback_pages[capability_variant] as CanvasItem).visible = str(capability_variant) == _provider_fallback_focus
	var network_page := VBoxContainer.new()
	network_page.add_theme_constant_override("separation", 9)
	page_stack.add_child(network_page)
	pages["network"] = network_page
	_build_network_proxy_editor(network_page, data)
	_show_settings_page(pages)

func _add_provider_focus_button(
	parent: HFlowContainer,
	group: ButtonGroup,
	capability: String,
	label_text: String,
	selected: bool,
	callback: Callable,
	data: Dictionary
) -> void:
	var button := Button.new()
	button.text = label_text
	button.toggle_mode = true
	button.button_group = group
	button.button_pressed = selected
	button.custom_minimum_size = Vector2(92, 30)
	if selected:
		var selected_style := _style(Color(data.primary, 0.16), Color(data.primary, 0.62), 7, 5)
		button.add_theme_stylebox_override("normal", selected_style)
		button.add_theme_stylebox_override("pressed", selected_style)
	button.pressed.connect(callback.bind(capability), CONNECT_DEFERRED)
	parent.add_child(button)

func _switch_provider_capability_focus(capability: String) -> void:
	if capability not in CAPABILITY_PROVIDER_UI or capability == _provider_capability_focus:
		return
	_capture_visible_category_draft()
	_provider_capability_focus = capability
	_rebuild_content()
	_restore_visible_category_draft()

func _switch_provider_fallback_focus(capability: String) -> void:
	if capability not in PROVIDER_CAPABILITY_LABELS or capability == _provider_fallback_focus:
		return
	_capture_visible_category_draft()
	_provider_fallback_focus = capability
	_rebuild_content()
	_restore_visible_category_draft()

func _build_network_proxy_editor(parent: VBoxContainer, data: Dictionary) -> void:
	_provider_proxy_controls.clear()
	parent.add_child(HSeparator.new())
	var heading := Label.new()
	heading.text = "网络与代理"
	heading.add_theme_font_size_override("font_size", 13)
	heading.add_theme_color_override("font_color", Color(data.primary))
	parent.add_child(heading)
	var note := Label.new()
	note.text = "代理只用于 Companion Core 访问外部模型和导入网页；本机 127.0.0.1 通信始终直连。自定义模式支持常见的 Clash、Mihomo 等 HTTP 代理端口。"
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 10)
	note.add_theme_color_override("font_color", Color(data.secondary, 0.96))
	parent.add_child(note)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	var mode_select := OptionButton.new()
	mode_select.custom_minimum_size = Vector2(148, 34)
	for option in [
		{"label": "直连", "value": "direct"},
		{"label": "系统代理", "value": "system"},
		{"label": "自定义 HTTP 代理", "value": "custom"},
	]:
		var index := mode_select.item_count
		mode_select.add_item(str(option.label))
		mode_select.set_item_metadata(index, str(option.value))
	row.add_child(mode_select)
	var proxy_url := LineEdit.new()
	proxy_url.placeholder_text = "例如 http://127.0.0.1:7890"
	proxy_url.tooltip_text = "不支持在 URL 中保存代理用户名或密码；SOCKS5 端口不能直接填写。"
	proxy_url.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(proxy_url)
	var save := Button.new()
	save.text = "保存代理设置"
	save.custom_minimum_size = Vector2(128, 34)
	row.add_child(save)
	var status := Label.new()
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	status.custom_minimum_size = Vector2(180, 0)
	status.add_theme_font_size_override("font_size", 10)
	row.add_child(status)
	_provider_proxy_controls = {
		"mode": mode_select,
		"url": proxy_url,
		"save": save,
		"status": status,
	}
	_apply_provider_proxy_values_to_controls(_provider_proxy_loaded)
	mode_select.item_selected.connect(func(_index: int):
		_update_provider_proxy_dirty()
		_sync_provider_proxy_url_state()
	)
	proxy_url.text_changed.connect(func(_value: String): _update_provider_proxy_dirty())
	save.pressed.connect(_save_network_proxy)
	_render_provider_proxy_status()
	_sync_provider_proxy_controls()

func _collect_provider_proxy_values() -> Dictionary:
	if not _provider_proxy_controls_valid():
		return {}
	var mode := _provider_proxy_controls.mode as OptionButton
	return {
		"mode": str(mode.get_item_metadata(mode.selected)),
		"url": (_provider_proxy_controls.url as LineEdit).text.strip_edges(),
	}

func _apply_provider_proxy_values_to_controls(values: Dictionary) -> void:
	if not _provider_proxy_controls_valid():
		return
	_provider_suppress_dirty = true
	var mode := _provider_proxy_controls.mode as OptionButton
	for index in mode.item_count:
		if str(mode.get_item_metadata(index)) == str(values.get("mode", "direct")):
			mode.select(index)
			break
	(_provider_proxy_controls.url as LineEdit).text = str(values.get("url", ""))
	_provider_suppress_dirty = false
	_sync_provider_proxy_url_state()

func _sync_provider_proxy_url_state() -> void:
	if not _provider_proxy_controls_valid():
		return
	var mode := _provider_proxy_controls.mode as OptionButton
	var custom := str(mode.get_item_metadata(mode.selected)) == "custom"
	(_provider_proxy_controls.url as LineEdit).editable = custom
	(_provider_proxy_controls.url as LineEdit).placeholder_text = (
		"例如 http://127.0.0.1:7890" if custom else "当前模式不需要填写代理地址"
	)

func _update_provider_proxy_dirty() -> void:
	if _provider_suppress_dirty:
		return
	var current := _collect_provider_proxy_values()
	if str(current.get("mode", "direct")) != "custom":
		current["url"] = ""
	_provider_proxy_dirty = current != _provider_proxy_loaded
	_render_provider_proxy_status()
	_sync_provider_proxy_controls()

func _save_network_proxy() -> void:
	if _provider_busy or not _provider_proxy_dirty:
		return
	var values := _collect_provider_proxy_values()
	_provider_busy = true
	_provider_write_in_flight = true
	_set_provider_proxy_status("正在保存…", Color(ThemeMgr.get_current_theme_data().primary))
	_sync_provider_proxy_controls()
	var result: Dictionary = await CompanionCore.configure_network_proxy(
		str(values.get("mode", "direct")), str(values.get("url", ""))
	)
	_provider_busy = false
	_provider_write_in_flight = false
	if not bool(result.get("ok", false)):
		_set_provider_proxy_status(
			"保存失败：%s" % str(result.get("message", "代理设置无效")), Color("#D9534F")
		)
		_sync_provider_proxy_controls()
		return
	var response_data = result.get("data", {})
	var normalized = (response_data as Dictionary).get("network_proxy", values) if response_data is Dictionary else values
	_provider_proxy_loaded = (normalized as Dictionary).duplicate(true) if normalized is Dictionary else values.duplicate(true)
	_provider_proxy_dirty = false
	_apply_provider_proxy_values_to_controls(_provider_proxy_loaded)
	_render_provider_proxy_status("已保存，后续请求立即生效")
	_sync_provider_proxy_controls()

func _render_provider_proxy_status(prefix: String = "") -> void:
	if not _provider_proxy_controls_valid():
		return
	var text := prefix
	var color := Color("#4CAF7D")
	if _provider_proxy_dirty:
		text = "有未保存修改"
		color = Color("#D9A441")
	elif text.is_empty():
		match str(_provider_proxy_loaded.get("mode", "direct")):
			"system": text = "使用系统代理环境变量"
			"custom": text = "使用自定义代理"
			_: text = "外部请求直连"
		color = Color(ThemeMgr.get_current_theme_data().secondary, 0.96)
	_set_provider_proxy_status(text, color)

func _set_provider_proxy_status(text: String, color: Color) -> void:
	if not _provider_proxy_controls_valid():
		return
	var status := _provider_proxy_controls.status as Label
	status.text = text
	status.tooltip_text = text
	status.add_theme_color_override("font_color", color)

func _sync_provider_proxy_controls() -> void:
	if not _provider_proxy_controls_valid():
		return
	(_provider_proxy_controls.save as Button).disabled = (
		_provider_busy or not _provider_proxy_dirty
	)

func _provider_proxy_controls_valid() -> bool:
	return (
		not _provider_proxy_controls.is_empty()
		and is_instance_valid(_provider_proxy_controls.get("mode"))
		and is_instance_valid(_provider_proxy_controls.get("url"))
		and is_instance_valid(_provider_proxy_controls.get("save"))
		and is_instance_valid(_provider_proxy_controls.get("status"))
	)

func _build_knowledge_management_section(data: Dictionary) -> void:
	_provider_rag_controls.clear()
	_content.add_child(_section_label("知识库与检索", data))
	var introduction := Label.new()
	introduction.text = "文档保存在独立 SQLite 中，可按角色隔离；聊天时只注入检索命中的只读片段，不会破坏稳定提示词缓存。"
	introduction.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	introduction.add_theme_font_size_override("font_size", 11)
	introduction.add_theme_color_override("font_color", Color(data.secondary, 0.96))
	_content.add_child(introduction)
	var card := PanelContainer.new()
	card.add_theme_stylebox_override(
		"panel", _style(Color(data.primary, 0.055), Color(data.text, 0.12), 12, 12)
	)
	_content.add_child(card)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 9)
	card.add_child(column)
	_build_rag_editor(column, data)
	_refresh_rag_library.call_deferred()

func _build_capability_provider_editor(
	parent: VBoxContainer,
	capability: String,
	data: Dictionary,
	include_fallback := true
) -> void:
	var definition: Dictionary = CAPABILITY_PROVIDER_UI[capability]
	parent.add_child(HSeparator.new())
	var heading := HBoxContainer.new()
	heading.add_theme_constant_override("separation", 8)
	parent.add_child(heading)
	var title := Label.new()
	title.text = str(definition.label)
	title.add_theme_font_size_override("font_size", 13)
	title.add_theme_color_override("font_color", Color(data.primary))
	heading.add_child(title)
	var description := Label.new()
	description.text = str(definition.description)
	description.add_theme_font_size_override("font_size", 10)
	description.add_theme_color_override("font_color", Color(data.secondary, 0.96))
	heading.add_child(description)
	var heading_spacer := Control.new()
	heading_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(heading_spacer)

	var loaded := _capability_loaded_or_default(capability)
	var enabled := CheckBox.new()
	enabled.text = "启用"
	enabled.button_pressed = bool(loaded.get("enabled", false))
	heading.add_child(enabled)
	var inherit_key := CheckBox.new()
	inherit_key.text = "复用聊天 Key"
	inherit_key.button_pressed = bool(loaded.get("inherit_chat_key", capability in ["vision", "embedding"]))
	heading.add_child(inherit_key)
	var allow_insecure_http := CheckBox.new()
	allow_insecure_http.text = "允许 HTTP"
	allow_insecure_http.tooltip_text = "仅在中转站没有 HTTPS 时启用。公网 HTTP 会以明文发送 API Key、图片和模型回复；局域网私有 IP 无需勾选。"
	allow_insecure_http.button_pressed = bool(loaded.get("allow_insecure_http", false))
	heading.add_child(allow_insecure_http)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 6)
	parent.add_child(grid)
	var base_input := _provider_labeled_line_edit(
		grid, "Base URL", str(loaded.get("base_url", definition.base_url)), str(definition.base_url)
	)
	base_input.tooltip_text = "HTTPS 最安全；局域网私有 IP 可使用 HTTP。公网 HTTP 需要勾选“允许 HTTP”。"
	var model_input := _provider_labeled_line_edit(
		grid, "模型名称", str(loaded.get("model", definition.model)), str(definition.model)
	)
	var protocol_label := Label.new()
	protocol_label.text = "接口协议"
	grid.add_child(protocol_label)
	var protocol_select := OptionButton.new()
	protocol_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var protocols: Dictionary = definition.protocols
	var selected_protocol := 0
	for protocol_variant in protocols:
		var protocol := str(protocol_variant)
		var index := protocol_select.item_count
		protocol_select.add_item(str(protocols[protocol_variant]))
		protocol_select.set_item_metadata(index, protocol)
		if protocol == str(loaded.get("protocol", "")):
			selected_protocol = index
	protocol_select.select(selected_protocol)
	grid.add_child(protocol_select)
	var ling_voice_input: LineEdit = null
	var nai_voice_input: LineEdit = null
	if capability == "tts":
		var saved_voices := _saved_tts_voices()
		ling_voice_input = _provider_labeled_line_edit(
			grid, "Voice ID (Ling)", str(saved_voices.get("ling", "")), "default voice or profile ID"
		)
		nai_voice_input = _provider_labeled_line_edit(
			grid, "Voice ID (Nai)", str(saved_voices.get("nai", "")), "default voice or profile ID"
		)
	var key_label := Label.new()
	key_label.text = "独立 API Key"
	grid.add_child(key_label)
	var key_input := LineEdit.new()
	key_input.secret = true
	key_input.placeholder_text = "留空则保留；可选择复用聊天 Key"
	key_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(key_input)

	var command_row := HBoxContainer.new()
	command_row.add_theme_constant_override("separation", 8)
	parent.add_child(command_row)
	var save_button := Button.new()
	save_button.text = "保存%s配置" % str(definition.label)
	save_button.custom_minimum_size = Vector2(138, 32)
	command_row.add_child(save_button)
	var clear_button := Button.new()
	clear_button.text = "清除独立 Key"
	clear_button.custom_minimum_size = Vector2(116, 32)
	command_row.add_child(clear_button)
	var diagnose_button := Button.new()
	diagnose_button.text = "测试连接"
	diagnose_button.tooltip_text = "发送不包含角色设定的最小诊断请求"
	command_row.add_child(diagnose_button)
	var status := Label.new()
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.add_theme_font_size_override("font_size", 10)
	parent.add_child(status)

	_provider_profile_controls[capability] = {
		"base_url": base_input,
		"model": model_input,
		"api_key": key_input,
		"enabled": enabled,
		"inherit_chat_key": inherit_key,
		"allow_insecure_http": allow_insecure_http,
		"protocol": protocol_select,
		"voice_ling": ling_voice_input,
		"voice_nai": nai_voice_input,
		"save": save_button,
		"clear": clear_button,
		"diagnose": diagnose_button,
		"status": status,
	}
	var capability_id := capability
	base_input.text_changed.connect(func(_value: String): _update_provider_profile_dirty(capability_id))
	model_input.text_changed.connect(func(_value: String): _update_provider_profile_dirty(capability_id))
	if is_instance_valid(ling_voice_input):
		ling_voice_input.text_changed.connect(func(_value: String): _update_provider_profile_dirty(capability_id))
	if is_instance_valid(nai_voice_input):
		nai_voice_input.text_changed.connect(func(_value: String): _update_provider_profile_dirty(capability_id))
	key_input.text_changed.connect(func(_value: String): _update_provider_profile_dirty(capability_id))
	enabled.toggled.connect(func(_value: bool): _update_provider_profile_dirty(capability_id))
	inherit_key.toggled.connect(func(_value: bool): _update_provider_profile_dirty(capability_id))
	allow_insecure_http.toggled.connect(func(_value: bool): _update_provider_profile_dirty(capability_id))
	protocol_select.item_selected.connect(func(_index: int): _update_provider_profile_dirty(capability_id))
	save_button.pressed.connect(func(): _save_provider_profile(capability_id))
	clear_button.pressed.connect(func(): _request_clear_provider_profile_key(capability_id))
	diagnose_button.pressed.connect(func(): _diagnose_provider(capability_id))
	_render_provider_profile_status(capability)
	_sync_provider_profile_buttons(capability)
	if include_fallback:
		_build_provider_fallback_editor(parent, capability, data)

func _provider_labeled_line_edit(
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

func _build_provider_fallback_editor(parent: VBoxContainer, capability: String, data: Dictionary) -> void:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	parent.add_child(column)
	var heading := HBoxContainer.new()
	column.add_child(heading)
	var title := Label.new()
	title.text = "故障切换候选链"
	title.add_theme_font_size_override("font_size", 11)
	title.add_theme_color_override("font_color", Color(data.primary))
	heading.add_child(title)
	var hint := Label.new()
	hint.text = "  仅连接失败、429、5xx 或熔断时按顺序尝试；鉴权与参数错误不会切换。"
	hint.add_theme_font_size_override("font_size", 9)
	hint.add_theme_color_override("font_color", Color(data.secondary, 0.96))
	heading.add_child(hint)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(spacer)
	var add_button := Button.new()
	add_button.text = "＋ 添加备用项"
	heading.add_child(add_button)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 6)
	column.add_child(rows)
	var command_row := HBoxContainer.new()
	column.add_child(command_row)
	var save_button := Button.new()
	save_button.text = "保存候选链"
	command_row.add_child(save_button)
	var status := Label.new()
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	status.add_theme_font_size_override("font_size", 9)
	command_row.add_child(status)
	_provider_fallback_controls[capability] = {
		"rows": rows, "add": add_button, "save": save_button, "status": status,
	}
	if not _provider_fallback_drafts.has(capability):
		_provider_fallback_drafts[capability] = _provider_fallback_loaded.get(capability, []).duplicate(true)
	add_button.pressed.connect(func(): _add_provider_fallback_candidate(capability))
	save_button.pressed.connect(func(): _save_provider_fallbacks(capability))
	_rebuild_provider_fallback_rows(capability)

func _add_provider_fallback_candidate(capability: String) -> void:
	var draft: Array = _provider_fallback_drafts.get(capability, []).duplicate(true)
	if draft.size() >= 6:
		_set_provider_fallback_status(capability, "每类能力最多 6 个备用项", Color("#D9A441"))
		return
	var index := draft.size() + 1
	var default_profile := _provider_loaded_values if capability == "chat" else _capability_loaded_or_default(capability)
	draft.append({
		"id": "fallback_%d" % Time.get_ticks_msec(),
		"label": "备用 %d" % index,
		"base_url": str(default_profile.get("base_url", "")),
		"model": str(default_profile.get("model", "")),
		"enabled": true,
		"protocol": "openai_chat" if capability == "chat" else str(default_profile.get("protocol", "")),
		"inherit_chat_key": true,
		"allow_insecure_http": false,
	})
	_provider_fallback_drafts[capability] = draft
	_provider_fallback_dirty[capability] = true
	_rebuild_provider_fallback_rows(capability)

func _rebuild_provider_fallback_rows(capability: String) -> void:
	var controls = _provider_fallback_controls.get(capability, {})
	if not controls is Dictionary or not is_instance_valid((controls as Dictionary).get("rows")):
		return
	var rows := (controls as Dictionary).rows as VBoxContainer
	for child in rows.get_children():
		child.queue_free()
	var draft: Array = _provider_fallback_drafts.get(capability, [])
	if draft.is_empty():
		var empty := Label.new()
		empty.text = "尚未配置备用模型；主模型故障时会直接返回错误。"
		empty.add_theme_font_size_override("font_size", 9)
		rows.add_child(empty)
	else:
		for index in draft.size():
			_build_provider_fallback_row(rows, capability, index, draft[index] as Dictionary)
	_render_provider_fallback_status(capability)

func _build_provider_fallback_row(parent: VBoxContainer, capability: String, index: int, candidate: Dictionary) -> void:
	var box := VBoxContainer.new()
	parent.add_child(box)
	var first := HBoxContainer.new()
	box.add_child(first)
	var priority := Label.new()
	priority.text = "#%d" % (index + 1)
	priority.custom_minimum_size.x = 28
	first.add_child(priority)
	var label_input := LineEdit.new()
	label_input.text = str(candidate.get("label", "备用 %d" % (index + 1)))
	label_input.placeholder_text = "显示名称"
	label_input.custom_minimum_size.x = 112
	first.add_child(label_input)
	var base_input := LineEdit.new()
	base_input.text = str(candidate.get("base_url", ""))
	base_input.placeholder_text = "Base URL"
	base_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	first.add_child(base_input)
	var model_input := LineEdit.new()
	model_input.text = str(candidate.get("model", ""))
	model_input.placeholder_text = "模型名称"
	model_input.custom_minimum_size.x = 156
	first.add_child(model_input)
	var move_up := Button.new()
	move_up.text = "▲"
	move_up.tooltip_text = "提高备用优先级"
	move_up.disabled = index == 0
	first.add_child(move_up)
	var move_down := Button.new()
	move_down.text = "▼"
	move_down.tooltip_text = "降低备用优先级"
	move_down.disabled = index >= (_provider_fallback_drafts.get(capability, []) as Array).size() - 1
	first.add_child(move_down)
	var remove := Button.new()
	remove.text = "🗑"
	remove.tooltip_text = "移除此备用项"
	first.add_child(remove)
	var second := HBoxContainer.new()
	box.add_child(second)
	var enabled := CheckBox.new()
	enabled.text = "启用"
	enabled.button_pressed = bool(candidate.get("enabled", true))
	second.add_child(enabled)
	var inherit_key := CheckBox.new()
	inherit_key.text = "复用主项 Key"
	inherit_key.button_pressed = bool(candidate.get("inherit_chat_key", true))
	second.add_child(inherit_key)
	var allow_http := CheckBox.new()
	allow_http.text = "允许 HTTP"
	allow_http.button_pressed = bool(candidate.get("allow_insecure_http", false))
	second.add_child(allow_http)
	var protocol := OptionButton.new()
	var protocols: Dictionary = {"openai_chat": "OpenAI Chat"} if capability == "chat" else (CAPABILITY_PROVIDER_UI[capability] as Dictionary).protocols
	for key in protocols:
		var protocol_index := protocol.item_count
		protocol.add_item(str(protocols[key]))
		protocol.set_item_metadata(protocol_index, str(key))
		if str(key) == str(candidate.get("protocol", "")):
			protocol.select(protocol_index)
	second.add_child(protocol)
	var key_input := LineEdit.new()
	key_input.secret = true
	key_input.placeholder_text = "独立 Key（留空保持）"
	key_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	second.add_child(key_input)
	var key_state := Label.new()
	if bool(candidate.get("inherit_chat_key", true)):
		key_state.text = "Key：主项" + ("（另存）" if bool(candidate.get("saved_api_key_configured", false)) else "")
	elif bool(candidate.get("saved_api_key_configured", false)):
		key_state.text = "Key：已加密"
	else:
		key_state.text = "Key：未配置"
	key_state.add_theme_font_size_override("font_size", 9)
	second.add_child(key_state)
	var clear_key := Button.new()
	clear_key.text = "清除 Key"
	clear_key.disabled = not bool(candidate.get("saved_api_key_configured", false))
	second.add_child(clear_key)
	var candidate_id := str(candidate.get("id", "fallback_%d" % (index + 1)))
	for control in [label_input, base_input, model_input]:
		(control as LineEdit).text_changed.connect(func(_value: String):
			_update_provider_fallback_candidate(capability, candidate_id, label_input, base_input, model_input, protocol, enabled, inherit_key, allow_http, key_input)
		)
	key_input.text_changed.connect(func(value: String):
		if not value.strip_edges().is_empty():
			inherit_key.set_pressed_no_signal(false)
		_update_provider_fallback_candidate(capability, candidate_id, label_input, base_input, model_input, protocol, enabled, inherit_key, allow_http, key_input)
	)
	for toggle in [enabled, inherit_key, allow_http]:
		(toggle as CheckBox).toggled.connect(func(_value: bool):
			_update_provider_fallback_candidate(capability, candidate_id, label_input, base_input, model_input, protocol, enabled, inherit_key, allow_http, key_input)
		)
	protocol.item_selected.connect(func(_value: int):
		_update_provider_fallback_candidate(capability, candidate_id, label_input, base_input, model_input, protocol, enabled, inherit_key, allow_http, key_input)
	)
	move_up.pressed.connect(func(): call_deferred("_move_provider_fallback_candidate", capability, candidate_id, -1))
	move_down.pressed.connect(func(): call_deferred("_move_provider_fallback_candidate", capability, candidate_id, 1))
	clear_key.pressed.connect(func(): call_deferred("_clear_provider_fallback_candidate_key", capability, candidate_id))
	remove.pressed.connect(func(): call_deferred("_remove_provider_fallback_candidate", capability, candidate_id))
	_apply_settings_content_readability(box, ThemeMgr.get_current_theme_data())

func _update_provider_fallback_candidate(capability: String, candidate_id: String, label_input: LineEdit, base_input: LineEdit, model_input: LineEdit, protocol: OptionButton, enabled: CheckBox, inherit_key: CheckBox, allow_http: CheckBox, key_input: LineEdit) -> void:
	var draft: Array = _provider_fallback_drafts.get(capability, []).duplicate(true)
	for index in draft.size():
		if str((draft[index] as Dictionary).get("id", "")) != candidate_id:
			continue
		var updated: Dictionary = (draft[index] as Dictionary).duplicate(true)
		updated["label"] = label_input.text.strip_edges()
		updated["base_url"] = base_input.text.strip_edges()
		updated["model"] = model_input.text.strip_edges()
		updated["protocol"] = str(protocol.get_item_metadata(protocol.selected))
		updated["enabled"] = enabled.button_pressed
		updated["inherit_chat_key"] = inherit_key.button_pressed
		updated["allow_insecure_http"] = allow_http.button_pressed
		if not key_input.text.strip_edges().is_empty():
			updated["api_key"] = key_input.text.strip_edges()
			updated.erase("clear_api_key")
		draft[index] = updated
		break
	_provider_fallback_drafts[capability] = draft
	_provider_fallback_dirty[capability] = true
	_render_provider_fallback_status(capability)

func _move_provider_fallback_candidate(capability: String, candidate_id: String, offset: int) -> void:
	var draft: Array = _provider_fallback_drafts.get(capability, []).duplicate(true)
	for index in draft.size():
		if str((draft[index] as Dictionary).get("id", "")) != candidate_id:
			continue
		var target := clampi(index + offset, 0, draft.size() - 1)
		if target != index:
			var value = draft[index]
			draft[index] = draft[target]
			draft[target] = value
			_provider_fallback_drafts[capability] = draft
			_provider_fallback_dirty[capability] = true
			_rebuild_provider_fallback_rows(capability)
		return

func _clear_provider_fallback_candidate_key(capability: String, candidate_id: String) -> void:
	var draft: Array = _provider_fallback_drafts.get(capability, []).duplicate(true)
	for index in draft.size():
		if str((draft[index] as Dictionary).get("id", "")) == candidate_id:
			var updated: Dictionary = (draft[index] as Dictionary).duplicate(true)
			updated["clear_api_key"] = true
			updated.erase("api_key")
			updated["saved_api_key_configured"] = false
			draft[index] = updated
			break
	_provider_fallback_drafts[capability] = draft
	_provider_fallback_dirty[capability] = true
	_rebuild_provider_fallback_rows(capability)

func _remove_provider_fallback_candidate(capability: String, candidate_id: String) -> void:
	var draft: Array = _provider_fallback_drafts.get(capability, []).duplicate(true)
	for index in range(draft.size() - 1, -1, -1):
		if str((draft[index] as Dictionary).get("id", "")) == candidate_id:
			draft.remove_at(index)
	_provider_fallback_drafts[capability] = draft
	_provider_fallback_dirty[capability] = true
	_rebuild_provider_fallback_rows(capability)

func _save_provider_fallbacks(capability: String) -> void:
	if _provider_busy:
		return
	_provider_busy = true
	_provider_write_in_flight = true
	_set_provider_fallback_status(capability, "正在安全保存候选链…", Color(ThemeMgr.get_current_theme_data().primary))
	var result: Dictionary = await CompanionCore.configure_provider_fallbacks(capability, _provider_fallback_drafts.get(capability, []))
	_provider_busy = false
	_provider_write_in_flight = false
	if not bool(result.get("ok", false)):
		_set_provider_fallback_status(capability, "保存失败：%s" % _localized_provider_error(str(result.get("message", "配置无效"))), Color("#D9534F"))
		return
	var data = result.get("data", {})
	var candidates = (data as Dictionary).get("candidates", []) if data is Dictionary else []
	_provider_fallback_loaded[capability] = candidates.duplicate(true) if candidates is Array else []
	_provider_fallback_drafts[capability] = _provider_fallback_loaded[capability].duplicate(true)
	_provider_fallback_dirty[capability] = false
	_rebuild_provider_fallback_rows(capability)
	_render_provider_fallback_status(capability, "已保存并立即生效")

func _render_provider_fallback_status(capability: String, prefix := "") -> void:
	var text := prefix
	var color := Color("#4CAF7D")
	if bool(_provider_fallback_dirty.get(capability, false)):
		text = "有未保存的候选链修改"
		color = Color("#D9A441")
	elif text.is_empty():
		var runtime = (_provider_status_data.get("runtime", {}) as Dictionary).get("circuits", {}) if _provider_status_data.get("runtime", {}) is Dictionary else {}
		var state = (runtime as Dictionary).get(capability, {}) if runtime is Dictionary else {}
		var count := (_provider_fallback_loaded.get(capability, []) as Array).size() if _provider_fallback_loaded.get(capability, []) is Array else 0
		text = "%d 个备用项" % count
		if state is Dictionary and int((state as Dictionary).get("switch_count", 0)) > 0:
			text += " · 当前 %s · 已切换 %d 次 · %s" % [str((state as Dictionary).get("active_label", "Primary")), int((state as Dictionary).get("switch_count", 0)), str((state as Dictionary).get("last_switch_reason", ""))]
	_set_provider_fallback_status(capability, text, color)

func _set_provider_fallback_status(capability: String, text: String, color: Color) -> void:
	var controls = _provider_fallback_controls.get(capability, {})
	if controls is Dictionary and is_instance_valid((controls as Dictionary).get("status")):
		var status := (controls as Dictionary).status as Label
		status.text = text
		status.tooltip_text = text
		status.add_theme_color_override("font_color", color)
		((controls as Dictionary).save as Button).disabled = _provider_busy or not bool(_provider_fallback_dirty.get(capability, false))

func _build_rag_editor(parent: VBoxContainer, data: Dictionary) -> void:
	var page_stack := parent
	var retrieval_page := VBoxContainer.new()
	retrieval_page.add_theme_constant_override("separation", 9)
	page_stack.add_child(retrieval_page)
	var documents_page := VBoxContainer.new()
	documents_page.add_theme_constant_override("separation", 9)
	page_stack.add_child(documents_page)
	var editor_page := VBoxContainer.new()
	editor_page.add_theme_constant_override("separation", 9)
	page_stack.add_child(editor_page)
	var test_page := VBoxContainer.new()
	test_page.add_theme_constant_override("separation", 9)
	page_stack.add_child(test_page)
	var pages := {
		"retrieval": retrieval_page,
		"documents": documents_page,
		"editor": editor_page,
		"test": test_page,
	}
	parent = retrieval_page
	parent.add_child(HSeparator.new())
	var title := Label.new()
	title.text = "本地 RAG 知识库"
	title.add_theme_font_size_override("font_size", 13)
	title.add_theme_color_override("font_color", Color(data.primary))
	parent.add_child(title)
	var note := Label.new()
	note.text = "知识文档保存在独立 SQLite 中；语义嵌入和重排序均可选，关闭后仍可使用本地关键词召回。"
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 10)
	note.add_theme_color_override("font_color", Color(data.secondary, 0.96))
	parent.add_child(note)
	_rag_library_status = Label.new()
	_rag_library_status.text = "正在读取知识库状态…"
	_rag_library_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_rag_library_status.add_theme_font_size_override("font_size", 11)
	_rag_library_status.add_theme_color_override("font_color", Color(data.secondary, 0.96))
	parent.add_child(_rag_library_status)
	var loaded := _rag_loaded_or_default()
	var toggles := HBoxContainer.new()
	toggles.add_theme_constant_override("separation", 12)
	parent.add_child(toggles)
	var enabled := CheckBox.new()
	enabled.text = "启用 RAG"
	enabled.button_pressed = bool(loaded.get("enabled", false))
	toggles.add_child(enabled)
	var embeddings := CheckBox.new()
	embeddings.text = "使用语义嵌入"
	embeddings.button_pressed = bool(loaded.get("use_embeddings", true))
	toggles.add_child(embeddings)
	var rerank := CheckBox.new()
	rerank.text = "使用重排序"
	rerank.button_pressed = bool(loaded.get("use_rerank", false))
	toggles.add_child(rerank)

	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 6)
	parent.add_child(grid)
	var top_k := _rag_spin(grid, "注入片段数", loaded.get("top_k", 6), 1, 20)
	var candidates := _rag_spin(grid, "候选片段数", loaded.get("candidate_limit", 24), 4, 100)
	var chunk_size := _rag_spin(grid, "分块字符数", loaded.get("chunk_size", 900), 200, 4000)
	var overlap := _rag_spin(grid, "重叠字符数", loaded.get("chunk_overlap", 120), 0, 1000)
	var command_row := HBoxContainer.new()
	command_row.add_theme_constant_override("separation", 8)
	parent.add_child(command_row)
	var save := Button.new()
	save.text = "保存 RAG 配置"
	save.custom_minimum_size = Vector2(132, 32)
	command_row.add_child(save)
	var status := Label.new()
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	status.add_theme_font_size_override("font_size", 10)
	command_row.add_child(status)
	_provider_rag_controls = {
		"enabled": enabled,
		"use_embeddings": embeddings,
		"use_rerank": rerank,
		"top_k": top_k,
		"candidate_limit": candidates,
		"chunk_size": chunk_size,
		"chunk_overlap": overlap,
		"save": save,
		"status": status,
	}
	for toggle in [enabled, embeddings, rerank]:
		toggle.toggled.connect(func(_value: bool): _update_provider_rag_dirty())
	for spin in [top_k, candidates, chunk_size, overlap]:
		spin.value_changed.connect(func(_value: float): _update_provider_rag_dirty())
	save.pressed.connect(_save_provider_rag)
	_render_provider_rag_status()
	_sync_provider_rag_button()

	parent = documents_page
	parent.add_child(HSeparator.new())
	var library_heading := HBoxContainer.new()
	library_heading.add_theme_constant_override("separation", 8)
	parent.add_child(library_heading)
	var library_title := Label.new()
	library_title.text = "文档管理"
	library_title.add_theme_font_size_override("font_size", 13)
	library_title.add_theme_color_override("font_color", Color(data.primary))
	library_heading.add_child(library_title)
	var library_spacer := Control.new()
	library_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	library_heading.add_child(library_spacer)
	var refresh_button := Button.new()
	refresh_button.text = "↻ 刷新"
	refresh_button.pressed.connect(_refresh_rag_library)
	library_heading.add_child(refresh_button)
	var reindex_button := Button.new()
	reindex_button.text = "重新向量化"
	reindex_button.tooltip_text = "使用当前嵌入模型重新生成全部知识分块的向量"
	reindex_button.pressed.connect(_reindex_rag_library)
	library_heading.add_child(reindex_button)
	var import_scope_label := Label.new()
	import_scope_label.text = "导入到"
	import_scope_label.add_theme_font_size_override("font_size", 10)
	library_heading.add_child(import_scope_label)
	_rag_import_scope = _create_rag_scope_select()
	_rag_import_scope.tooltip_text = "同时用于批量文件和网页导入的角色作用域"
	_rag_import_scope.item_selected.connect(func(_index: int):
		_select_rag_scope_filter(_selected_rag_import_scope())
	)
	library_heading.add_child(_rag_import_scope)
	var file_button := Button.new()
	file_button.text = "📄 导入文件"
	file_button.tooltip_text = "支持 TXT、Markdown、JSON、CSV、HTML、DOCX 和 PDF；使用左侧选择的导入作用域"
	file_button.pressed.connect(func(): _rag_file_dialog.popup_centered_ratio(0.72))
	library_heading.add_child(file_button)

	var web_row := HBoxContainer.new()
	web_row.add_theme_constant_override("separation", 8)
	parent.add_child(web_row)
	_rag_url_input = LineEdit.new()
	_rag_url_input.placeholder_text = "https://example.com/knowledge（远程网页必须使用 HTTPS）"
	_rag_url_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	web_row.add_child(_rag_url_input)
	var web_button := Button.new()
	web_button.text = "导入网页"
	web_button.pressed.connect(_import_rag_web_url)
	web_row.add_child(web_button)

	var filter_row := HBoxContainer.new()
	filter_row.add_theme_constant_override("separation", 8)
	parent.add_child(filter_row)
	_rag_document_filter = LineEdit.new()
	_rag_document_filter.placeholder_text = "按标题、来源或作用域筛选文档…"
	_rag_document_filter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rag_document_filter.text_changed.connect(func(_value: String): _render_rag_document_list())
	filter_row.add_child(_rag_document_filter)
	_rag_scope_filter = OptionButton.new()
	_rag_scope_filter.custom_minimum_size = Vector2(150, 34)
	for option in [
		{"label": "全部作用域", "value": "all"},
		{"label": "共享 (*)", "value": "*"},
		{"label": "小玲 (ling)", "value": "ling"},
		{"label": "小奈 (nai)", "value": "nai"},
	]:
		var index := _rag_scope_filter.item_count
		_rag_scope_filter.add_item(str(option.label))
		_rag_scope_filter.set_item_metadata(index, str(option.value))
	_rag_scope_filter.item_selected.connect(func(_index: int): _render_rag_document_list())
	filter_row.add_child(_rag_scope_filter)
	var new_button := Button.new()
	new_button.text = "＋ 新建文档"
	new_button.pressed.connect(_new_rag_document)
	filter_row.add_child(new_button)

	var batch_row := HBoxContainer.new()
	batch_row.add_theme_constant_override("separation", 8)
	parent.add_child(batch_row)
	var select_all_button := Button.new()
	select_all_button.text = "全选筛选结果"
	select_all_button.pressed.connect(_select_all_visible_rag_documents)
	batch_row.add_child(select_all_button)
	var clear_selection_button := Button.new()
	clear_selection_button.text = "清空选择"
	clear_selection_button.pressed.connect(_clear_rag_document_selection)
	batch_row.add_child(clear_selection_button)
	var selection_status := Label.new()
	selection_status.custom_minimum_size = Vector2(72, 0)
	selection_status.add_theme_font_size_override("font_size", 10)
	batch_row.add_child(selection_status)
	var batch_spacer := Control.new()
	batch_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	batch_row.add_child(batch_spacer)
	_rag_batch_scope = _create_rag_scope_select()
	_rag_batch_scope.tooltip_text = "将所选文档统一修改到这个作用域"
	batch_row.add_child(_rag_batch_scope)
	var scope_button := Button.new()
	scope_button.text = "修改作用域"
	scope_button.pressed.connect(_batch_update_rag_scope)
	batch_row.add_child(scope_button)
	var rechunk_button := Button.new()
	rechunk_button.text = "重新分块"
	rechunk_button.tooltip_text = "按当前 RAG 参数和 Markdown 章节规则重建所选文档分块"
	rechunk_button.pressed.connect(_batch_rechunk_rag_documents)
	batch_row.add_child(rechunk_button)
	var delete_selected_button := Button.new()
	delete_selected_button.text = "删除所选"
	delete_selected_button.pressed.connect(_request_delete_selected_rag_documents)
	batch_row.add_child(delete_selected_button)
	_rag_batch_controls = {
		"select_all": select_all_button,
		"clear": clear_selection_button,
		"status": selection_status,
		"scope": scope_button,
		"rechunk": rechunk_button,
		"delete": delete_selected_button,
	}

	var list_panel := PanelContainer.new()
	list_panel.custom_minimum_size = Vector2(0, 118)
	list_panel.add_theme_stylebox_override(
		"panel", _style(Color(data.bg, 0.34), Color(data.text, 0.09), 9, 7)
	)
	parent.add_child(list_panel)
	_rag_document_list = VBoxContainer.new()
	_rag_document_list.add_theme_constant_override("separation", 4)
	list_panel.add_child(_rag_document_list)

	parent = editor_page
	parent.add_child(HSeparator.new())
	var import_title := Label.new()
	import_title.text = "新建或编辑文档"
	import_title.add_theme_font_size_override("font_size", 11)
	parent.add_child(import_title)
	var metadata_row := HBoxContainer.new()
	metadata_row.add_theme_constant_override("separation", 8)
	parent.add_child(metadata_row)
	_rag_document_title = LineEdit.new()
	_rag_document_title.placeholder_text = "文档标题"
	_rag_document_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rag_document_title.text_changed.connect(func(_value: String): _mark_rag_document_dirty())
	metadata_row.add_child(_rag_document_title)
	_rag_document_scope = _create_rag_scope_select()
	_rag_document_scope.item_selected.connect(func(_index: int): _mark_rag_document_dirty())
	metadata_row.add_child(_rag_document_scope)
	_rag_document_source = LineEdit.new()
	_rag_document_source.placeholder_text = "来源 URL 或备注（可选）"
	_rag_document_source.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rag_document_source.text_changed.connect(func(_value: String): _mark_rag_document_dirty())
	metadata_row.add_child(_rag_document_source)
	_rag_document_text = TextEdit.new()
	_rag_document_text.placeholder_text = "粘贴设定、世界观、说明书或其他需要检索的知识文本……"
	_rag_document_text.custom_minimum_size = Vector2(0, 132)
	_rag_document_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_rag_document_text.text_changed.connect(_mark_rag_document_dirty)
	parent.add_child(_rag_document_text)
	var import_row := HBoxContainer.new()
	parent.add_child(import_row)
	var import_button := Button.new()
	import_button.text = "保存并生成检索分块"
	import_button.custom_minimum_size = Vector2(154, 32)
	import_button.pressed.connect(_import_rag_document)
	import_row.add_child(import_button)
	var delete_button := Button.new()
	delete_button.text = "删除当前文档"
	delete_button.pressed.connect(_request_delete_current_rag_document)
	import_row.add_child(delete_button)
	_rag_document_status = Label.new()
	_rag_document_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rag_document_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_rag_document_status.add_theme_font_size_override("font_size", 10)
	_rag_document_status.add_theme_color_override("font_color", Color(data.secondary, 0.96))
	import_row.add_child(_rag_document_status)

	parent = test_page
	parent.add_child(HSeparator.new())
	var search_title := Label.new()
	search_title.text = "检索测试"
	search_title.add_theme_font_size_override("font_size", 13)
	search_title.add_theme_color_override("font_color", Color(data.primary))
	parent.add_child(search_title)
	var search_row := HBoxContainer.new()
	search_row.add_theme_constant_override("separation", 8)
	parent.add_child(search_row)
	_rag_search_query = LineEdit.new()
	_rag_search_query.placeholder_text = "输入角色可能提出的问题，验证实际会召回哪些片段…"
	_rag_search_query.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rag_search_query.text_submitted.connect(func(_value: String): _test_rag_search())
	search_row.add_child(_rag_search_query)
	_rag_search_role = _create_rag_scope_select(true)
	search_row.add_child(_rag_search_role)
	var search_button := Button.new()
	search_button.text = "开始检索"
	search_button.pressed.connect(_test_rag_search)
	search_row.add_child(search_button)
	_rag_search_results = VBoxContainer.new()
	_rag_search_results.add_theme_constant_override("separation", 5)
	parent.add_child(_rag_search_results)
	_render_rag_document_list()
	_show_settings_page(pages)

func _rag_spin(
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

func _create_rag_scope_select(for_search: bool = false) -> OptionButton:
	var select := OptionButton.new()
	if for_search:
		select.add_item("以小玲身份检索")
		select.set_item_metadata(0, "ling")
		select.add_item("以小奈身份检索")
		select.set_item_metadata(1, "nai")
	else:
		select.add_item("两位角色共享")
		select.set_item_metadata(0, "*")
		select.add_item("仅小玲")
		select.set_item_metadata(1, "ling")
		select.add_item("仅小奈")
		select.set_item_metadata(2, "nai")
	select.custom_minimum_size = Vector2(144, 34)
	return select

func _refresh_rag_library() -> void:
	if _rag_operation_busy or _settings_category != "knowledge":
		return
	_rag_operation_busy = true
	_set_rag_library_message("正在读取知识库…", Color(ThemeMgr.get_current_theme_data().secondary, 0.96))
	var status_result: Dictionary = await CompanionCore.get_rag_status()
	var documents_result: Dictionary = await CompanionCore.list_rag_documents(500)
	_rag_operation_busy = false
	if _settings_category != "knowledge":
		return
	if not bool(status_result.get("ok", false)) or not bool(documents_result.get("ok", false)):
		var message := str(status_result.get("message", documents_result.get("message", "Companion Core 不可用")))
		_set_rag_library_message("读取失败：%s" % message, Color("#D9534F"))
		return
	var status = status_result.get("data", {})
	var document_data = documents_result.get("data", {})
	_rag_documents = (
		(document_data as Dictionary).get("documents", []).duplicate(true)
		if document_data is Dictionary and (document_data as Dictionary).get("documents", []) is Array
		else []
	)
	var available_ids := {}
	for document_variant in _rag_documents:
		if document_variant is Dictionary:
			available_ids[str((document_variant as Dictionary).get("document_id", ""))] = true
	for selected_id_variant in _rag_selected_document_ids.keys():
		if not available_ids.has(str(selected_id_variant)):
			_rag_selected_document_ids.erase(selected_id_variant)
	if status is Dictionary:
		var settings = (status as Dictionary).get("settings", {})
		var modes: Array[String] = ["关键词"]
		if settings is Dictionary and bool((settings as Dictionary).get("use_embeddings", false)):
			modes.append("向量")
		if settings is Dictionary and bool((settings as Dictionary).get("use_rerank", false)):
			modes.append("重排")
		_set_rag_library_message(
			"%d 份文档 · %d 个分块 · %d 个向量 · 检索：%s" % [
				int((status as Dictionary).get("document_count", 0)),
				int((status as Dictionary).get("chunk_count", 0)),
				int((status as Dictionary).get("embedded_chunk_count", 0)),
				" + ".join(modes),
			],
			Color("#4CAF7D")
		)
	_render_rag_document_list()

func _set_rag_library_message(text: String, color: Color) -> void:
	if is_instance_valid(_rag_library_status):
		_rag_library_status.text = text
		_rag_library_status.tooltip_text = text
		_rag_library_status.add_theme_color_override("font_color", color)

func _render_rag_document_list() -> void:
	if not is_instance_valid(_rag_document_list):
		return
	for child in _rag_document_list.get_children():
		child.free()
	var filter_text := _rag_document_filter.text.strip_edges().to_lower() if is_instance_valid(_rag_document_filter) else ""
	var scope_filter := _selected_rag_scope_filter()
	var visible_count := 0
	for document_variant in _rag_documents:
		if not document_variant is Dictionary:
			continue
		var document: Dictionary = document_variant
		var document_scope := str(document.get("scope", "*"))
		if not _rag_document_matches_filters(document, filter_text, scope_filter):
			continue
		visible_count += 1
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 7)
		_rag_document_list.add_child(row)
		var document_id := str(document.get("document_id", ""))
		var selected := CheckBox.new()
		selected.tooltip_text = "选择此文档进行批量操作"
		selected.button_pressed = _rag_selected_document_ids.has(document_id)
		selected.toggled.connect(func(enabled: bool):
			_set_rag_document_selected(document_id, enabled)
		)
		row.add_child(selected)
		var open_button := Button.new()
		open_button.text = ("● " if document_id == _rag_document_id else "") + str(document.get("title", "未命名文档"))
		open_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		open_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		open_button.tooltip_text = str(document.get("source_uri", ""))
		open_button.pressed.connect(func(): _open_rag_document(document_id))
		row.add_child(open_button)
		var scope_label := Label.new()
		scope_label.text = _rag_scope_label(document_scope)
		scope_label.custom_minimum_size = Vector2(118, 0)
		row.add_child(scope_label)
		var detail := Label.new()
		detail.text = "%d 字 · %d 块 · %s" % [
			int(document.get("character_count", 0)),
			int(document.get("chunk_count", 0)),
			_rag_embedding_label(str(document.get("embedding_state", "none"))),
		]
		detail.custom_minimum_size = Vector2(188, 0)
		detail.add_theme_font_size_override("font_size", 10)
		row.add_child(detail)
		var delete_button := Button.new()
		delete_button.text = "🗑"
		delete_button.tooltip_text = "删除此文档"
		delete_button.pressed.connect(func(): _request_delete_rag_document(document_id))
		row.add_child(delete_button)
	if visible_count == 0:
		var empty := Label.new()
		empty.text = "知识库中还没有匹配的文档。可新建、粘贴、批量导入文件或导入网页。"
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.add_theme_color_override("font_color", Color(ThemeMgr.get_current_theme_data().secondary, 0.96))
		_rag_document_list.add_child(empty)
	_sync_rag_batch_controls()

func _rag_document_matches_filters(
	document: Dictionary, filter_text: String, scope_filter: String
) -> bool:
	var document_scope := str(document.get("scope", "*"))
	if scope_filter != "all" and document_scope != scope_filter:
		return false
	var searchable := "%s %s %s" % [
		document.get("title", ""), document.get("source_uri", ""), document_scope
	]
	return filter_text.is_empty() or filter_text in searchable.to_lower()

func _set_rag_document_selected(document_id: String, selected: bool) -> void:
	if selected:
		_rag_selected_document_ids[document_id] = true
	else:
		_rag_selected_document_ids.erase(document_id)
	_sync_rag_batch_controls()

func _selected_rag_document_ids() -> Array:
	return _rag_selected_document_ids.keys()

func _select_all_visible_rag_documents() -> void:
	var filter_text := _rag_document_filter.text.strip_edges().to_lower() if is_instance_valid(_rag_document_filter) else ""
	var scope_filter := _selected_rag_scope_filter()
	for document_variant in _rag_documents:
		if document_variant is Dictionary:
			var document: Dictionary = document_variant
			if _rag_document_matches_filters(document, filter_text, scope_filter):
				_rag_selected_document_ids[str(document.get("document_id", ""))] = true
	_render_rag_document_list()

func _clear_rag_document_selection() -> void:
	_rag_selected_document_ids.clear()
	_render_rag_document_list()

func _sync_rag_batch_controls() -> void:
	if _rag_batch_controls.is_empty():
		return
	var count := _rag_selected_document_ids.size()
	if is_instance_valid(_rag_batch_controls.get("status")):
		(_rag_batch_controls.status as Label).text = "已选 %d" % count
	for key in ["clear", "scope", "rechunk", "delete"]:
		if is_instance_valid(_rag_batch_controls.get(key)):
			(_rag_batch_controls[key] as Button).disabled = _rag_operation_busy or count == 0
	if is_instance_valid(_rag_batch_controls.get("select_all")):
		(_rag_batch_controls.select_all as Button).disabled = _rag_operation_busy

func _batch_update_rag_scope() -> void:
	if not is_instance_valid(_rag_batch_scope):
		return
	var scope := str(_rag_batch_scope.get_item_metadata(_rag_batch_scope.selected))
	_run_rag_batch_action("update_scope", scope)

func _batch_rechunk_rag_documents() -> void:
	_run_rag_batch_action("rechunk")

func _run_rag_batch_action(action: String, scope: String = "") -> void:
	var document_ids := _selected_rag_document_ids()
	if document_ids.is_empty() or _rag_operation_busy:
		return
	_rag_operation_busy = true
	_sync_rag_batch_controls()
	_set_rag_library_message("正在批量处理 %d 份文档…" % document_ids.size(), Color(ThemeMgr.get_current_theme_data().primary))
	var result: Dictionary = await CompanionCore.batch_rag_documents(action, document_ids, scope)
	_rag_operation_busy = false
	if not bool(result.get("ok", false)):
		_set_rag_library_message("批量操作失败：%s" % str(result.get("message", "Core 不可用")), Color("#D9534F"))
		_sync_rag_batch_controls()
		return
	var data = result.get("data", {})
	_set_rag_library_message(
		"批量操作完成 · %d 份文档" % int((data as Dictionary).get("affected_documents", document_ids.size())) if data is Dictionary else "批量操作完成",
		Color("#4CAF7D")
	)
	await _refresh_rag_library()

func _rag_scope_label(scope: String) -> String:
	match scope:
		"ling": return "ling · 小玲"
		"nai": return "nai · 小奈"
		_: return "* · 共享"

func _selected_rag_scope_filter() -> String:
	if not is_instance_valid(_rag_scope_filter):
		return "all"
	return str(_rag_scope_filter.get_item_metadata(_rag_scope_filter.selected))

func _select_rag_scope_filter(scope: String) -> void:
	if not is_instance_valid(_rag_scope_filter):
		return
	for index in _rag_scope_filter.item_count:
		if str(_rag_scope_filter.get_item_metadata(index)) == scope:
			_rag_scope_filter.select(index)
			_render_rag_document_list()
			return

func _rag_embedding_label(state: String) -> String:
	match state:
		"ready": return "已向量化"
		"error": return "向量失败"
		"disabled": return "仅关键词"
		_: return "未向量化"

func _mark_rag_document_dirty() -> void:
	if _provider_suppress_dirty:
		return
	_rag_document_dirty = true
	if is_instance_valid(_rag_document_status):
		_rag_document_status.text = "有未保存的文档修改"
		_rag_document_status.add_theme_color_override("font_color", Color("#D9A441"))

func _new_rag_document() -> void:
	if _rag_document_dirty:
		_set_rag_document_message("请先保存当前修改，或清空正文后再新建", Color("#D9A441"))
		return
	_apply_rag_document_to_editor({})

func _open_rag_document(document_id: String) -> void:
	if _rag_operation_busy:
		return
	if _rag_document_dirty and document_id != _rag_document_id:
		_set_rag_document_message("当前文档有未保存修改，请先保存", Color("#D9A441"))
		return
	_rag_operation_busy = true
	_set_rag_document_message("正在读取文档原文…", Color(ThemeMgr.get_current_theme_data().primary))
	var result: Dictionary = await CompanionCore.get_rag_document(document_id)
	_rag_operation_busy = false
	if not bool(result.get("ok", false)):
		_set_rag_document_message("读取失败：%s" % str(result.get("message", "文档不存在")), Color("#D9534F"))
		return
	var data = result.get("data", {})
	var document = (data as Dictionary).get("document", {}) if data is Dictionary else {}
	if document is Dictionary:
		_apply_rag_document_to_editor(document as Dictionary)
		_render_rag_document_list()

func _apply_rag_document_to_editor(document: Dictionary) -> void:
	if not is_instance_valid(_rag_document_title):
		return
	_provider_suppress_dirty = true
	_rag_document_id = str(document.get("document_id", ""))
	_rag_document_title.text = str(document.get("title", ""))
	_rag_document_text.text = str(document.get("text", ""))
	_rag_document_source.text = str(document.get("source_uri", ""))
	_select_rag_scope(_rag_document_scope, str(document.get("scope", "*")))
	_provider_suppress_dirty = false
	_rag_document_dirty = false
	_set_rag_document_message(
		"已载入，可编辑后覆盖保存" if not _rag_document_id.is_empty() else "新文档尚未保存",
		Color(ThemeMgr.get_current_theme_data().secondary, 0.96)
	)

func _select_rag_scope(select: OptionButton, scope: String) -> void:
	if not is_instance_valid(select):
		return
	for index in select.item_count:
		if str(select.get_item_metadata(index)) == scope:
			select.select(index)
			return

func _set_rag_document_message(text: String, color: Color) -> void:
	if is_instance_valid(_rag_document_status):
		_rag_document_status.text = text
		_rag_document_status.tooltip_text = text
		_rag_document_status.add_theme_color_override("font_color", color)

func _request_delete_current_rag_document() -> void:
	if _rag_document_id.is_empty():
		_set_rag_document_message("当前是尚未保存的新文档", Color("#D9A441"))
		return
	_request_delete_rag_document(_rag_document_id)

func _request_delete_rag_document(document_id: String) -> void:
	if document_id.is_empty() or _rag_operation_busy:
		return
	_rag_pending_delete_ids = [document_id]
	_rag_delete_dialog.dialog_text = "文档与全部检索分块将被永久删除。"
	_rag_delete_dialog.popup_centered(Vector2i(500, 200))

func _request_delete_selected_rag_documents() -> void:
	var selected_ids := _selected_rag_document_ids()
	if selected_ids.is_empty() or _rag_operation_busy:
		return
	_rag_pending_delete_ids.clear()
	for document_id_variant in selected_ids:
		_rag_pending_delete_ids.append(str(document_id_variant))
	_rag_delete_dialog.dialog_text = "将永久删除所选 %d 份文档及其全部检索分块。" % _rag_pending_delete_ids.size()
	_rag_delete_dialog.popup_centered(Vector2i(520, 210))

func _confirm_delete_rag_document() -> void:
	if _rag_pending_delete_ids.is_empty() or _rag_operation_busy:
		return
	var deleting_ids: Array = _rag_pending_delete_ids.duplicate()
	_rag_pending_delete_ids.clear()
	_rag_operation_busy = true
	_sync_rag_batch_controls()
	_set_rag_library_message("正在删除 %d 份文档…" % deleting_ids.size(), Color(ThemeMgr.get_current_theme_data().primary))
	var result: Dictionary = await CompanionCore.batch_rag_documents("delete", deleting_ids)
	_rag_operation_busy = false
	if not bool(result.get("ok", false)):
		_set_rag_library_message("删除失败：%s" % str(result.get("message", "Core 不可用")), Color("#D9534F"))
		return
	if _rag_document_id in deleting_ids:
		_rag_document_dirty = false
		_apply_rag_document_to_editor({})
	for deleting_id_variant in deleting_ids:
		_rag_selected_document_ids.erase(str(deleting_id_variant))
	await _refresh_rag_library()

func _import_rag_files(paths: PackedStringArray) -> void:
	if paths.is_empty() or _rag_operation_busy:
		return
	_rag_operation_busy = true
	var import_scope := _selected_rag_import_scope()
	var imported := 0
	var failures: Array[String] = []
	for path in paths:
		var bytes := FileAccess.get_file_as_bytes(path)
		if bytes.is_empty():
			failures.append("%s：文件为空或无法读取" % path.get_file())
			continue
		_set_rag_library_message("正在导入 %s…" % path.get_file(), Color(ThemeMgr.get_current_theme_data().primary))
		var result: Dictionary = await CompanionCore.import_rag_file(
			path.get_file(), bytes, "", import_scope, path
		)
		if bool(result.get("ok", false)):
			imported += 1
		else:
			failures.append("%s：%s" % [path.get_file(), str(result.get("message", "导入失败"))])
	_rag_operation_busy = false
	if imported > 0:
		_select_rag_scope_filter(import_scope)
	_set_rag_library_message(
		"已导入 %d/%d 份文档%s" % [imported, paths.size(), "；" + "；".join(failures) if not failures.is_empty() else ""],
		Color("#4CAF7D") if failures.is_empty() else Color("#D9A441")
	)
	await _refresh_rag_library()

func _import_rag_web_url() -> void:
	if _rag_operation_busy or not is_instance_valid(_rag_url_input):
		return
	var url := _rag_url_input.text.strip_edges()
	if url.is_empty():
		_set_rag_library_message("请填写要导入的网页 URL", Color("#D9534F"))
		return
	var scope := _selected_rag_import_scope()
	_rag_operation_busy = true
	_set_rag_library_message("正在下载并提取网页正文…", Color(ThemeMgr.get_current_theme_data().primary))
	var result: Dictionary = await CompanionCore.import_rag_url(url, "", scope)
	_rag_operation_busy = false
	if not bool(result.get("ok", false)):
		_set_rag_library_message("网页导入失败：%s" % str(result.get("message", "无法下载网页")), Color("#D9534F"))
		return
	_rag_url_input.text = ""
	_select_rag_scope_filter(scope)
	await _refresh_rag_library()

func _selected_rag_import_scope() -> String:
	if not is_instance_valid(_rag_import_scope):
		return "*"
	return str(
		_rag_import_scope.get_item_metadata(_rag_import_scope.selected)
	)

func _test_rag_search() -> void:
	if _rag_operation_busy or not is_instance_valid(_rag_search_query):
		return
	var query := _rag_search_query.text.strip_edges()
	if query.is_empty():
		_render_rag_search_results([], "请输入检索问题")
		return
	var role_id := str(_rag_search_role.get_item_metadata(_rag_search_role.selected))
	_rag_operation_busy = true
	_render_rag_search_results([], "正在检索…")
	var result: Dictionary = await CompanionCore.search_rag(query, role_id, 8)
	_rag_operation_busy = false
	if not bool(result.get("ok", false)):
		_render_rag_search_results([], "检索失败：%s" % str(result.get("message", "Core 不可用")))
		return
	var data = result.get("data", {})
	var entries = (data as Dictionary).get("entries", []) if data is Dictionary else []
	_render_rag_search_results(entries as Array if entries is Array else [], "没有召回匹配片段")

func _render_rag_search_results(entries: Array, empty_message: String) -> void:
	if not is_instance_valid(_rag_search_results):
		return
	for child in _rag_search_results.get_children():
		child.free()
	if entries.is_empty():
		var empty := Label.new()
		empty.text = empty_message
		empty.add_theme_font_size_override("font_size", 10)
		empty.add_theme_color_override("font_color", Color(ThemeMgr.get_current_theme_data().secondary, 0.96))
		_rag_search_results.add_child(empty)
		return
	for entry_variant in entries:
		if not entry_variant is Dictionary:
			continue
		var entry: Dictionary = entry_variant
		var result_label := Label.new()
		result_label.text = "%.3f · %s · %s\n%s" % [
			float(entry.get("score", 0.0)),
			str(entry.get("title", "未命名文档")),
			_rag_scope_label(str(entry.get("scope", "*"))),
			str(entry.get("content", "")),
		]
		result_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		result_label.add_theme_font_size_override("font_size", 10)
		_rag_search_results.add_child(result_label)

func _reindex_rag_library() -> void:
	if _rag_operation_busy:
		return
	_rag_operation_busy = true
	_set_rag_library_message("正在重新生成全部知识向量…", Color(ThemeMgr.get_current_theme_data().primary))
	var result: Dictionary = await CompanionCore.reindex_rag()
	_rag_operation_busy = false
	if not bool(result.get("ok", false)):
		_set_rag_library_message("重新向量化失败：%s" % str(result.get("message", "请先启用嵌入模型")), Color("#D9534F"))
		return
	var data = result.get("data", {})
	_set_rag_library_message(
		"重新向量化完成 · %d 个分块" % int((data as Dictionary).get("updated_chunks", 0)) if data is Dictionary else "重新向量化完成",
		Color("#4CAF7D")
	)
	await _refresh_rag_library()

func _saved_tts_voices() -> Dictionary:
	if is_instance_valid(Settings) and Settings.has_method("get_tts_voices"):
		return Settings.get_tts_voices()
	return {"ling": "", "nai": ""}

func _capability_loaded_or_default(capability: String) -> Dictionary:
	if _provider_profile_loaded.get(capability, {}) is Dictionary and not (_provider_profile_loaded.get(capability, {}) as Dictionary).is_empty():
		var loaded_profile := (_provider_profile_loaded[capability] as Dictionary).duplicate(true)
		if capability == "tts":
			var saved_voices := _saved_tts_voices()
			loaded_profile["voice_ling"] = str(saved_voices.get("ling", ""))
			loaded_profile["voice_nai"] = str(saved_voices.get("nai", ""))
		return loaded_profile
	var definition: Dictionary = CAPABILITY_PROVIDER_UI[capability]
	var protocols: Dictionary = definition.protocols
	return {
		"base_url": str(definition.base_url),
		"model": str(definition.model),
		"enabled": false,
		"protocol": str(protocols.keys()[0]),
		"inherit_chat_key": capability in ["vision", "embedding"],
		"allow_insecure_http": false,
		"saved_api_key_configured": false,
		"credential_source": "none",
		"voice_ling": _saved_tts_voices().get("ling", "") if capability == "tts" else "",
		"voice_nai": _saved_tts_voices().get("nai", "") if capability == "tts" else "",
	}

func _rag_loaded_or_default() -> Dictionary:
	if not _provider_rag_loaded.is_empty():
		return _provider_rag_loaded.duplicate(true)
	return {
		"enabled": false,
		"use_embeddings": true,
		"use_rerank": false,
		"top_k": 6,
		"candidate_limit": 24,
		"chunk_size": 900,
		"chunk_overlap": 120,
	}

func _collect_provider_profile_values(capability: String) -> Dictionary:
	var controls = _provider_profile_controls.get(capability, {})
	if not controls is Dictionary or (controls as Dictionary).is_empty():
		return {}
	var protocol_select := (controls as Dictionary).protocol as OptionButton
	return {
		"base_url": ((controls as Dictionary).base_url as LineEdit).text.strip_edges(),
		"model": ((controls as Dictionary).model as LineEdit).text.strip_edges(),
		"api_key": ((controls as Dictionary).api_key as LineEdit).text,
		"enabled": ((controls as Dictionary).enabled as CheckBox).button_pressed,
		"inherit_chat_key": ((controls as Dictionary).inherit_chat_key as CheckBox).button_pressed,
		"allow_insecure_http": ((controls as Dictionary).allow_insecure_http as CheckBox).button_pressed,
		"protocol": str(protocol_select.get_item_metadata(protocol_select.selected)),
		"voice_ling": ((controls as Dictionary).voice_ling as LineEdit).text.strip_edges() if is_instance_valid((controls as Dictionary).get("voice_ling")) else "",
		"voice_nai": ((controls as Dictionary).voice_nai as LineEdit).text.strip_edges() if is_instance_valid((controls as Dictionary).get("voice_nai")) else "",
	}

func _update_provider_profile_dirty(capability: String) -> void:
	if _provider_suppress_dirty:
		return
	var current := _collect_provider_profile_values(capability)
	var loaded := _capability_loaded_or_default(capability)
	var dirty := not str(current.get("api_key", "")).strip_edges().is_empty()
	for key in ["base_url", "model", "enabled", "inherit_chat_key", "allow_insecure_http", "protocol", "voice_ling", "voice_nai"]:
		if current.get(key) != loaded.get(key):
			dirty = true
	_provider_profile_dirty[capability] = dirty
	_render_provider_profile_status(capability)
	_sync_provider_profile_buttons(capability)

func _save_provider_profile(capability: String) -> void:
	if _provider_busy:
		return
	var current := _collect_provider_profile_values(capability)
	_provider_busy = true
	_provider_write_in_flight = true
	_set_provider_profile_status(capability, "正在安全保存…", Color(ThemeMgr.get_current_theme_data().primary))
	_sync_provider_profile_buttons(capability)
	var result: Dictionary = await CompanionCore.configure_provider_profile(
		capability,
		str(current.get("base_url", "")),
		str(current.get("model", "")),
		str(current.get("protocol", "")),
		bool(current.get("enabled", false)),
		bool(current.get("inherit_chat_key", false)),
		bool(current.get("allow_insecure_http", false)),
		str(current.get("api_key", "")),
		false
	)
	_provider_busy = false
	_provider_write_in_flight = false
	if not bool(result.get("ok", false)):
		var raw_message := str(result.get("message", "配置无效"))
		if _is_provider_insecure_http_error(raw_message):
			_request_provider_insecure_http_confirmation(capability)
			return
		_set_provider_profile_status(
			capability,
			"保存失败：%s" % _localized_provider_error(raw_message),
			Color("#D9534F")
		)
		_sync_provider_profile_buttons(capability)
		return
	var profile_data = result.get("data", {})
	var tts_settings_saved := true
	if capability == "tts" and is_instance_valid(Settings) and Settings.has_method("set_tts_voices"):
		tts_settings_saved = Settings.set_tts_voices({
			"ling": str(current.get("voice_ling", "")),
			"nai": str(current.get("voice_nai", "")),
		})
		if tts_settings_saved and is_instance_valid(Multimodal) and Multimodal.has_method("set_tts_voices"):
			Multimodal.set_tts_voices({
				"ling": str(current.get("voice_ling", "")),
				"nai": str(current.get("voice_nai", "")),
			})
	if not tts_settings_saved:
		_provider_profile_dirty[capability] = true
		_set_provider_profile_status(capability, "TTS voice settings could not be saved", Color("#D9534F"))
		_sync_provider_profile_buttons(capability)
		return
	if profile_data is Dictionary:
		_provider_profile_loaded[capability] = (profile_data as Dictionary).duplicate(true)
		_apply_provider_profile_values_to_controls(capability, profile_data as Dictionary)
	_provider_profile_dirty[capability] = false
	var cached := CompanionCore.get_cached_provider_status()
	if not cached.is_empty():
		_provider_status_data = cached
	_render_provider_profile_status(capability, "已保存并立即生效")
	_sync_provider_profile_buttons(capability)

func _is_provider_insecure_http_error(message: String) -> bool:
	var normalized := message.to_lower()
	return "allow_insecure_http" in normalized or "remote http provider" in normalized

func _localized_provider_error(message: String) -> String:
	if _is_provider_insecure_http_error(message):
		return "这是公网 HTTP 地址，请允许明文 HTTP 后再保存"
	if "provider base url must use http or https" in message.to_lower():
		return "Base URL 必须以 http:// 或 https:// 开头"
	if "provider base url is invalid" in message.to_lower():
		return "Base URL 为空或格式无效"
	return message

func _request_provider_insecure_http_confirmation(capability: String) -> void:
	_provider_http_confirmation_target = capability
	_set_provider_profile_status(
		capability,
		"检测到公网 HTTP 地址，请确认是否允许未加密传输。",
		Color("#D9A441")
	)
	_sync_provider_profile_buttons(capability)
	_provider_http_confirmation_dialog.popup_centered(Vector2i(600, 250))

func _confirm_provider_insecure_http() -> void:
	var capability := _provider_http_confirmation_target
	_provider_http_confirmation_target = ""
	var controls = _provider_profile_controls.get(capability, {})
	if capability.is_empty() or not controls is Dictionary or (controls as Dictionary).is_empty():
		return
	var allow_http := (controls as Dictionary).get("allow_insecure_http") as CheckBox
	if not is_instance_valid(allow_http):
		return
	allow_http.set_pressed_no_signal(true)
	_update_provider_profile_dirty(capability)
	_set_provider_profile_status(capability, "已确认明文 HTTP，正在重新保存…", Color("#D9A441"))
	call_deferred("_save_provider_profile", capability)

func _cancel_provider_insecure_http() -> void:
	var capability := _provider_http_confirmation_target
	_provider_http_confirmation_target = ""
	if capability.is_empty():
		return
	_set_provider_profile_status(capability, "已取消；公网 HTTP 配置未保存。", Color("#D9A441"))
	_sync_provider_profile_buttons(capability)

func _diagnose_provider(capability: String) -> void:
	if _provider_busy:
		return
	_provider_busy = true
	if capability == "chat":
		_set_provider_status("正在发送最小诊断请求…", Color(ThemeMgr.get_current_theme_data().primary))
	else:
		_set_provider_profile_status(capability, "正在诊断连接…", Color(ThemeMgr.get_current_theme_data().primary))
	_sync_provider_buttons()
	for capability_variant in CAPABILITY_PROVIDER_UI:
		_sync_provider_profile_buttons(str(capability_variant))
	var result: Dictionary = await CompanionCore.diagnose_provider(capability)
	_provider_busy = false
	var message := ""
	var color := Color("#4CAF7D")
	if not bool(result.get("ok", false)):
		message = "诊断失败：%s" % str(result.get("message", "网络请求失败"))
		color = Color("#D9534F")
	else:
		var data = result.get("data", {})
		if data is Dictionary:
			message = "连接正常 · %d ms · %s" % [
				int((data as Dictionary).get("latency_ms", 0)),
				str((data as Dictionary).get("model", "未知模型")),
			]
			var details = (data as Dictionary).get("details", {})
			if capability == "embedding" and details is Dictionary:
				message += " · %d 维" % int((details as Dictionary).get("vector_dimensions", 0))
	if capability == "chat":
		_set_provider_status(message, color)
	else:
		_set_provider_profile_status(capability, message, color)
	_sync_provider_buttons()
	for capability_variant in CAPABILITY_PROVIDER_UI:
		_sync_provider_profile_buttons(str(capability_variant))

func _request_clear_provider_profile_key(capability: String) -> void:
	var loaded := _capability_loaded_or_default(capability)
	if _provider_busy or not bool(loaded.get("saved_api_key_configured", false)):
		return
	_provider_clear_target = capability
	_provider_clear_dialog.dialog_text = "这会删除%s独立保存的密钥；若启用了“复用聊天 Key”，将自动回退到聊天密钥。" % str((CAPABILITY_PROVIDER_UI[capability] as Dictionary).label)
	_provider_clear_dialog.popup_centered(Vector2i(540, 220))

func _clear_provider_profile_key(capability: String) -> void:
	var current := _collect_provider_profile_values(capability)
	_provider_busy = true
	_provider_write_in_flight = true
	_set_provider_profile_status(capability, "正在清除独立 Key…", Color(ThemeMgr.get_current_theme_data().primary))
	var result: Dictionary = await CompanionCore.configure_provider_profile(
		capability,
		str(current.get("base_url", "")),
		str(current.get("model", "")),
		str(current.get("protocol", "")),
		bool(current.get("enabled", false)),
		bool(current.get("inherit_chat_key", false)),
		bool(current.get("allow_insecure_http", false)),
		"",
		true
	)
	_provider_busy = false
	_provider_write_in_flight = false
	if not bool(result.get("ok", false)):
		_set_provider_profile_status(capability, "清除失败：%s" % str(result.get("message", "Core 不可用")), Color("#D9534F"))
		return
	var profile_data = result.get("data", {})
	if profile_data is Dictionary:
		_provider_profile_loaded[capability] = (profile_data as Dictionary).duplicate(true)
		_apply_provider_profile_values_to_controls(capability, profile_data as Dictionary)
	_provider_profile_dirty[capability] = false
	_render_provider_profile_status(capability, "独立 Key 已清除")
	_sync_provider_profile_buttons(capability)
	_provider_clear_target = "chat"

func _render_provider_profile_status(capability: String, prefix: String = "") -> void:
	var loaded := _capability_loaded_or_default(capability)
	var text := prefix
	var color := Color("#4CAF7D")
	if bool(_provider_profile_dirty.get(capability, false)):
		text = "有未保存修改"
		color = Color("#D9A441")
	elif text.is_empty():
		if not bool(loaded.get("enabled", false)):
			text = "未启用"
			color = Color(ThemeMgr.get_current_theme_data().secondary, 0.96)
		else:
			match str(loaded.get("credential_source", "none")):
				"inherited_chat": text = "已启用 · 复用聊天 Key"
				"encrypted_store": text = "已启用 · 独立 Key 已安全保存"
				"environment": text = "已启用 · Key 来自环境变量"
				_:
					text = "已启用 · 未配置 Key"
					color = Color("#D9A441")
	if (
		bool(loaded.get("allow_insecure_http", false))
		and str(loaded.get("base_url", "")).begins_with("http://")
	):
		text += " · 明文 HTTP"
		color = Color("#D9A441")
	_set_provider_profile_status(capability, text, color)

func _set_provider_profile_status(capability: String, text: String, color: Color) -> void:
	var controls = _provider_profile_controls.get(capability, {})
	if not controls is Dictionary or not is_instance_valid((controls as Dictionary).get("status")):
		return
	var status := (controls as Dictionary).status as Label
	status.text = text
	status.tooltip_text = text
	status.add_theme_color_override("font_color", color)

func _sync_provider_profile_buttons(capability: String) -> void:
	var controls = _provider_profile_controls.get(capability, {})
	if not controls is Dictionary or (controls as Dictionary).is_empty():
		return
	((controls as Dictionary).save as Button).disabled = (
		_provider_busy or not bool(_provider_profile_dirty.get(capability, false))
	)
	((controls as Dictionary).clear as Button).disabled = (
		_provider_busy
		or not bool(_capability_loaded_or_default(capability).get("saved_api_key_configured", false))
	)
	if is_instance_valid((controls as Dictionary).get("diagnose")):
		((controls as Dictionary).diagnose as Button).disabled = (
			_provider_busy
			or bool(_provider_profile_dirty.get(capability, false))
			or not bool(_capability_loaded_or_default(capability).get("request_ready", false))
		)

func _collect_provider_rag_values() -> Dictionary:
	if _provider_rag_controls.is_empty():
		return {}
	return {
		"enabled": (_provider_rag_controls.enabled as CheckBox).button_pressed,
		"use_embeddings": (_provider_rag_controls.use_embeddings as CheckBox).button_pressed,
		"use_rerank": (_provider_rag_controls.use_rerank as CheckBox).button_pressed,
		"top_k": roundi((_provider_rag_controls.top_k as SpinBox).value),
		"candidate_limit": roundi((_provider_rag_controls.candidate_limit as SpinBox).value),
		"chunk_size": roundi((_provider_rag_controls.chunk_size as SpinBox).value),
		"chunk_overlap": roundi((_provider_rag_controls.chunk_overlap as SpinBox).value),
	}

func _update_provider_rag_dirty() -> void:
	if _provider_suppress_dirty:
		return
	_provider_rag_dirty = _collect_provider_rag_values() != _rag_loaded_or_default()
	_render_provider_rag_status()
	_sync_provider_rag_button()

func _save_provider_rag() -> void:
	if _provider_busy:
		return
	var values := _collect_provider_rag_values()
	_provider_busy = true
	_provider_write_in_flight = true
	_set_provider_rag_status("正在保存 RAG 配置…", Color(ThemeMgr.get_current_theme_data().primary))
	var result: Dictionary = await CompanionCore.configure_rag(values)
	_provider_busy = false
	_provider_write_in_flight = false
	if not bool(result.get("ok", false)):
		_set_provider_rag_status("保存失败：%s" % str(result.get("message", "配置无效")), Color("#D9534F"))
		_sync_provider_rag_button()
		return
	var response_data = result.get("data", {})
	var normalized_settings = (response_data as Dictionary).get("settings", values) if response_data is Dictionary else values
	_provider_rag_loaded = (normalized_settings as Dictionary).duplicate(true) if normalized_settings is Dictionary else values.duplicate(true)
	_apply_provider_rag_values_to_controls(_provider_rag_loaded)
	_provider_rag_dirty = false
	_render_provider_rag_status("RAG 配置已保存")
	_sync_provider_rag_button()

func _render_provider_rag_status(prefix: String = "") -> void:
	var text := prefix
	var color := Color("#4CAF7D")
	if _provider_rag_dirty:
		text = "有未保存修改"
		color = Color("#D9A441")
	elif text.is_empty():
		text = "RAG 已启用" if bool(_rag_loaded_or_default().get("enabled", false)) else "RAG 未启用"
		if not bool(_rag_loaded_or_default().get("enabled", false)):
			color = Color(ThemeMgr.get_current_theme_data().secondary, 0.96)
	_set_provider_rag_status(text, color)

func _set_provider_rag_status(text: String, color: Color) -> void:
	if _provider_rag_controls.is_empty() or not is_instance_valid(_provider_rag_controls.get("status")):
		return
	var status := _provider_rag_controls.status as Label
	status.text = text
	status.add_theme_color_override("font_color", color)

func _sync_provider_rag_button() -> void:
	if not _provider_rag_controls.is_empty():
		(_provider_rag_controls.save as Button).disabled = _provider_busy or not _provider_rag_dirty

func _import_rag_document() -> void:
	if _provider_busy or _rag_operation_busy:
		return
	var title := _rag_document_title.text.strip_edges()
	var content := _rag_document_text.text.strip_edges()
	if title.is_empty() or content.is_empty():
		_rag_document_status.text = "请填写标题和知识正文"
		_rag_document_status.add_theme_color_override("font_color", Color("#D9534F"))
		return
	_rag_operation_busy = true
	_provider_write_in_flight = true
	_rag_document_status.text = "正在分块、嵌入并保存…"
	var payload := {
		"title": title,
		"text": content,
		"scope": str(_rag_document_scope.get_item_metadata(_rag_document_scope.selected)),
		"source_uri": _rag_document_source.text.strip_edges(),
	}
	if not _rag_document_id.is_empty():
		payload["document_id"] = _rag_document_id
	var result: Dictionary = await CompanionCore.put_rag_document(payload)
	_rag_operation_busy = false
	_provider_write_in_flight = false
	if not bool(result.get("ok", false)):
		_rag_document_status.text = "导入失败：%s" % str(result.get("message", "Core 不可用"))
		_rag_document_status.add_theme_color_override("font_color", Color("#D9534F"))
		return
	var data = result.get("data", {})
	var document = (data as Dictionary).get("document", {}) if data is Dictionary else {}
	_rag_document_status.text = "文档已保存 · %d 个片段" % int((document as Dictionary).get("chunk_count", 0)) if document is Dictionary else "文档已保存"
	_rag_document_status.add_theme_color_override("font_color", Color("#4CAF7D"))
	if document is Dictionary:
		_rag_document_id = str((document as Dictionary).get("document_id", _rag_document_id))
	_rag_document_dirty = false
	await _refresh_rag_library()

func _on_provider_preset_selected(index: int) -> void:
	if index <= 0 or not is_instance_valid(_provider_preset_select):
		return
	var preset = _provider_preset_select.get_item_metadata(index)
	if not preset is Dictionary:
		return
	_provider_suppress_dirty = true
	_provider_base_url_input.text = str((preset as Dictionary).get("base_url", ""))
	_provider_model_input.text = str((preset as Dictionary).get("model", ""))
	_provider_preset_select.select(0)
	_provider_suppress_dirty = false
	_update_provider_dirty_state()

func _refresh_provider_status() -> void:
	_provider_request_generation += 1
	var generation := _provider_request_generation
	_provider_busy = true
	_set_provider_status("正在读取 Companion Core 配置…", Color(ThemeMgr.get_current_theme_data().secondary, 0.96))
	_sync_provider_buttons()
	var result: Dictionary = await CompanionCore.get_provider_status()
	if generation != _provider_request_generation:
		return
	_provider_busy = false
	if not bool(result.get("ok", false)):
		_set_provider_status(
			"Core 离线或未鉴权：%s" % str(result.get("message", "无法读取模型配置")),
			Color("#D9534F")
		)
		_sync_provider_buttons()
		return
	var response_data = result.get("data", {})
	if not response_data is Dictionary:
		_set_provider_status("Companion Core 返回了无效配置", Color("#D9534F"))
		_sync_provider_buttons()
		return
	_provider_status_data = (response_data as Dictionary).duplicate(true)
	_provider_loaded_values = {
		"base_url": str(_provider_status_data.get("base_url", "")),
		"model": str(_provider_status_data.get("model", "")),
	}
	_apply_provider_catalog_to_advanced_controls()
	if not _provider_dirty:
		_apply_provider_values_to_controls(_provider_loaded_values, "")
	_render_provider_status()
	_sync_provider_buttons()

func _apply_provider_catalog_to_advanced_controls() -> void:
	var profiles = _provider_status_data.get("profiles", {})
	if profiles is Dictionary:
		for capability_variant in CAPABILITY_PROVIDER_UI:
			var capability := str(capability_variant)
			var profile = (profiles as Dictionary).get(capability, {})
			if profile is Dictionary and not (profile as Dictionary).is_empty():
				_provider_profile_loaded[capability] = (profile as Dictionary).duplicate(true)
				if not bool(_provider_profile_dirty.get(capability, false)):
					_apply_provider_profile_values_to_controls(capability, profile as Dictionary)
			_render_provider_profile_status(capability)
			_sync_provider_profile_buttons(capability)
	var rag = _provider_status_data.get("rag", {})
	if rag is Dictionary and not (rag as Dictionary).is_empty():
		_provider_rag_loaded = (rag as Dictionary).duplicate(true)
		if not _provider_rag_dirty:
			_apply_provider_rag_values_to_controls(_provider_rag_loaded)
		_render_provider_rag_status()
		_sync_provider_rag_button()
	var network_proxy = _provider_status_data.get("network_proxy", {})
	if network_proxy is Dictionary and not (network_proxy as Dictionary).is_empty():
		_provider_proxy_loaded = (network_proxy as Dictionary).duplicate(true)
		if not _provider_proxy_dirty:
			_apply_provider_proxy_values_to_controls(_provider_proxy_loaded)
		_render_provider_proxy_status()
		_sync_provider_proxy_controls()
	var fallback_catalog = _provider_status_data.get("fallbacks", {})
	if fallback_catalog is Dictionary:
		for capability in ["chat", "vision", "embedding", "rerank", "asr", "tts"]:
			var candidates = (fallback_catalog as Dictionary).get(capability, [])
			if candidates is Array and not bool(_provider_fallback_dirty.get(capability, false)):
				_provider_fallback_loaded[capability] = candidates.duplicate(true)
				_provider_fallback_drafts[capability] = candidates.duplicate(true)
				_rebuild_provider_fallback_rows(capability)
			_render_provider_fallback_status(capability)

func _apply_provider_profile_values_to_controls(capability: String, values: Dictionary) -> void:
	var controls = _provider_profile_controls.get(capability, {})
	if not controls is Dictionary or (controls as Dictionary).is_empty():
		return
	_provider_suppress_dirty = true
	((controls as Dictionary).base_url as LineEdit).text = str(values.get("base_url", ""))
	((controls as Dictionary).model as LineEdit).text = str(values.get("model", ""))
	((controls as Dictionary).api_key as LineEdit).text = ""
	((controls as Dictionary).enabled as CheckBox).button_pressed = bool(values.get("enabled", false))
	((controls as Dictionary).inherit_chat_key as CheckBox).button_pressed = bool(values.get("inherit_chat_key", false))
	((controls as Dictionary).allow_insecure_http as CheckBox).button_pressed = bool(values.get("allow_insecure_http", false))
	if capability == "tts":
		var saved_voices := _saved_tts_voices()
		var ling_voice := (controls as Dictionary).get("voice_ling") as LineEdit
		var nai_voice := (controls as Dictionary).get("voice_nai") as LineEdit
		if is_instance_valid(ling_voice):
			ling_voice.text = str(values.get("voice_ling", saved_voices.get("ling", "")))
		if is_instance_valid(nai_voice):
			nai_voice.text = str(values.get("voice_nai", saved_voices.get("nai", "")))
	var protocol_select := (controls as Dictionary).protocol as OptionButton
	for index in protocol_select.item_count:
		if str(protocol_select.get_item_metadata(index)) == str(values.get("protocol", "")):
			protocol_select.select(index)
			break
	_provider_suppress_dirty = false

func _apply_provider_rag_values_to_controls(values: Dictionary) -> void:
	if _provider_rag_controls.is_empty():
		return
	_provider_suppress_dirty = true
	(_provider_rag_controls.enabled as CheckBox).button_pressed = bool(values.get("enabled", false))
	(_provider_rag_controls.use_embeddings as CheckBox).button_pressed = bool(values.get("use_embeddings", true))
	(_provider_rag_controls.use_rerank as CheckBox).button_pressed = bool(values.get("use_rerank", false))
	(_provider_rag_controls.top_k as SpinBox).value = float(values.get("top_k", 6))
	(_provider_rag_controls.candidate_limit as SpinBox).value = float(values.get("candidate_limit", 24))
	(_provider_rag_controls.chunk_size as SpinBox).value = float(values.get("chunk_size", 900))
	(_provider_rag_controls.chunk_overlap as SpinBox).value = float(values.get("chunk_overlap", 120))
	_provider_suppress_dirty = false

func _save_provider_settings() -> void:
	if _provider_busy or not is_instance_valid(_provider_base_url_input):
		return
	var base_url := _provider_base_url_input.text.strip_edges()
	var model := _provider_model_input.text.strip_edges()
	var api_key := _provider_api_key_input.text.strip_edges()
	_provider_busy = true
	_provider_write_in_flight = true
	_set_provider_status("正在安全保存并应用…", Color(ThemeMgr.get_current_theme_data().primary))
	_sync_provider_buttons()
	var result: Dictionary = await CompanionCore.configure_provider(base_url, model, api_key, false)
	_provider_busy = false
	_provider_write_in_flight = false
	if not bool(result.get("ok", false)):
		_set_provider_status(
			"保存失败：%s" % str(result.get("message", "请检查地址、模型和 Key")),
			Color("#D9534F")
		)
		_sync_provider_buttons()
		return
	var response_data = result.get("data", {})
	if response_data is Dictionary:
		_provider_status_data = (response_data as Dictionary).duplicate(true)
		_apply_provider_catalog_to_advanced_controls()
	_provider_loaded_values = {
		"base_url": str(_provider_status_data.get("base_url", base_url)),
		"model": str(_provider_status_data.get("model", model)),
	}
	_provider_dirty = false
	_apply_provider_values_to_controls(_provider_loaded_values, "")
	_render_provider_status("已保存并立即生效")
	_sync_provider_buttons()

func _request_clear_provider_api_key() -> void:
	if _provider_busy or not bool(_provider_status_data.get("saved_api_key_configured", false)):
		return
	_provider_clear_target = "chat"
	_provider_clear_dialog.dialog_text = "这会删除由当前 Windows 用户加密保存的聊天模型密钥。环境变量中的密钥不会被删除。"
	_provider_clear_dialog.popup_centered(Vector2i(510, 210))

func _clear_provider_api_key() -> void:
	if _provider_busy:
		return
	if _provider_clear_target != "chat":
		await _clear_provider_profile_key(_provider_clear_target)
		return
	_provider_busy = true
	_provider_write_in_flight = true
	_set_provider_status("正在清除已保存的 Key…", Color(ThemeMgr.get_current_theme_data().primary))
	_sync_provider_buttons()
	var result: Dictionary = await CompanionCore.configure_provider(
		_provider_base_url_input.text.strip_edges(),
		_provider_model_input.text.strip_edges(),
		"",
		true
	)
	_provider_busy = false
	_provider_write_in_flight = false
	if not bool(result.get("ok", false)):
		_set_provider_status(
			"清除失败：%s" % str(result.get("message", "Companion Core 不可用")),
			Color("#D9534F")
		)
		_sync_provider_buttons()
		return
	var response_data = result.get("data", {})
	if response_data is Dictionary:
		_provider_status_data = (response_data as Dictionary).duplicate(true)
		_apply_provider_catalog_to_advanced_controls()
	_provider_loaded_values = {
		"base_url": str(_provider_status_data.get("base_url", _provider_base_url_input.text.strip_edges())),
		"model": str(_provider_status_data.get("model", _provider_model_input.text.strip_edges())),
	}
	_provider_dirty = false
	_apply_provider_values_to_controls(_provider_loaded_values, "")
	_render_provider_status("已清除加密保存的 Key")
	_sync_provider_buttons()
	_provider_clear_target = "chat"

func _collect_provider_draft() -> Dictionary:
	if not is_instance_valid(_provider_base_url_input):
		return {}
	var profiles := {}
	for capability_variant in CAPABILITY_PROVIDER_UI:
		var capability := str(capability_variant)
		profiles[capability] = _collect_provider_profile_values(capability)
	return {
		"base_url": _provider_base_url_input.text,
		"model": _provider_model_input.text,
		"api_key": _provider_api_key_input.text,
		"show_key": _provider_show_key.button_pressed,
		"profiles": profiles,
		"fallbacks": _provider_fallback_drafts.duplicate(true),
		"network_proxy": _collect_provider_proxy_values(),
	}

func _restore_provider_draft(draft: Dictionary) -> void:
	if draft.is_empty() or not is_instance_valid(_provider_base_url_input):
		return
	_apply_provider_values_to_controls(draft, str(draft.get("api_key", "")))
	_provider_show_key.set_pressed_no_signal(bool(draft.get("show_key", false)))
	_provider_api_key_input.secret = not _provider_show_key.button_pressed
	_update_provider_dirty_state()
	var profiles = draft.get("profiles", {})
	if profiles is Dictionary:
		for capability_variant in CAPABILITY_PROVIDER_UI:
			var capability := str(capability_variant)
			var values = (profiles as Dictionary).get(capability, {})
			if not values is Dictionary or (values as Dictionary).is_empty():
				continue
			_apply_provider_profile_values_to_controls(capability, values as Dictionary)
			var controls: Dictionary = _provider_profile_controls[capability]
			_provider_suppress_dirty = true
			(controls.api_key as LineEdit).text = str((values as Dictionary).get("api_key", ""))
			_provider_suppress_dirty = false
			_update_provider_profile_dirty(capability)
	var fallbacks = draft.get("fallbacks", {})
	if fallbacks is Dictionary:
		_provider_fallback_drafts = (fallbacks as Dictionary).duplicate(true)
		for capability in ["chat", "vision", "embedding", "rerank", "asr", "tts"]:
			_rebuild_provider_fallback_rows(capability)
	var network_proxy = draft.get("network_proxy", {})
	if network_proxy is Dictionary and not (network_proxy as Dictionary).is_empty():
		_apply_provider_proxy_values_to_controls(network_proxy as Dictionary)
		_update_provider_proxy_dirty()

func _collect_knowledge_draft() -> Dictionary:
	if not is_instance_valid(_rag_document_title):
		return {}
	return {
		"rag": _collect_provider_rag_values(),
		"document_id": _rag_document_id,
		"document_title": _rag_document_title.text,
		"document_text": _rag_document_text.text,
		"document_scope": _rag_document_scope.selected,
		"document_source": _rag_document_source.text,
		"document_dirty": _rag_document_dirty,
		"url": _rag_url_input.text if is_instance_valid(_rag_url_input) else "",
		"import_scope": _rag_import_scope.selected if is_instance_valid(_rag_import_scope) else 0,
		"filter": _rag_document_filter.text if is_instance_valid(_rag_document_filter) else "",
		"scope_filter": _rag_scope_filter.selected if is_instance_valid(_rag_scope_filter) else 0,
		"search_query": _rag_search_query.text if is_instance_valid(_rag_search_query) else "",
		"search_role": _rag_search_role.selected if is_instance_valid(_rag_search_role) else 0,
	}

func _restore_knowledge_draft(draft: Dictionary) -> void:
	if draft.is_empty() or not is_instance_valid(_rag_document_title):
		return
	var rag = draft.get("rag", {})
	if rag is Dictionary and not (rag as Dictionary).is_empty():
		_apply_provider_rag_values_to_controls(rag as Dictionary)
		_update_provider_rag_dirty()
	_provider_suppress_dirty = true
	_rag_document_id = str(draft.get("document_id", ""))
	_rag_document_title.text = str(draft.get("document_title", ""))
	_rag_document_text.text = str(draft.get("document_text", ""))
	_rag_document_source.text = str(draft.get("document_source", ""))
	_rag_document_scope.select(clampi(int(draft.get("document_scope", 0)), 0, _rag_document_scope.item_count - 1))
	if is_instance_valid(_rag_url_input):
		_rag_url_input.text = str(draft.get("url", ""))
	if is_instance_valid(_rag_import_scope):
		_rag_import_scope.select(clampi(
			int(draft.get("import_scope", 0)), 0, _rag_import_scope.item_count - 1
		))
	if is_instance_valid(_rag_document_filter):
		_rag_document_filter.text = str(draft.get("filter", ""))
	if is_instance_valid(_rag_scope_filter):
		_rag_scope_filter.select(clampi(
			int(draft.get("scope_filter", 0)), 0, _rag_scope_filter.item_count - 1
		))
	if is_instance_valid(_rag_search_query):
		_rag_search_query.text = str(draft.get("search_query", ""))
		_rag_search_role.select(clampi(int(draft.get("search_role", 0)), 0, _rag_search_role.item_count - 1))
	_provider_suppress_dirty = false
	_rag_document_dirty = bool(draft.get("document_dirty", false))
	if _rag_document_dirty:
		_set_rag_document_message("有未保存的文档修改", Color("#D9A441"))
	_render_rag_document_list()

func _capture_visible_category_draft() -> void:
	match _settings_category:
		"ai":
			if _has_unsaved_ai_draft():
				_category_drafts["ai"] = _collect_provider_draft()
			else:
				_category_drafts.erase("ai")
		"knowledge":
			_category_drafts["knowledge"] = _collect_knowledge_draft()
		"life":
			_category_drafts["life"] = {
				"ambient": _collect_ambient_values(),
			}
		"advanced":
			_category_drafts["advanced"] = {
				"runtime": _collect_runtime_values(),
				"stats": _collect_current_stats(),
				"stat_role": _stat_role,
				"interaction_values": _collect_developer_values(),
				"interaction_role": _developer_role,
				"interaction_action": _developer_action,
			}

func _has_unsaved_ai_draft() -> bool:
	if _provider_dirty or _provider_proxy_dirty:
		return true
	for capability_variant in _provider_profile_dirty:
		if bool(_provider_profile_dirty.get(capability_variant, false)):
			return true
	for capability_variant in _provider_fallback_dirty:
		if bool(_provider_fallback_dirty.get(capability_variant, false)):
			return true
	return false

func _restore_visible_category_draft() -> void:
	var draft = _category_drafts.get(_settings_category, {})
	if not draft is Dictionary or (draft as Dictionary).is_empty():
		return
	match _settings_category:
		"ai":
			_restore_provider_draft(draft as Dictionary)
		"knowledge":
			_restore_knowledge_draft(draft as Dictionary)
		"life":
			var life: Dictionary = draft
			var ambient = life.get("ambient", {})
			if ambient is Dictionary:
				_restore_ambient_draft(ambient as Dictionary)
		"advanced":
			var advanced: Dictionary = draft
			var runtime = advanced.get("runtime", {})
			if runtime is Dictionary:
				_apply_runtime_values_to_controls(runtime as Dictionary)
				_update_runtime_dirty_state()
			var stats = advanced.get("stats", {})
			if stats is Dictionary:
				for stat_variant in stats:
					var stat := str(stat_variant)
					if _stat_controls.has(stat):
						(_stat_controls[stat] as SpinBox).set_value_no_signal(float((stats as Dictionary)[stat_variant]))
				_update_stat_dirty_state()
			var values = advanced.get("interaction_values", {})
			if values is Dictionary:
				_restore_developer_draft(values as Dictionary)

func _has_provider_dirty() -> bool:
	if (
		_provider_dirty
		or _provider_proxy_dirty
		or _provider_rag_dirty
		or _rag_document_dirty
	):
		return true
	for capability_variant in _provider_profile_dirty:
		if bool(_provider_profile_dirty[capability_variant]):
			return true
	for capability_variant in _provider_fallback_dirty:
		if bool(_provider_fallback_dirty[capability_variant]):
			return true
	return false

func _apply_provider_values_to_controls(values: Dictionary, api_key: String) -> void:
	if not is_instance_valid(_provider_base_url_input):
		return
	_provider_suppress_dirty = true
	_provider_base_url_input.text = str(values.get("base_url", ""))
	_provider_model_input.text = str(values.get("model", ""))
	_provider_api_key_input.text = api_key
	_provider_suppress_dirty = false

func _update_provider_dirty_state() -> void:
	if _provider_suppress_dirty or not is_instance_valid(_provider_base_url_input):
		return
	_provider_dirty = (
		_provider_base_url_input.text.strip_edges() != str(_provider_loaded_values.get("base_url", ""))
		or _provider_model_input.text.strip_edges() != str(_provider_loaded_values.get("model", ""))
		or not _provider_api_key_input.text.strip_edges().is_empty()
	)
	if _provider_dirty:
		_set_provider_status("有未保存的模型连接修改", Color("#D9A441"))
	else:
		_render_provider_status()
	_sync_provider_buttons()

func _render_provider_status(prefix: String = "") -> void:
	if not is_instance_valid(_provider_status):
		return
	var source := str(_provider_status_data.get("credential_source", "none"))
	var configured := bool(_provider_status_data.get("api_key_configured", false))
	var message := prefix
	var color := Color("#4CAF7D")
	if message.is_empty():
		match source:
			"environment":
				message = "Key 来自环境变量"
			"encrypted_store":
				message = "Key 已由 Windows 安全保存"
			"runtime":
				message = "Key 仅在本次运行中有效"
			"config":
				message = "Key 来自旧版 Core 配置"
			_:
				message = "未配置 Key；本地无鉴权模型仍可使用"
				color = Color(ThemeMgr.get_current_theme_data().secondary, 0.96)
	if configured and source == "environment" and bool(_provider_status_data.get("saved_api_key_configured", false)):
		message += "（另有加密备用 Key）"
	_set_provider_status(message, color)

func _set_provider_status(text: String, color: Color) -> void:
	if not is_instance_valid(_provider_status):
		return
	_provider_status.text = text
	_provider_status.tooltip_text = text
	_provider_status.add_theme_color_override("font_color", color)

func _sync_provider_buttons() -> void:
	if is_instance_valid(_provider_save_button):
		_provider_save_button.disabled = _provider_busy or not _provider_dirty
	if is_instance_valid(_provider_clear_button):
		_provider_clear_button.disabled = (
			_provider_busy
			or not bool(_provider_status_data.get("saved_api_key_configured", false))
		)
	if is_instance_valid(_provider_diagnose_button):
		_provider_diagnose_button.disabled = (
			_provider_busy
			or _provider_dirty
			or not bool(_provider_status_data.get("api_key_configured", false))
		)
	_sync_provider_proxy_controls()
	for capability in _provider_fallback_controls:
		var controls = _provider_fallback_controls.get(capability, {})
		if not controls is Dictionary:
			continue
		if is_instance_valid((controls as Dictionary).get("save")):
			((controls as Dictionary).save as Button).disabled = _provider_busy or not bool(_provider_fallback_dirty.get(capability, false))
		if is_instance_valid((controls as Dictionary).get("add")):
			var candidates = _provider_fallback_drafts.get(capability, [])
			((controls as Dictionary).add as Button).disabled = _provider_busy or (candidates is Array and (candidates as Array).size() >= 6)

func _build_developer_runtime_section(data: Dictionary, include_current_stats := true) -> void:
	_content.add_child(_section_label("开发者 · 运行参数", data))
	var notice := Label.new()
	notice.text = "运行参数全局保存并即时生效；当前属性只写入正在使用的旅程。"
	notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	notice.add_theme_font_size_override("font_size", 11)
	notice.add_theme_color_override("font_color", Color(data.secondary, 0.96))
	_content.add_child(notice)

	_runtime_loaded_values = Settings.get_runtime_tuning()
	_runtime_controls.clear()
	_runtime_group_reset_buttons.clear()
	if include_current_stats:
		_build_current_stats_editor(data)
	for group_variant in RUNTIME_TUNING.GROUPS:
		var group: Dictionary = group_variant
		var group_id := str(group.id)
		var heading := HBoxContainer.new()
		heading.add_theme_constant_override("separation", 8)
		_content.add_child(heading)
		var title := Label.new()
		title.text = str(group.label)
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		title.add_theme_font_size_override("font_size", 13)
		title.add_theme_color_override("font_color", Color(data.primary))
		heading.add_child(title)
		var reset := Button.new()
		reset.text = "↺"
		reset.tooltip_text = "恢复这个分组的默认值"
		reset.flat = true
		reset.custom_minimum_size = Vector2(32, 30)
		reset.pressed.connect(func(): _reset_runtime_group(group_id))
		heading.add_child(reset)
		_runtime_group_reset_buttons[group_id] = reset
		var grid := GridContainer.new()
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 12)
		grid.add_theme_constant_override("v_separation", 6)
		_content.add_child(grid)
		for key in RUNTIME_TUNING.specs_for_group(group_id):
			_add_runtime_control(grid, key, data)

	var command_row := HBoxContainer.new()
	command_row.add_theme_constant_override("separation", 8)
	_content.add_child(command_row)
	var save_button := Button.new()
	save_button.text = "保存全部运行参数"
	save_button.custom_minimum_size = Vector2(168, 36)
	save_button.pressed.connect(_save_runtime_tuning)
	command_row.add_child(save_button)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	command_row.add_child(spacer)
	_runtime_status = Label.new()
	_runtime_status.text = "尚未修改"
	_runtime_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_runtime_status.add_theme_font_size_override("font_size", 11)
	_runtime_status.add_theme_color_override("font_color", Color(data.secondary, 0.96))
	command_row.add_child(_runtime_status)
	_runtime_dirty = false

func _build_current_stats_editor(data: Dictionary) -> void:
	var heading := HBoxContainer.new()
	heading.add_theme_constant_override("separation", 8)
	_content.add_child(heading)
	var label := Label.new()
	label.text = "当前旅程属性"
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color(data.primary))
	heading.add_child(label)
	_stat_role_select = OptionButton.new()
	for role in DEVELOPER_ROLES:
		var role_data: Dictionary = Global.ROLES[role]
		var index := _stat_role_select.item_count
		_stat_role_select.add_item("%s %s" % [str(role_data.icon), str(role_data.name)])
		_stat_role_select.set_item_metadata(index, role)
		if role == _stat_role:
			_stat_role_select.select(index)
	_stat_role_select.item_selected.connect(_on_stat_role_selected)
	heading.add_child(_stat_role_select)
	var commands := HBoxContainer.new()
	commands.add_theme_constant_override("separation", 8)
	_content.add_child(commands)
	var save_button := Button.new()
	save_button.text = "保存属性"
	save_button.pressed.connect(_save_current_stats)
	commands.add_child(save_button)
	var default_button := Button.new()
	default_button.text = "设为新旅程默认"
	default_button.tooltip_text = "之后创建或重置旅程时使用当前输入值"
	default_button.pressed.connect(_save_current_stats_as_defaults)
	commands.add_child(default_button)
	var reset_button := Button.new()
	reset_button.text = "恢复项目默认"
	reset_button.pressed.connect(_reset_current_stats_draft)
	commands.add_child(reset_button)

	_stat_controls.clear()
	_stat_loaded_values = Global.get_role_stats(_stat_role).duplicate(true)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 5)
	_content.add_child(grid)
	for stat_variant in STAT_LABELS:
		var stat := str(stat_variant)
		var stat_label := Label.new()
		stat_label.text = str(STAT_LABELS[stat])
		stat_label.custom_minimum_size = Vector2(76, 0)
		stat_label.add_theme_font_size_override("font_size", 11)
		stat_label.add_theme_color_override("font_color", Color(data.text))
		grid.add_child(stat_label)
		var spin := SpinBox.new()
		spin.min_value = 0.0
		spin.max_value = 100.0
		spin.step = 0.1
		spin.value = float(_stat_loaded_values.get(stat, 0.0))
		spin.custom_minimum_size = Vector2(108, 32)
		spin.value_changed.connect(func(_value: float): _update_stat_dirty_state())
		grid.add_child(spin)
		_stat_controls[stat] = spin
	_stat_status = Label.new()
	_stat_status.text = "属性尚未修改"
	_stat_status.add_theme_font_size_override("font_size", 10)
	_stat_status.add_theme_color_override("font_color", Color(data.secondary, 0.96))
	_content.add_child(_stat_status)
	_stat_dirty = false

func _add_runtime_control(grid: GridContainer, key: String, data: Dictionary) -> void:
	var spec: Dictionary = RUNTIME_TUNING.SPECS[key]
	var label := Label.new()
	label.text = str(spec.label)
	label.custom_minimum_size = Vector2(210, 32)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", Color(data.text))
	grid.add_child(label)
	var control: Control
	match str(spec.type):
		"bool":
			var toggle := CheckBox.new()
			toggle.button_pressed = bool(_runtime_loaded_values.get(key, spec.default))
			toggle.toggled.connect(func(_pressed: bool): _update_runtime_dirty_state())
			control = toggle
		"option":
			var select := OptionButton.new()
			for option_variant in spec.options:
				var option: Dictionary = option_variant
				var index := select.item_count
				select.add_item(str(option.label))
				select.set_item_metadata(index, str(option.value))
				if str(_runtime_loaded_values.get(key, spec.default)) == str(option.value):
					select.select(index)
			select.item_selected.connect(func(_index: int): _update_runtime_dirty_state())
			control = select
		_:
			var spin := SpinBox.new()
			var percent := str(spec.type) == "percent"
			spin.min_value = float(spec.min) * (100.0 if percent else 1.0)
			spin.max_value = float(spec.max) * (100.0 if percent else 1.0)
			spin.step = float(spec.step) * (100.0 if percent else 1.0)
			spin.value = float(_runtime_loaded_values.get(key, spec.default)) * (100.0 if percent else 1.0)
			spin.rounded = str(spec.type) == "int"
			spin.suffix = "%" if percent else str(spec.get("suffix", ""))
			spin.custom_minimum_size = Vector2(170, 32)
			spin.value_changed.connect(func(_value: float): _update_runtime_dirty_state())
			control = spin
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(control)
	_runtime_controls[key] = control

func _collect_runtime_values() -> Dictionary:
	var values := {}
	for key_variant in _runtime_controls:
		var key := str(key_variant)
		var control = _runtime_controls[key]
		var spec: Dictionary = RUNTIME_TUNING.SPECS[key]
		if control is CheckBox:
			values[key] = (control as CheckBox).button_pressed
		elif control is OptionButton:
			var select := control as OptionButton
			values[key] = str(select.get_item_metadata(select.selected))
		elif control is SpinBox:
			var value := (control as SpinBox).value
			values[key] = value / 100.0 if str(spec.type) == "percent" else value
	return values

func _update_runtime_dirty_state() -> void:
	var normalized := RUNTIME_TUNING.normalize(_collect_runtime_values())
	_runtime_dirty = JSON.stringify(normalized) != JSON.stringify(_runtime_loaded_values)
	_set_runtime_status(
		"有未保存修改" if _runtime_dirty else "尚未修改",
		Color("#D9A441") if _runtime_dirty else Color(ThemeMgr.get_current_theme_data().secondary, 0.96)
	)

func _save_runtime_tuning() -> void:
	var result := Settings.set_runtime_tuning(_collect_runtime_values())
	var ok := bool(result.get("ok", false))
	if ok:
		_runtime_loaded_values = Settings.get_runtime_tuning()
		_runtime_dirty = false
		_apply_runtime_values_to_controls(_runtime_loaded_values)
	_set_runtime_status(
		str(result.get("message", "已保存" if ok else "保存失败")),
		Color("#4CAF7D") if ok else Color("#D9534F")
	)

func _reset_runtime_group(group: String) -> void:
	var defaults := RUNTIME_TUNING.defaults()
	for key in RUNTIME_TUNING.specs_for_group(group):
		_set_runtime_control_value(key, defaults[key])
	_update_runtime_dirty_state()

func _apply_runtime_values_to_controls(values: Dictionary) -> void:
	for key_variant in values:
		_set_runtime_control_value(str(key_variant), values[key_variant])

func _set_runtime_control_value(key: String, value: Variant) -> void:
	var control = _runtime_controls.get(key)
	if not is_instance_valid(control):
		return
	var spec: Dictionary = RUNTIME_TUNING.SPECS[key]
	if control is CheckBox:
		(control as CheckBox).set_pressed_no_signal(bool(value))
	elif control is OptionButton:
		var select := control as OptionButton
		for index in select.item_count:
			if str(select.get_item_metadata(index)) == str(value):
				select.select(index)
				break
	elif control is SpinBox:
		var multiplier := 100.0 if str(spec.type) == "percent" else 1.0
		(control as SpinBox).set_value_no_signal(float(value) * multiplier)

func _set_runtime_status(text: String, color: Color) -> void:
	if is_instance_valid(_runtime_status):
		_runtime_status.text = text
		_runtime_status.add_theme_color_override("font_color", color)

func _on_stat_role_selected(index: int) -> void:
	var role := str(_stat_role_select.get_item_metadata(index))
	if role not in DEVELOPER_ROLES:
		return
	_stat_role = role
	_build_stat_controls_values(Global.get_role_stats(role))

func _build_stat_controls_values(values: Dictionary) -> void:
	_stat_loaded_values = values.duplicate(true)
	for stat_variant in _stat_controls:
		var stat := str(stat_variant)
		(_stat_controls[stat] as SpinBox).set_value_no_signal(float(values.get(stat, 0.0)))
	_stat_dirty = false
	_set_stat_status("属性尚未修改", Color(ThemeMgr.get_current_theme_data().secondary, 0.96))

func _collect_current_stats() -> Dictionary:
	var values := {}
	for stat_variant in _stat_controls:
		var stat := str(stat_variant)
		values[stat] = (_stat_controls[stat] as SpinBox).value
	return values

func _update_stat_dirty_state() -> void:
	_stat_dirty = JSON.stringify(_collect_current_stats()) != JSON.stringify(_stat_loaded_values)
	_set_stat_status(
		"属性有未保存修改" if _stat_dirty else "属性尚未修改",
		Color("#D9A441") if _stat_dirty else Color(ThemeMgr.get_current_theme_data().secondary, 0.96)
	)

func _save_current_stats() -> void:
	var ok := Global.persist_role_stats(_stat_role, _collect_current_stats())
	if ok:
		_build_stat_controls_values(Global.get_role_stats(_stat_role))
	_set_stat_status("属性已保存" if ok else "属性保存失败", Color("#4CAF7D") if ok else Color("#D9534F"))

func _save_current_stats_as_defaults() -> void:
	var result := Settings.set_role_default_stats(_stat_role, _collect_current_stats())
	var ok := bool(result.get("ok", false))
	_set_stat_status(
		str(result.get("message", "默认属性已保存" if ok else "默认属性保存失败")),
		Color("#4CAF7D") if ok else Color("#D9534F")
	)

func _reset_current_stats_draft() -> void:
	var defaults: Dictionary = Global.call("_default_stats_for_role", _stat_role)
	for stat_variant in _stat_controls:
		var stat := str(stat_variant)
		(_stat_controls[stat] as SpinBox).set_value_no_signal(float(defaults.get(stat, 0.0)))
	_update_stat_dirty_state()

func _set_stat_status(text: String, color: Color) -> void:
	if is_instance_valid(_stat_status):
		_stat_status.text = text
		_stat_status.add_theme_color_override("font_color", color)

func _build_developer_interaction_section(data: Dictionary) -> void:
	_content.add_child(_section_label("开发者 · 互动数值", data))
	_developer_scope_label = Label.new()
	_developer_scope_label.text = _developer_scope_text(_developer_scope_save_id)
	_developer_scope_label.tooltip_text = (
		"完整旅程 ID：%s" % _developer_scope_save_id
		if not _developer_scope_save_id.is_empty()
		else "当前没有可用的已加载旅程"
	)
	_developer_scope_label.add_theme_font_size_override("font_size", 11)
	_developer_scope_label.add_theme_color_override("font_color", Color(data.accent, 0.92))
	_content.add_child(_developer_scope_label)
	var notice := PanelContainer.new()
	notice.add_theme_stylebox_override(
		"panel",
		_style(Color(data.accent, 0.08), Color(data.accent, 0.28), 10, 9)
	)
	_content.add_child(notice)
	var notice_label := Label.new()
	notice_label.text = (
		"⚙ 高级参数：数值按旅程独立保存；修改每次互动对属性的最终 delta。"
		+ "仅影响保存之后的新互动，不会重算现有属性、历史事件或正在等待的请求。"
	)
	notice_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	notice_label.add_theme_font_size_override("font_size", 11)
	notice_label.add_theme_color_override("font_color", Color(data.secondary, 0.96))
	notice.add_child(notice_label)

	var selectors := HBoxContainer.new()
	selectors.add_theme_constant_override("separation", 8)
	_content.add_child(selectors)
	_developer_role_select = OptionButton.new()
	_developer_role_select.custom_minimum_size = Vector2(150, 36)
	for role_variant in DEVELOPER_ROLES:
		var role := str(role_variant)
		var role_data: Dictionary = Global.ROLES.get(role, {})
		var index := _developer_role_select.item_count
		_developer_role_select.add_item("%s %s" % [
			str(role_data.get("icon", "")), str(role_data.get("name", role))
		])
		_developer_role_select.set_item_metadata(index, role)
		if role == _developer_role:
			_developer_role_select.select(index)
	_developer_role_select.item_selected.connect(_on_developer_role_selected)
	selectors.add_child(_developer_role_select)

	_developer_action_select = OptionButton.new()
	_developer_action_select.custom_minimum_size = Vector2(180, 36)
	for action_variant in INTERACTION_RULES.ACTION_LABELS:
		var action := str(action_variant)
		var index := _developer_action_select.item_count
		_developer_action_select.add_item(INTERACTION_RULES.action_label(action))
		_developer_action_select.set_item_metadata(index, action)
		if action == _developer_action:
			_developer_action_select.select(index)
	_developer_action_select.item_selected.connect(_on_developer_action_selected)
	selectors.add_child(_developer_action_select)

	var selector_spacer := Control.new()
	selector_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	selectors.add_child(selector_spacer)
	var reset_all := Button.new()
	reset_all.text = "本旅程全部恢复"
	reset_all.custom_minimum_size = Vector2(132, 36)
	reset_all.tooltip_text = "只清除当前旅程中两位角色的全部互动 delta 覆盖"
	reset_all.pressed.connect(_request_reset_all_developer_interactions)
	selectors.add_child(reset_all)

	_developer_delta_rows = VBoxContainer.new()
	_developer_delta_rows.add_theme_constant_override("separation", 6)
	_content.add_child(_developer_delta_rows)
	_rebuild_developer_delta_rows(data)

	var command_row := HBoxContainer.new()
	command_row.add_theme_constant_override("separation", 8)
	_content.add_child(command_row)
	var save_current := Button.new()
	save_current.text = "保存当前"
	save_current.custom_minimum_size = Vector2(112, 36)
	save_current.pressed.connect(_save_current_developer_interaction)
	command_row.add_child(save_current)
	var reset_current := Button.new()
	reset_current.text = "恢复当前默认"
	reset_current.custom_minimum_size = Vector2(132, 36)
	reset_current.pressed.connect(_reset_current_developer_interaction)
	command_row.add_child(reset_current)
	var command_spacer := Control.new()
	command_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	command_row.add_child(command_spacer)
	_developer_status = Label.new()
	_developer_status.text = "尚未修改"
	_developer_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_developer_status.add_theme_font_size_override("font_size", 11)
	_developer_status.add_theme_color_override("font_color", Color(data.secondary, 0.96))
	command_row.add_child(_developer_status)

func _build_developer_ambient_section(data: Dictionary) -> void:
	_content.add_child(_section_label("开发者 · 后台生活", data))
	var notice := Label.new()
	notice.text = (
		"两位角色只会在玩家空闲后互聊；时间配置为全局设置。"
		+ "关闭记忆整理时，对话仍保留在当前旅程聊天记录中，但不会交给 Heartloom。"
	)
	notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	notice.add_theme_font_size_override("font_size", 11)
	notice.add_theme_color_override("font_color", Color(data.secondary, 0.96))
	_content.add_child(notice)

	_ambient_loaded_values = Settings.get_ambient_dialogue_settings()
	_ambient_controls.clear()
	_add_ambient_toggle(
		"enabled",
		"允许小玲和小奈在后台自然聊天",
		bool(_ambient_loaded_values.enabled),
		data
	)
	_add_ambient_number(
		"idle_minutes", "玩家空闲多久后允许互聊", int(_ambient_loaded_values.idle_minutes),
		Settings.AMBIENT_IDLE_MINUTES_MIN, Settings.AMBIENT_IDLE_MINUTES_MAX, " 分钟", data
	)
	_add_ambient_number(
		"cooldown_min_minutes", "两次互聊最短间隔", int(_ambient_loaded_values.cooldown_min_minutes),
		Settings.AMBIENT_COOLDOWN_MINUTES_MIN, Settings.AMBIENT_COOLDOWN_MINUTES_MAX, " 分钟", data
	)
	_add_ambient_number(
		"cooldown_max_minutes", "两次互聊最长间隔", int(_ambient_loaded_values.cooldown_max_minutes),
		Settings.AMBIENT_COOLDOWN_MINUTES_MIN, Settings.AMBIENT_COOLDOWN_MINUTES_MAX, " 分钟", data
	)
	_add_ambient_number(
		"turns_min", "每次互聊最少消息数", int(_ambient_loaded_values.turns_min),
		Settings.AMBIENT_TURNS_MIN, Settings.AMBIENT_TURNS_MAX, " 条", data
	)
	_add_ambient_number(
		"turns_max", "每次互聊最多消息数", int(_ambient_loaded_values.turns_max),
		Settings.AMBIENT_TURNS_MIN, Settings.AMBIENT_TURNS_MAX, " 条", data
	)
	_add_ambient_toggle(
		"notifications_enabled",
		"整轮结束后发送一次 Windows 通知",
		bool(_ambient_loaded_values.notifications_enabled),
		data
	)
	_add_ambient_toggle(
		"memory_enabled",
		"将自然化后的角色间对话交给 Heartloom 整理",
		bool(_ambient_loaded_values.memory_enabled),
		data
	)

	var command_row := HBoxContainer.new()
	command_row.add_theme_constant_override("separation", 8)
	_content.add_child(command_row)
	var save_button := Button.new()
	save_button.text = "保存后台生活配置"
	save_button.custom_minimum_size = Vector2(168, 36)
	save_button.pressed.connect(_save_ambient_settings)
	command_row.add_child(save_button)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	command_row.add_child(spacer)
	_ambient_status = Label.new()
	_ambient_status.text = "尚未修改"
	_ambient_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_ambient_status.add_theme_font_size_override("font_size", 11)
	_ambient_status.add_theme_color_override("font_color", Color(data.secondary, 0.96))
	command_row.add_child(_ambient_status)
	_ambient_dirty = false

func _add_ambient_toggle(
	key: String,
	label_text: String,
	value: bool,
	data: Dictionary
) -> void:
	var toggle := CheckBox.new()
	toggle.text = label_text
	toggle.button_pressed = value
	toggle.add_theme_color_override("font_color", Color(data.text))
	toggle.toggled.connect(func(_pressed: bool):
		_update_ambient_dirty_state()
	)
	_content.add_child(toggle)
	_ambient_controls[key] = toggle

func _add_ambient_number(
	key: String,
	label_text: String,
	value: int,
	minimum: int,
	maximum: int,
	suffix: String,
	data: Dictionary
) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_content.add_child(row)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(260, 0)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_color_override("font_color", Color(data.text))
	row.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = 1.0
	spin.rounded = true
	spin.suffix = suffix
	spin.value = value
	spin.custom_minimum_size = Vector2(154, 34)
	spin.value_changed.connect(func(_new_value: float):
		_update_ambient_dirty_state()
	)
	row.add_child(spin)
	_ambient_controls[key] = spin

func _collect_ambient_values() -> Dictionary:
	var result := {}
	for key_variant in _ambient_controls:
		var key := str(key_variant)
		var control = _ambient_controls[key]
		if control is CheckBox:
			result[key] = bool((control as CheckBox).button_pressed)
		elif control is SpinBox:
			result[key] = int((control as SpinBox).value)
	return result

func _restore_ambient_draft(values: Dictionary) -> void:
	for key_variant in values:
		var key := str(key_variant)
		var control = _ambient_controls.get(key)
		if control is CheckBox:
			(control as CheckBox).set_pressed_no_signal(bool(values[key_variant]))
		elif control is SpinBox:
			(control as SpinBox).set_value_no_signal(float(values[key_variant]))
	_update_ambient_dirty_state()

func _update_ambient_dirty_state() -> void:
	var current := _collect_ambient_values()
	_ambient_dirty = JSON.stringify(current) != JSON.stringify(_ambient_loaded_values)
	_set_ambient_status(
		"有未保存修改" if _ambient_dirty else "尚未修改",
		Color("#D9A441") if _ambient_dirty else Color(ThemeMgr.get_current_theme_data().secondary, 0.96)
	)

func _save_ambient_settings() -> void:
	var result := Settings.set_ambient_dialogue_settings(_collect_ambient_values())
	var ok := bool(result.get("ok", false))
	if ok:
		_ambient_loaded_values = Settings.get_ambient_dialogue_settings()
		_ambient_dirty = false
	_set_ambient_status(
		str(result.get("message", "已保存" if ok else "保存失败")),
		Color("#4CAF7D") if ok else Color("#D9534F")
	)

func _set_ambient_status(text: String, color: Color) -> void:
	if not is_instance_valid(_ambient_status):
		return
	_ambient_status.text = text
	_ambient_status.add_theme_color_override("font_color", color)

func _rebuild_developer_delta_rows(data: Dictionary) -> void:
	if not is_instance_valid(_developer_delta_rows):
		return
	for child in _developer_delta_rows.get_children():
		child.free()
	_developer_spinboxes.clear()
	_developer_dirty = false
	var defaults := _updates_to_dictionary(
		INTERACTION_RULES.default_updates(_developer_role, _developer_action)
	)
	var effective := _updates_to_dictionary(
		Settings.get_effective_interaction_updates(_developer_role, _developer_action)
	)
	_developer_loaded_values = effective.duplicate(true)
	var overrides := Settings.get_interaction_overrides(_developer_role, _developer_action)
	for stat_variant in INTERACTION_RULES.action_stat_keys(_developer_action):
		var stat := str(stat_variant)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		_developer_delta_rows.add_child(row)
		var label := Label.new()
		label.text = str(STAT_LABELS.get(stat, stat))
		label.custom_minimum_size = Vector2(112, 0)
		label.add_theme_color_override("font_color", Color(data.text))
		row.add_child(label)
		var default_label := Label.new()
		default_label.text = "默认 %s" % _format_delta(float(defaults.get(stat, 0.0)))
		default_label.custom_minimum_size = Vector2(96, 0)
		default_label.add_theme_font_size_override("font_size", 10)
		default_label.add_theme_color_override("font_color", Color(data.secondary, 0.96))
		row.add_child(default_label)
		var spin := SpinBox.new()
		spin.min_value = INTERACTION_RULES.MIN_CUSTOM_DELTA
		spin.max_value = INTERACTION_RULES.MAX_CUSTOM_DELTA
		spin.step = 0.1
		spin.allow_lesser = false
		spin.allow_greater = false
		spin.value = float(effective.get(stat, defaults.get(stat, 0.0)))
		spin.custom_minimum_size = Vector2(142, 34)
		spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spin.value_changed.connect(func(_value: float):
			_update_developer_dirty_state()
		)
		row.add_child(spin)
		_developer_spinboxes[stat] = spin
		var override_badge := Label.new()
		override_badge.text = "已覆盖" if overrides.has(stat) else "使用默认"
		override_badge.custom_minimum_size = Vector2(68, 0)
		override_badge.add_theme_font_size_override("font_size", 10)
		override_badge.add_theme_color_override(
			"font_color",
			Color(data.accent, 0.96) if overrides.has(stat) else Color(data.secondary, 0.96)
		)
		row.add_child(override_badge)

func _on_developer_role_selected(index: int) -> void:
	if not _ensure_developer_scope_current():
		return
	var role := str(_developer_role_select.get_item_metadata(index))
	if not INTERACTION_RULES.ROLE_MULTIPLIERS.has(role):
		return
	var discarded := _developer_dirty
	_developer_role = role
	_rebuild_developer_delta_rows(ThemeMgr.get_current_theme_data())
	if discarded:
		_set_developer_status("已放弃未保存修改", Color("#D9A441"))
	else:
		_set_developer_neutral_status()

func _on_developer_action_selected(index: int) -> void:
	if not _ensure_developer_scope_current():
		return
	var action := str(_developer_action_select.get_item_metadata(index))
	if not INTERACTION_RULES.has_action(action):
		return
	var discarded := _developer_dirty
	_developer_action = action
	_rebuild_developer_delta_rows(ThemeMgr.get_current_theme_data())
	if discarded:
		_set_developer_status("已放弃未保存修改", Color("#D9A441"))
	else:
		_set_developer_neutral_status()

func _save_current_developer_interaction() -> void:
	if not _ensure_developer_scope_current():
		return
	var values := _collect_developer_values()
	var result := Settings.set_interaction_action_overrides(
		_developer_role,
		_developer_action,
		values
	)
	if bool(result.get("ok", false)):
		_rebuild_developer_delta_rows(ThemeMgr.get_current_theme_data())
	_show_developer_result(result)

func _reset_current_developer_interaction() -> void:
	if not _ensure_developer_scope_current():
		return
	var result := Settings.reset_interaction_action_overrides(
		_developer_role,
		_developer_action
	)
	if bool(result.get("ok", false)):
		_rebuild_developer_delta_rows(ThemeMgr.get_current_theme_data())
	_show_developer_result(result)

func _reset_all_developer_interactions() -> void:
	if not _ensure_developer_scope_current():
		return
	var result := Settings.reset_all_interaction_overrides()
	if bool(result.get("ok", false)):
		_rebuild_developer_delta_rows(ThemeMgr.get_current_theme_data())
	_show_developer_result(result)

func _request_reset_all_developer_interactions() -> void:
	if not _ensure_developer_scope_current():
		return
	_developer_reset_all_dialog.dialog_text = (
		"这会清除当前旅程（%s）中，小玲和小奈的全部互动 delta 覆盖。\n"
		% _short_save_id(_developer_scope_save_id)
		+ "当前未保存的互动数值也会被丢弃。\n"
		+ "只影响之后的新互动，不会回滚现有属性或已保存事件。"
	)
	_developer_reset_all_dialog.popup_centered(Vector2i(540, 220))

func _ensure_developer_scope_current() -> bool:
	var active_save_id := Settings.get_interaction_scope_save_id()
	if active_save_id == _developer_scope_save_id:
		if active_save_id.is_empty():
			_set_developer_status("当前没有已加载旅程，无法保存", Color("#D9534F"))
			return false
		return true
	var discarded_draft := _developer_dirty or _stat_dirty
	var ambient_draft := _collect_ambient_values() if _ambient_dirty else {}
	var runtime_draft := _collect_runtime_values() if _runtime_dirty else {}
	_developer_scope_save_id = active_save_id
	_developer_dirty = false
	_stat_dirty = false
	if _developer_reset_all_dialog.visible:
		_developer_reset_all_dialog.hide()
	_rebuild_content()
	if not ambient_draft.is_empty():
		_restore_ambient_draft(ambient_draft)
	if not runtime_draft.is_empty():
		_apply_runtime_values_to_controls(runtime_draft)
		_update_runtime_dirty_state()
	_set_developer_status(
		(
			"旅程已切换；旧旅程未保存修改已丢弃"
			if discarded_draft
			else "已切换到当前旅程配置"
		),
		Color("#D9A441")
	)
	return false

func _developer_scope_text(save_id: String) -> String:
	if save_id.is_empty():
		return "⚠ 当前没有已加载旅程 · 使用默认互动数值"
	return "仅作用于当前旅程 · ID %s" % _short_save_id(save_id)

func _short_save_id(save_id: String) -> String:
	if save_id.length() <= 12:
		return save_id
	return "%s…%s" % [save_id.left(8), save_id.right(4)]

func _collect_developer_values() -> Dictionary:
	var values := {}
	for stat_variant in _developer_spinboxes:
		var stat := str(stat_variant)
		var spin := _developer_spinboxes[stat] as SpinBox
		if is_instance_valid(spin):
			values[stat] = spin.value
	return values

func _restore_developer_draft(values: Dictionary) -> void:
	for stat_variant in values:
		var stat := str(stat_variant)
		var spin = _developer_spinboxes.get(stat)
		if spin is SpinBox and is_instance_valid(spin):
			(spin as SpinBox).set_value_no_signal(float(values[stat_variant]))
	_update_developer_dirty_state()

func _update_developer_dirty_state() -> void:
	var current := _collect_developer_values()
	_developer_dirty = current.size() != _developer_loaded_values.size()
	if not _developer_dirty:
		for stat_variant in _developer_loaded_values:
			var stat := str(stat_variant)
			if (
				not current.has(stat)
				or not is_equal_approx(
					float(current[stat]),
					float(_developer_loaded_values[stat_variant])
				)
			):
				_developer_dirty = true
				break
	if _developer_dirty:
		_set_developer_status("有未保存修改", Color("#D9A441"))
	else:
		_set_developer_neutral_status()

func _set_developer_neutral_status() -> void:
	var data := ThemeMgr.get_current_theme_data()
	_set_developer_status("尚未修改", Color(data.secondary, 0.96))

func _show_developer_result(result: Dictionary) -> void:
	var ok := bool(result.get("ok", false))
	var message := str(result.get("message", "已完成" if ok else "操作失败"))
	_set_developer_status(message, Color("#4CAF7D") if ok else Color("#D9534F"))

func _set_developer_status(text: String, color: Color) -> void:
	if not is_instance_valid(_developer_status):
		return
	_developer_status.text = text
	_developer_status.add_theme_color_override("font_color", color)

func _updates_to_dictionary(updates: Array) -> Dictionary:
	var result := {}
	for update_variant in updates:
		if not update_variant is Array or update_variant.size() < 2:
			continue
		result[str(update_variant[0])] = float(update_variant[1])
	return result

func _format_delta(value: float) -> String:
	return ("+" if value > 0.0 else "") + "%.1f" % value

func _section_label(text: String, data: Dictionary) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", Color(data.text, 0.84))
	return label

func _color_picker(label_text: String, color: Color, parent: HBoxContainer) -> ColorPickerButton:
	var group := VBoxContainer.new()
	group.add_theme_constant_override("separation", 3)
	parent.add_child(group)
	var label := Label.new()
	label.text = label_text
	label.add_theme_font_size_override("font_size", 11)
	group.add_child(label)
	var picker := ColorPickerButton.new()
	picker.color = color
	picker.custom_minimum_size = Vector2(88, 32)
	picker.edit_alpha = false
	picker.tooltip_text = "%s  #%s" % [label_text, color.to_html(false).to_upper()]
	var data := ThemeMgr.get_current_theme_data()
	var normal := _style(color, Color(data.text, 0.28), 7, 3)
	var hover := normal.duplicate()
	hover.border_color = Color(data.primary)
	var focus := _style(Color(0, 0, 0, 0), Color(data.primary), 7, 0)
	picker.add_theme_stylebox_override("normal", normal)
	picker.add_theme_stylebox_override("hover", hover)
	picker.add_theme_stylebox_override("pressed", hover)
	picker.add_theme_stylebox_override("focus", focus)
	_configure_color_picker(picker, data)
	group.add_child(picker)
	return picker

func _configure_color_picker(button: ColorPickerButton, data: Dictionary) -> void:
	var picker := button.get_picker()
	picker.picker_shape = ColorPicker.SHAPE_HSV_RECTANGLE
	picker.color_modes_visible = false
	picker.sliders_visible = true
	picker.hex_visible = true
	picker.presets_visible = false
	picker.sampler_visible = false
	picker.custom_minimum_size = Vector2(300, 300)

	var popup := button.get_popup()
	popup.transparent_bg = false
	popup.add_theme_stylebox_override("panel", _style(Color(data.bg), Color(data.text, 0.24), 10, 12))
	popup.about_to_popup.connect(func():
		popup.size = Vector2i(324, 340)
	)

func _apply_custom_colors() -> void:
	Settings.set_custom_colors(_bg_picker.color.to_html(false), _primary_picker.color.to_html(false), _accent_picker.color.to_html(false))

func _on_resolution_selected(index: int) -> void:
	var key := str(_resolution_select.get_item_metadata(index))
	Settings.set_resolution(key)

func _on_fullscreen_toggled(enabled: bool) -> void:
	Settings.settings.display.fullscreen = enabled
	Settings.save()
	Settings.apply_display()
	_resolution_select.disabled = enabled

func _on_vsync_toggled(enabled: bool) -> void:
	Settings.settings.display.vsync = enabled
	Settings.save()
	Settings.apply_display()

func _update_readability(data: Dictionary) -> void:
	for child in _readability_row.get_children():
		child.free()
	var ratio := _contrast_ratio(Color(data.bg), Color(data.text))
	var icon := "✅"
	var message := "对比度 %.1f:1 · AAA 级 · 极佳" % ratio
	var status := Color("#4CAF7D")
	if ratio < 3.0:
		icon = "❌"
		message = "对比度 %.1f:1 · 可读性不足！" % ratio
		status = Color("#D9534F")
	elif ratio < 4.5:
		icon = "⚠"
		message = "对比度 %.1f:1 · 建议调整" % ratio
		status = Color("#D9A441")
	elif ratio < 7.0:
		message = "对比度 %.1f:1 · AA 级 · 良好" % ratio
	_readability_panel.add_theme_stylebox_override("panel", _style(Color(status, 0.10), Color(status, 0.35), 10, 9))
	var label := Label.new()
	label.text = icon + "  " + message
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 12)
	_readability_row.add_child(label)
	if ratio < 4.5:
		var optimize := Button.new()
		optimize.text = "智能优化"
		optimize.pressed.connect(func():
			Settings.settings.ui.theme = "amber"
			Settings.save()
			ThemeMgr.apply_theme("amber")
		)
		_readability_row.add_child(optimize)

func _contrast_ratio(a: Color, b: Color) -> float:
	var l1 := _relative_luminance(a)
	var l2 := _relative_luminance(b)
	return (maxf(l1, l2) + 0.05) / (minf(l1, l2) + 0.05)

func _relative_luminance(color: Color) -> float:
	var r := color.r / 12.92 if color.r <= 0.03928 else pow((color.r + 0.055) / 1.055, 2.4)
	var g := color.g / 12.92 if color.g <= 0.03928 else pow((color.g + 0.055) / 1.055, 2.4)
	var b := color.b / 12.92 if color.b <= 0.03928 else pow((color.b + 0.055) / 1.055, 2.4)
	return 0.2126 * r + 0.7152 * g + 0.0722 * b

func _style(background: Color, border: Color, radius: int, margin: int) -> StyleBoxFlat:
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

func _apply_panel_style() -> void:
	var data := ThemeMgr.get_current_theme_data()
	_panel.add_theme_stylebox_override("panel", _style(Color(data.bg, 0.97), Color(data.text, 0.12), 24, 0))
	var material := ShaderMaterial.new()
	material.shader = GLASS_SHADER
	material.set_shader_parameter("tint_color", Color(data.bg))
	material.set_shader_parameter("tint_strength", 0.88)
	material.set_shader_parameter("blur_lod", 3.0)
	_panel.material = material

func _update_panel_size() -> void:
	if _panel:
		var viewport_size := get_viewport_rect().size
		_panel.custom_minimum_size = Vector2(minf(960.0, viewport_size.x - 24.0), minf(720.0, viewport_size.y - 24.0))

func _on_theme_changed(_data: Dictionary) -> void:
	_apply_panel_style()
	if visible:
		call_deferred("_rebuild_content_preserving_developer_draft")

func _rebuild_content_preserving_developer_draft() -> void:
	if not visible:
		return
	_capture_visible_category_draft()
	var active_save_id := Settings.get_interaction_scope_save_id()
	if active_save_id != _developer_scope_save_id:
		_developer_scope_save_id = active_save_id
		_developer_dirty = false
		_stat_dirty = false
		_category_drafts.erase("advanced")
		if _developer_reset_all_dialog.visible:
			_developer_reset_all_dialog.hide()
	_rebuild_content()
	_restore_visible_category_draft()

func _request_close_panel() -> void:
	if _provider_write_in_flight:
		_set_provider_status("请等待模型连接操作完成", Color("#D9A441"))
		return
	if _developer_dirty or _ambient_dirty or _runtime_dirty or _stat_dirty or _has_provider_dirty():
		_developer_discard_dialog.popup_centered(Vector2i(460, 180))
		return
	close_panel()

func _on_scrim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_request_close_panel()

func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		_request_close_panel()
