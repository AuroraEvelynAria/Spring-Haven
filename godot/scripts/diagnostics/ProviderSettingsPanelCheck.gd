extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	await process_frame
	print("PROVIDER_SETTINGS_PANEL_CHECK stage=instantiate")
	var settings_panel := load("res://scenes/Settings/SettingsPanel.tscn") as PackedScene
	_expect(settings_panel != null, "设置面板场景无法加载")
	var panel := settings_panel.instantiate()
	print("PROVIDER_SETTINGS_PANEL_CHECK stage=add_child")
	root.add_child(panel)
	print("PROVIDER_SETTINGS_PANEL_CHECK stage=show")
	panel.show_panel()
	print("PROVIDER_SETTINGS_PANEL_CHECK stage=inspect")
	_expect(str(panel.get("_settings_category")) == "general", "设置页默认分类不是体验")
	_expect(str(panel.get("_settings_subcategory")) == "appearance", "体验页默认二级分类错误")
	var category_buttons: Dictionary = panel.get("_category_buttons")
	_expect(category_buttons.size() == 5, "设置分类导航不完整")
	_expect((panel.get("_subcategory_buttons") as Dictionary).size() == 3, "体验页二级导航不完整")
	_expect(panel.get("_provider_api_key_input") == null, "体验页仍堆叠显示 AI Provider")
	_expect(panel.get("_diagnostic_bundle_button") == null, "体验页仍堆叠显示开发者诊断入口")

	panel.call("_switch_settings_category", "advanced")
	_expect(str(panel.get("_settings_subcategory")) == "reliability", "高级页默认二级分类错误")
	_expect(panel.get("_diagnostic_bundle_button") is Button, "高级可靠性页缺少脱敏诊断包入口")
	_expect(panel.get("_diagnostic_open_button") is Button, "高级可靠性页缺少诊断目录入口")
	_expect(panel.get("_diagnostic_bundle_status") is Label, "高级可靠性页缺少诊断包状态指示")
	panel.call("_switch_settings_category", "general")

	(category_buttons.get("ai") as Button).pressed.emit()
	await process_frame
	_expect(str(panel.get("_settings_category")) == "ai", "分类按钮的延迟切换没有执行")
	_expect(str(panel.get("_settings_subcategory")) == "chat", "AI 服务默认二级分类错误")
	_expect((panel.get("_subcategory_buttons") as Dictionary).size() == 4, "AI 服务二级导航不完整")

	var key_input := panel.get("_provider_api_key_input") as LineEdit
	var base_input := panel.get("_provider_base_url_input") as LineEdit
	var model_input := panel.get("_provider_model_input") as LineEdit
	var save_button := panel.get("_provider_save_button") as Button
	var clear_button := panel.get("_provider_clear_button") as Button
	_expect(key_input != null, "API Key 输入框不存在")
	_expect(base_input != null and model_input != null, "Provider 地址或模型输入框不存在")
	_expect(save_button != null and clear_button != null, "Provider 操作按钮不存在")
	_expect(key_input.secret, "API Key 输入框默认没有隐藏内容")
	_expect(key_input.text.is_empty(), "设置页不应回填已保存的 API Key")
	_expect(
		panel.get("_adult_user_toggle") == null
		and panel.get("_adult_content_toggle") == null
		and panel.get("_adult_policy_save_button") == null,
		"成人内容开关应已从设置页移除"
	)

	panel.call("_on_provider_preset_selected", 1)
	_expect(base_input.text == "https://api.openai.com/v1", "OpenAI 预设地址错误")
	_expect(model_input.text == "gpt-4.1-mini", "OpenAI 预设模型错误")
	key_input.text = "diagnostic-placeholder-key"
	panel.call("_update_provider_dirty_state")
	_expect(bool(panel.get("_provider_dirty")), "Provider 草稿没有进入未保存状态")
	var profile_controls: Dictionary = panel.get("_provider_profile_controls")
	var tts_controls: Dictionary = profile_controls.get("tts", {})
	_expect(tts_controls.get("voice_ling") is LineEdit, "TTS missing Ling voice ID control")
	_expect(tts_controls.get("voice_nai") is LineEdit, "TTS missing Nai voice ID control")
	_expect(profile_controls.size() == 5, "视觉、嵌入、重排序、语音识别或语音合成配置没有完整创建")
	var fallback_controls: Dictionary = panel.get("_provider_fallback_controls")
	_expect(fallback_controls.size() == 6, "聊天、视觉、嵌入、重排序、语音识别或语音合成候选链编辑器不完整")
	var fallback_drafts: Dictionary = panel.get("_provider_fallback_drafts")
	var original_chat_fallbacks: Array = (fallback_drafts.get("chat", []) as Array).duplicate(true)
	panel.call("_add_provider_fallback_candidate", "chat")
	fallback_drafts = panel.get("_provider_fallback_drafts")
	_expect((fallback_drafts.get("chat", []) as Array).size() == original_chat_fallbacks.size() + 1, "聊天备用候选没有加入草稿")
	_expect(bool((panel.get("_provider_fallback_dirty") as Dictionary).get("chat", false)), "聊天候选链没有进入未保存状态")
	var vision_controls: Dictionary = profile_controls.get("vision", {})
	var vision_key := vision_controls.get("api_key") as LineEdit
	var vision_allow_http := vision_controls.get("allow_insecure_http") as CheckBox
	_expect(vision_allow_http != null and not vision_allow_http.button_pressed, "视觉模型明文 HTTP 开关默认状态错误")
	_expect(
		bool(panel.call("_is_provider_insecure_http_error", "remote HTTP provider requires allow_insecure_http")),
		"公网 HTTP 错误没有触发安全确认"
	)
	_expect(
		str(panel.call("_localized_provider_error", "provider base URL must use http or https")).contains("http://"),
		"Provider 地址错误没有转换为中文提示"
	)
	panel.call("_request_provider_insecure_http_confirmation", "vision")
	var http_dialog := panel.get("_provider_http_confirmation_dialog") as ConfirmationDialog
	_expect(http_dialog != null and http_dialog.visible, "公网 HTTP 安全确认框没有显示")
	_expect(
		str((vision_controls.get("status") as Label).text).contains("公网 HTTP"),
		"公网 HTTP 状态没有给出中文说明"
	)
	http_dialog.hide()
	panel.call("_cancel_provider_insecure_http")
	_expect(vision_key != null and vision_key.secret, "视觉 API Key 没有默认隐藏")
	vision_key.text = "diagnostic-vision-key"
	vision_allow_http.button_pressed = true
	panel.call("_update_provider_profile_dirty", "vision")
	var profile_dirty: Dictionary = panel.get("_provider_profile_dirty")
	_expect(bool(profile_dirty.get("vision", false)), "视觉 Provider 草稿没有进入未保存状态")
	var proxy_controls: Dictionary = panel.get("_provider_proxy_controls")
	_expect(not proxy_controls.is_empty(), "网络代理控件不存在")
	var proxy_mode := proxy_controls.get("mode") as OptionButton
	var proxy_url := proxy_controls.get("url") as LineEdit
	proxy_mode.select(2)
	proxy_url.text = "http://127.0.0.1:7890"
	panel.call("_update_provider_proxy_dirty")
	panel.call("_sync_provider_proxy_url_state")
	_expect(bool(panel.get("_provider_proxy_dirty")), "代理草稿没有进入未保存状态")
	_expect(proxy_url.editable, "自定义代理地址输入框不可编辑")
	panel.call("_switch_settings_subcategory", "network")
	_expect(str(panel.get("_settings_subcategory")) == "network", "AI 网络二级页没有切换")
	panel.call("_switch_settings_subcategory", "chat")
	key_input = panel.get("_provider_api_key_input") as LineEdit
	base_input = panel.get("_provider_base_url_input") as LineEdit
	_expect(key_input.text == "diagnostic-placeholder-key", "AI 二级页切换丢失聊天 Key 草稿")
	_expect(base_input.text == "https://api.openai.com/v1", "AI 二级页切换丢失 Provider 地址草稿")
	profile_controls = panel.get("_provider_profile_controls")
	vision_controls = profile_controls.get("vision", {})
	vision_key = vision_controls.get("api_key") as LineEdit
	_expect(vision_key.text == "diagnostic-vision-key", "AI 二级页切换丢失视觉 Key 草稿")
	var client := root.get_node_or_null("CompanionCore")
	_expect(client != null, "Companion Core 客户端不存在")
	var timeout_message := str(client.call(
		"_http_request_failure_message", HTTPRequest.RESULT_TIMEOUT, "http://127.0.0.1:18340/chat"
	))
	_expect("超时" in timeout_message and "代理" in timeout_message, "错误 13 没有转换成可理解的超时提示")
	_expect(panel.get("_rag_document_title") == null, "AI 页面仍堆叠显示知识库编辑器")

	panel.call("_switch_settings_category", "knowledge")
	var rag_controls: Dictionary = panel.get("_provider_rag_controls")
	_expect(not rag_controls.is_empty(), "RAG 配置控件不存在")
	(rag_controls.get("enabled") as CheckBox).button_pressed = true
	panel.call("_update_provider_rag_dirty")
	_expect(bool(panel.get("_provider_rag_dirty")), "RAG 草稿没有进入未保存状态")
	(panel.get("_rag_document_title") as LineEdit).text = "诊断知识"
	(panel.get("_rag_document_text") as TextEdit).text = "这是一段不会提交到模型的诊断知识。"
	_expect(panel.get("_rag_document_source") is LineEdit, "知识文档来源编辑器不存在")
	_expect(panel.get("_rag_document_filter") is LineEdit, "知识文档筛选框不存在")
	var scope_filter := panel.get("_rag_scope_filter") as OptionButton
	_expect(scope_filter != null, "知识文档作用域分类不存在")
	panel.set("_rag_documents", [
		{"document_id": "shared", "title": "共享资料", "scope": "*", "character_count": 10, "chunk_count": 1},
		{"document_id": "ling-doc", "title": "小玲资料", "scope": "ling", "character_count": 10, "chunk_count": 1},
		{"document_id": "nai-doc", "title": "小奈资料", "scope": "nai", "character_count": 10, "chunk_count": 1},
	])
	panel.call("_select_rag_scope_filter", "ling")
	var document_list := panel.get("_rag_document_list") as VBoxContainer
	_expect(document_list.get_child_count() == 1, "小玲作用域筛选没有隔离其他角色文档")
	var ling_row := document_list.get_child(0) as HBoxContainer
	_expect(ling_row.get_child(0) is CheckBox, "知识文档列表缺少批量选择框")
	_expect((ling_row.get_child(2) as Label).text == "ling · 小玲", "文档列表没有显示原始 ling scope")
	var batch_controls: Dictionary = panel.get("_rag_batch_controls")
	_expect(not batch_controls.is_empty(), "知识库批量操作控件不存在")
	(ling_row.get_child(0) as CheckBox).button_pressed = true
	_expect((panel.get("_rag_selected_document_ids") as Dictionary).has("ling-doc"), "批量选择没有记录文档 ID")
	_expect(panel.get("_rag_url_input") is LineEdit, "网页导入输入框不存在")
	var import_scope := panel.get("_rag_import_scope") as OptionButton
	_expect(import_scope != null, "文件与网页共用的导入作用域不存在")
	import_scope.select(1)
	_expect(str(panel.call("_selected_rag_import_scope")) == "ling", "批量文件导入没有读取仅小玲作用域")
	_expect(panel.get("_rag_search_query") is LineEdit, "检索测试输入框不存在")
	_expect(panel.get("_rag_file_dialog") is FileDialog, "批量文件导入对话框不存在")

	panel.call("_switch_settings_category", "general")
	_expect(panel.get("_rag_document_title") == null, "基础设置页仍显示知识库编辑器")
	panel.call("_switch_settings_category", "ai")
	key_input = panel.get("_provider_api_key_input") as LineEdit
	base_input = panel.get("_provider_base_url_input") as LineEdit
	_expect(key_input.text == "diagnostic-placeholder-key", "分类切换丢失了 API Key 草稿")
	_expect(base_input.text == "https://api.openai.com/v1", "分类切换丢失了 Provider 地址草稿")
	profile_controls = panel.get("_provider_profile_controls")
	vision_controls = profile_controls.get("vision", {})
	vision_key = vision_controls.get("api_key") as LineEdit
	vision_allow_http = vision_controls.get("allow_insecure_http") as CheckBox
	_expect(vision_allow_http.button_pressed, "分类切换丢失视觉模型明文 HTTP 草稿")
	_expect(vision_key.text == "diagnostic-vision-key", "分类切换丢失了视觉 Key 草稿")
	proxy_controls = panel.get("_provider_proxy_controls")
	proxy_mode = proxy_controls.get("mode") as OptionButton
	proxy_url = proxy_controls.get("url") as LineEdit
	_expect(str(proxy_mode.get_item_metadata(proxy_mode.selected)) == "custom", "分类切换丢失代理模式草稿")
	_expect(proxy_url.text == "http://127.0.0.1:7890", "分类切换丢失代理地址草稿")
	fallback_drafts = panel.get("_provider_fallback_drafts")
	_expect((fallback_drafts.get("chat", []) as Array).size() == original_chat_fallbacks.size() + 1, "分类切换丢失候选链草稿")

	panel.call("_switch_settings_category", "knowledge")
	_expect((panel.get("_rag_document_title") as LineEdit).text == "诊断知识", "分类切换丢失了知识文档草稿")
	import_scope = panel.get("_rag_import_scope") as OptionButton
	_expect(str(import_scope.get_item_metadata(import_scope.selected)) == "ling", "分类切换丢失了导入作用域")
	scope_filter = panel.get("_rag_scope_filter") as OptionButton
	_expect(str(scope_filter.get_item_metadata(scope_filter.selected)) == "ling", "分类切换丢失了小玲知识库分类")

	panel.call("_rebuild_content_preserving_developer_draft")
	_expect((panel.get("_rag_document_title") as LineEdit).text == "诊断知识", "主题重建丢失了 RAG 文档草稿")
	panel.call("_switch_settings_category", "ai")
	key_input = panel.get("_provider_api_key_input") as LineEdit
	profile_controls = panel.get("_provider_profile_controls")
	vision_controls = profile_controls.get("vision", {})
	vision_key = vision_controls.get("api_key") as LineEdit
	_expect(key_input.text == "diagnostic-placeholder-key", "知识库主题重建后丢失 AI Key 草稿")
	_expect(key_input.secret and vision_key.secret, "分类重建后 API Key 不再隐藏")

	key_input.text = ""
	vision_key.text = ""
	(panel.get("_provider_fallback_drafts") as Dictionary)["chat"] = original_chat_fallbacks
	(panel.get("_provider_fallback_dirty") as Dictionary)["chat"] = false
	panel.call("_switch_settings_category", "knowledge")
	(panel.get("_rag_document_text") as TextEdit).text = ""
	(panel.get("_rag_document_title") as LineEdit).text = ""
	print("PROVIDER_SETTINGS_PANEL_CHECK=PASS")
	quit(0)

func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	push_error(message)
	quit(1)
