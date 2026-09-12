extends "res://scenes/Settings/sections/SettingsSectionBase.gd"
## 设置面板 · AI 服务分节：聊天/能力模型配置、备用候选链、网络代理、连接诊断。
## 状态目录加载后经 on_status_loaded 回调把 RAG 配置下推给知识库分节。

const KIT := preload("res://scenes/Settings/sections/SettingsUIKit.gd")

var on_status_loaded: Callable

var _suppress_dirty := false

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
var _provider_request_generation := 0
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
var _provider_clear_target := "chat"
var _provider_capability_focus := "vision"
var _provider_fallback_focus := "chat"


func _prepare() -> void:
	_build_provider_clear_dialog()
	_build_provider_http_confirmation_dialog()


func build(parent: VBoxContainer, data: Dictionary, subcategory: String) -> void:
	_build_ai_provider_section(parent, data, subcategory)


func capture_draft() -> Dictionary:
	return _collect_provider_draft()


func restore_draft(draft: Dictionary) -> void:
	_restore_provider_draft(draft)


func reset_draft_state() -> void:
	_provider_dirty = false
	_provider_profile_dirty.clear()
	_provider_proxy_dirty = false


func reset_for_show(_scope_save_id: String) -> void:
	reset_draft_state()
	_provider_busy = false
	_provider_write_in_flight = false
	_provider_http_confirmation_target = ""
	_provider_request_generation += 1


func cancel_pending_requests() -> void:
	_provider_request_generation += 1
	_provider_busy = false


func is_write_in_flight() -> bool:
	return _provider_write_in_flight


func warn_write_in_flight() -> void:
	_set_provider_status("请等待模型连接操作完成", Color("#D9A441"))


func refresh_status() -> void:
	_refresh_provider_status()


func refresh_status_if_needed() -> void:
	if _provider_status_data.is_empty():
		_refresh_provider_status()


func release_controls() -> void:
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
func _build_provider_clear_dialog() -> void:
	_provider_clear_dialog = ConfirmationDialog.new()
	_provider_clear_dialog.title = "清除已保存的 API Key？"
	_provider_clear_dialog.dialog_text = "这会删除由当前 Windows 用户加密保存的模型密钥。环境变量中的密钥不会被删除。"
	_provider_clear_dialog.ok_button_text = "清除已保存 Key"
	_provider_clear_dialog.cancel_button_text = "取消"
	_provider_clear_dialog.confirmed.connect(_clear_provider_api_key)
	host.add_child(_provider_clear_dialog)


func _build_provider_http_confirmation_dialog() -> void:
	_provider_http_confirmation_dialog = ConfirmationDialog.new()
	_provider_http_confirmation_dialog.title = "允许公网 HTTP 中转？"
	_provider_http_confirmation_dialog.dialog_text = "这个模型地址使用公网 HTTP。继续后，API Key、截图、提示词和模型回复都可能在网络中以明文传输。仅在你信任该中转站和网络链路时继续。"
	_provider_http_confirmation_dialog.ok_button_text = "允许 HTTP 并保存"
	_provider_http_confirmation_dialog.cancel_button_text = "取消"
	_provider_http_confirmation_dialog.confirmed.connect(_confirm_provider_insecure_http)
	_provider_http_confirmation_dialog.canceled.connect(_cancel_provider_insecure_http)
	host.add_child(_provider_http_confirmation_dialog)


func _build_ai_provider_section(parent: VBoxContainer, data: Dictionary, subcategory: String) -> void:
	_provider_profile_controls.clear()
	_provider_fallback_controls.clear()
	parent.add_child(KIT.section_label("AI 模型连接", data))
	var card := PanelContainer.new()
	card.add_theme_stylebox_override(
		"panel",
		KIT.style(Color(data.primary, 0.055), Color(data.text, 0.12), 12, 12)
	)
	parent.add_child(card)
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
	for page_id_variant in pages:
		var page = pages[page_id_variant]
		if page is CanvasItem:
			(page as CanvasItem).visible = str(page_id_variant) == subcategory

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
		var selected_style := KIT.style(Color(data.primary, 0.16), Color(data.primary, 0.62), 7, 5)
		button.add_theme_stylebox_override("normal", selected_style)
		button.add_theme_stylebox_override("pressed", selected_style)
	button.pressed.connect(callback.bind(capability), CONNECT_DEFERRED)
	parent.add_child(button)

func _switch_provider_capability_focus(capability: String) -> void:
	if capability not in CAPABILITY_PROVIDER_UI or capability == _provider_capability_focus:
		return
	capture_category_draft.call()
	_provider_capability_focus = capability
	request_rebuild.call()
	restore_category_draft.call()

func _switch_provider_fallback_focus(capability: String) -> void:
	if capability not in PROVIDER_CAPABILITY_LABELS or capability == _provider_fallback_focus:
		return
	capture_category_draft.call()
	_provider_fallback_focus = capability
	request_rebuild.call()
	restore_category_draft.call()


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
	_suppress_dirty = true
	var mode := _provider_proxy_controls.mode as OptionButton
	for index in mode.item_count:
		if str(mode.get_item_metadata(index)) == str(values.get("mode", "direct")):
			mode.select(index)
			break
	(_provider_proxy_controls.url as LineEdit).text = str(values.get("url", ""))
	_suppress_dirty = false
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
	if _suppress_dirty:
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
	var base_input := KIT.labeled_line_edit(
		grid, "Base URL", str(loaded.get("base_url", definition.base_url)), str(definition.base_url)
	)
	base_input.tooltip_text = "HTTPS 最安全；局域网私有 IP 可使用 HTTP。公网 HTTP 需要勾选“允许 HTTP”。"
	var model_input := KIT.labeled_line_edit(
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
		ling_voice_input = KIT.labeled_line_edit(
			grid, "Voice ID (Ling)", str(saved_voices.get("ling", "")), "default voice or profile ID"
		)
		nai_voice_input = KIT.labeled_line_edit(
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
	KIT.apply_content_readability(box, ThemeMgr.get_current_theme_data())

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
	if _suppress_dirty:
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


func _on_provider_preset_selected(index: int) -> void:
	if index <= 0 or not is_instance_valid(_provider_preset_select):
		return
	var preset = _provider_preset_select.get_item_metadata(index)
	if not preset is Dictionary:
		return
	_suppress_dirty = true
	_provider_base_url_input.text = str((preset as Dictionary).get("base_url", ""))
	_provider_model_input.text = str((preset as Dictionary).get("model", ""))
	_provider_preset_select.select(0)
	_suppress_dirty = false
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
	on_status_loaded.call(_provider_status_data)
	apply_status_data(_provider_status_data)
	if not _provider_dirty:
		_apply_provider_values_to_controls(_provider_loaded_values, "")
	_render_provider_status()
	_sync_provider_buttons()

func apply_status_data(status: Dictionary) -> void:
	var profiles = status.get("profiles", {})
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
	var network_proxy = status.get("network_proxy", {})
	if network_proxy is Dictionary and not (network_proxy as Dictionary).is_empty():
		_provider_proxy_loaded = (network_proxy as Dictionary).duplicate(true)
		if not _provider_proxy_dirty:
			_apply_provider_proxy_values_to_controls(_provider_proxy_loaded)
		_render_provider_proxy_status()
		_sync_provider_proxy_controls()
	var fallback_catalog = status.get("fallbacks", {})
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
	_suppress_dirty = true
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
	_suppress_dirty = false

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
		on_status_loaded.call(_provider_status_data)
		apply_status_data(_provider_status_data)
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
		on_status_loaded.call(_provider_status_data)
		apply_status_data(_provider_status_data)
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
			_suppress_dirty = true
			(controls.api_key as LineEdit).text = str((values as Dictionary).get("api_key", ""))
			_suppress_dirty = false
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


func has_unsaved_changes() -> bool:
	if _provider_dirty or _provider_proxy_dirty:
		return true
	for capability_variant in _provider_profile_dirty:
		if bool(_provider_profile_dirty.get(capability_variant, false)):
			return true
	for capability_variant in _provider_fallback_dirty:
		if bool(_provider_fallback_dirty.get(capability_variant, false)):
			return true
	return false


func _apply_provider_values_to_controls(values: Dictionary, api_key: String) -> void:
	if not is_instance_valid(_provider_base_url_input):
		return
	_suppress_dirty = true
	_provider_base_url_input.text = str(values.get("base_url", ""))
	_provider_model_input.text = str(values.get("model", ""))
	_provider_api_key_input.text = api_key
	_suppress_dirty = false

func _update_provider_dirty_state() -> void:
	if _suppress_dirty or not is_instance_valid(_provider_base_url_input):
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
