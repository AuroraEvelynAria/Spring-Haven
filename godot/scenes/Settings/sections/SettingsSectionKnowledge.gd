extends "res://scenes/Settings/sections/SettingsSectionBase.gd"
## 设置面板 · 知识库分节：RAG 检索设置、文档管理、文档编辑器、检索测试。
## _provider_busy / _provider_write_in_flight 由根脚本（Provider 域）持有，
## 本节经 host 动态读写，等待 Provider 节拆分后再收敛为共享上下文。

const KIT := preload("res://scenes/Settings/sections/SettingsUIKit.gd")

var _suppress_dirty := false

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

var _provider_rag_controls: Dictionary = {}
var _provider_rag_loaded: Dictionary = {}
var _provider_rag_dirty := false


func _prepare() -> void:
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
	host.add_child(_rag_file_dialog)
	_rag_delete_dialog = ConfirmationDialog.new()
	_rag_delete_dialog.title = "删除知识文档？"
	_rag_delete_dialog.dialog_text = "文档与全部检索分块将被永久删除。"
	_rag_delete_dialog.ok_button_text = "删除文档"
	_rag_delete_dialog.cancel_button_text = "取消"
	_rag_delete_dialog.confirmed.connect(_confirm_delete_rag_document)
	host.add_child(_rag_delete_dialog)


func build(parent: VBoxContainer, data: Dictionary, subcategory: String) -> void:
	parent.add_child(KIT.section_label("知识库与检索", data))
	var introduction := Label.new()
	introduction.text = "文档保存在独立 SQLite 中，可按角色隔离；聊天时只注入检索命中的只读片段，不会破坏稳定提示词缓存。"
	introduction.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	introduction.add_theme_font_size_override("font_size", 11)
	introduction.add_theme_color_override("font_color", Color(data.secondary, 0.96))
	parent.add_child(introduction)
	var card := PanelContainer.new()
	card.add_theme_stylebox_override(
		"panel", KIT.style(Color(data.primary, 0.055), Color(data.text, 0.12), 12, 12)
	)
	parent.add_child(card)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 9)
	card.add_child(column)
	_build_rag_editor(column, data, subcategory)
	_refresh_rag_library.call_deferred()


func apply_status_data(status: Dictionary) -> void:
	var rag = status.get("rag", {})
	if rag is Dictionary and not (rag as Dictionary).is_empty():
		_provider_rag_loaded = (rag as Dictionary).duplicate(true)
		if not _provider_rag_dirty:
			_apply_provider_rag_values_to_controls(_provider_rag_loaded)
		_render_provider_rag_status()
		_sync_provider_rag_button()


func capture_draft() -> Dictionary:
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


func restore_draft(draft: Dictionary) -> void:
	if draft.is_empty() or not is_instance_valid(_rag_document_title):
		return
	var rag = draft.get("rag", {})
	if rag is Dictionary and not (rag as Dictionary).is_empty():
		_apply_provider_rag_values_to_controls(rag as Dictionary)
		_update_provider_rag_dirty()
	_suppress_dirty = true
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
	_suppress_dirty = false
	_rag_document_dirty = bool(draft.get("document_dirty", false))
	if _rag_document_dirty:
		_set_rag_document_message("有未保存的文档修改", Color("#D9A441"))
	_render_rag_document_list()


func has_unsaved_changes() -> bool:
	return _provider_rag_dirty or _rag_document_dirty


func reset_draft_state() -> void:
	_provider_rag_dirty = false
	_rag_document_dirty = false


func reset_for_show(_scope_save_id: String) -> void:
	reset_draft_state()
	_rag_operation_busy = false


func release_controls() -> void:
	_provider_rag_controls.clear()
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

func _build_rag_editor(parent: VBoxContainer, data: Dictionary, subcategory: String) -> void:
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
	var top_k := KIT.rag_spin(grid, "注入片段数", loaded.get("top_k", 6), 1, 20)
	var candidates := KIT.rag_spin(grid, "候选片段数", loaded.get("candidate_limit", 24), 4, 100)
	var chunk_size := KIT.rag_spin(grid, "分块字符数", loaded.get("chunk_size", 900), 200, 4000)
	var overlap := KIT.rag_spin(grid, "重叠字符数", loaded.get("chunk_overlap", 120), 0, 1000)
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
		"panel", KIT.style(Color(data.bg, 0.34), Color(data.text, 0.09), 9, 7)
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
	for page_id_variant in pages:
		var page = pages[page_id_variant]
		if page is CanvasItem:
			(page as CanvasItem).visible = str(page_id_variant) == subcategory

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
	if _rag_operation_busy or not is_panel_category.call("knowledge"):
		return
	_rag_operation_busy = true
	_set_rag_library_message("正在读取知识库…", Color(ThemeMgr.get_current_theme_data().secondary, 0.96))
	var status_result: Dictionary = await CompanionCore.get_rag_status()
	var documents_result: Dictionary = await CompanionCore.list_rag_documents(500)
	_rag_operation_busy = false
	if not is_panel_category.call("knowledge"):
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
	if _suppress_dirty:
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
	_suppress_dirty = true
	_rag_document_id = str(document.get("document_id", ""))
	_rag_document_title.text = str(document.get("title", ""))
	_rag_document_text.text = str(document.get("text", ""))
	_rag_document_source.text = str(document.get("source_uri", ""))
	_select_rag_scope(_rag_document_scope, str(document.get("scope", "*")))
	_suppress_dirty = false
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
	if _suppress_dirty:
		return
	_provider_rag_dirty = _collect_provider_rag_values() != _rag_loaded_or_default()
	_render_provider_rag_status()
	_sync_provider_rag_button()

func _save_provider_rag() -> void:
	if host._provider._provider_busy:
		return
	var values := _collect_provider_rag_values()
	host._provider._provider_busy = true
	host._provider._provider_write_in_flight = true
	_set_provider_rag_status("正在保存 RAG 配置…", Color(ThemeMgr.get_current_theme_data().primary))
	var result: Dictionary = await CompanionCore.configure_rag(values)
	host._provider._provider_busy = false
	host._provider._provider_write_in_flight = false
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
		(_provider_rag_controls.save as Button).disabled = host._provider._provider_busy or not _provider_rag_dirty

func _import_rag_document() -> void:
	if host._provider._provider_busy or _rag_operation_busy:
		return
	var title := _rag_document_title.text.strip_edges()
	var content := _rag_document_text.text.strip_edges()
	if title.is_empty() or content.is_empty():
		_rag_document_status.text = "请填写标题和知识正文"
		_rag_document_status.add_theme_color_override("font_color", Color("#D9534F"))
		return
	_rag_operation_busy = true
	host._provider._provider_write_in_flight = true
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
	host._provider._provider_write_in_flight = false
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

func _apply_provider_rag_values_to_controls(values: Dictionary) -> void:
	if _provider_rag_controls.is_empty():
		return
	_suppress_dirty = true
	(_provider_rag_controls.enabled as CheckBox).button_pressed = bool(values.get("enabled", false))
	(_provider_rag_controls.use_embeddings as CheckBox).button_pressed = bool(values.get("use_embeddings", true))
	(_provider_rag_controls.use_rerank as CheckBox).button_pressed = bool(values.get("use_rerank", false))
	(_provider_rag_controls.top_k as SpinBox).value = float(values.get("top_k", 6))
	(_provider_rag_controls.candidate_limit as SpinBox).value = float(values.get("candidate_limit", 24))
	(_provider_rag_controls.chunk_size as SpinBox).value = float(values.get("chunk_size", 900))
	(_provider_rag_controls.chunk_overlap as SpinBox).value = float(values.get("chunk_overlap", 120))
	_suppress_dirty = false
