class_name JourneyLibraryPanel
extends Control

signal journey_selected(save_id: String)
signal new_journey_requested(display_name: String)

const CONVERSATION_ARCHIVE := preload("res://scripts/domain/ConversationArchive.gd")

var _scrim: ColorRect
var _panel: PanelContainer
var _rows: VBoxContainer
var _title: Label
var _close_button: Button
var _search_input: LineEdit
var _show_archived: CheckBox
var _status: Label
var _rename_dialog: ConfirmationDialog
var _rename_input: LineEdit
var _rename_save_id := ""
var _archive_dialog: ConfirmationDialog
var _archive_save_id := ""
var _new_dialog: ConfirmationDialog
var _new_name_input: LineEdit


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_shell()
	_build_dialogs()
	get_viewport().size_changed.connect(_update_panel_size)
	Global.save_catalog_changed.connect(_refresh_rows)
	Global.theme_changed.connect(_on_theme_changed)
	hide()


func show_panel() -> void:
	_refresh_rows()
	show()
	modulate.a = 0.0
	_panel.scale = Vector2(0.98, 0.98)
	_panel.pivot_offset = _panel.size * 0.5
	var tween := create_tween().set_parallel(true)
	tween.tween_property(self, "modulate:a", 1.0, 0.18)
	tween.tween_property(_panel, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_CUBIC)


func close_panel() -> void:
	hide()


func _build_shell() -> void:
	_scrim = ColorRect.new()
	_scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scrim.color = Color(0, 0, 0, 0.58)
	_scrim.gui_input.connect(_on_scrim_input)
	add_child(_scrim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(900, 620)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(_panel)
	_apply_panel_style()

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 22)
	margin.add_theme_constant_override("margin_right", 22)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 18)
	_panel.add_child(margin)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 11)
	margin.add_child(content)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	content.add_child(header)
	_title = Label.new()
	_title.text = "📚 旅程档案"
	_title.add_theme_font_size_override("font_size", 20)
	header.add_child(_title)
	var header_spacer := Control.new()
	header_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(header_spacer)
	_close_button = Button.new()
	_close_button.text = "✕"
	_close_button.flat = true
	_close_button.tooltip_text = "关闭"
	_close_button.custom_minimum_size = Vector2(36, 36)
	_close_button.pressed.connect(close_panel)
	header.add_child(_close_button)

	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 8)
	content.add_child(toolbar)
	_search_input = LineEdit.new()
	_search_input.placeholder_text = "搜索旅程名称…"
	_search_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search_input.text_changed.connect(func(_value: String): _refresh_rows())
	toolbar.add_child(_search_input)
	_show_archived = CheckBox.new()
	_show_archived.text = "显示已归档"
	_show_archived.toggled.connect(func(_enabled: bool): _refresh_rows())
	toolbar.add_child(_show_archived)
	var new_button := Button.new()
	new_button.text = "＋ 新建旅程"
	new_button.custom_minimum_size = Vector2(132, 36)
	new_button.pressed.connect(_request_new_journey)
	toolbar.add_child(new_button)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(scroll)
	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override("separation", 8)
	scroll.add_child(_rows)

	_status = Label.new()
	_status.text = ""
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 11)
	content.add_child(_status)
	_apply_control_colors()
	_update_panel_size()


func _build_dialogs() -> void:
	_new_dialog = ConfirmationDialog.new()
	_new_dialog.title = "新建旅程"
	_new_dialog.ok_button_text = "创建并进入"
	_new_dialog.cancel_button_text = "取消"
	_new_name_input = LineEdit.new()
	_new_name_input.placeholder_text = "旅程名称，例如：和小玲小奈的家"
	_new_name_input.max_length = 48
	_new_name_input.custom_minimum_size = Vector2(430, 38)
	_new_dialog.get_label().get_parent().add_child(_new_name_input)
	_new_dialog.confirmed.connect(_confirm_new_journey)
	add_child(_new_dialog)

	_rename_dialog = ConfirmationDialog.new()
	_rename_dialog.title = "重命名旅程"
	_rename_dialog.ok_button_text = "保存名称"
	_rename_dialog.cancel_button_text = "取消"
	_rename_input = LineEdit.new()
	_rename_input.max_length = 48
	_rename_input.custom_minimum_size = Vector2(430, 38)
	_rename_dialog.get_label().get_parent().add_child(_rename_input)
	_rename_dialog.confirmed.connect(_confirm_rename)
	add_child(_rename_dialog)

	_archive_dialog = ConfirmationDialog.new()
	_archive_dialog.title = "归档旅程？"
	_archive_dialog.dialog_text = "旅程文件、聊天归档和心织记忆都会保留，可随时恢复。"
	_archive_dialog.ok_button_text = "归档"
	_archive_dialog.cancel_button_text = "取消"
	_archive_dialog.confirmed.connect(_confirm_archive)
	add_child(_archive_dialog)


func _refresh_rows() -> void:
	if not is_instance_valid(_rows):
		return
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	var query := _search_input.text.strip_edges().to_lower() if is_instance_valid(_search_input) else ""
	var slots := Global.list_save_slots(bool(_show_archived.button_pressed) if is_instance_valid(_show_archived) else false)
	var visible_count := 0
	for slot in slots:
		if not query.is_empty() and query not in str(slot.get("display_name", "")).to_lower():
			continue
		_build_slot_row(slot)
		visible_count += 1
	var recoverable := Global.list_recoverable_journeys()
	if not recoverable.is_empty():
		var separator := HSeparator.new()
		_rows.add_child(separator)
		var recovery_heading := Label.new()
		recovery_heading.text = "🧵 可恢复的旧旅程"
		recovery_heading.add_theme_font_size_override("font_size", 13)
		recovery_heading.add_theme_color_override("font_color", Color(ThemeMgr.get_current_theme_data().primary))
		_rows.add_child(recovery_heading)
		for summary in recoverable:
			_build_recovery_row(summary)
	if visible_count == 0 and recoverable.is_empty():
		var empty := Label.new()
		empty.text = "还没有匹配的旅程。"
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.add_theme_color_override("font_color", Color(ThemeMgr.get_current_theme_data().secondary, 0.96))
		_rows.add_child(empty)
	_set_status("%d 个旅程%s" % [slots.size(), " · %d 个可恢复" % recoverable.size() if not recoverable.is_empty() else ""])


func _build_slot_row(slot: Dictionary) -> void:
	var data := ThemeMgr.get_current_theme_data()
	var card := PanelContainer.new()
	card.add_theme_stylebox_override(
		"panel", _style(Color(data.text, 0.025), Color(data.text, 0.11), 8, 10)
	)
	_rows.add_child(card)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 9)
	card.add_child(row)
	var icon := Label.new()
	icon.text = "🌸" if bool(slot.get("active", false)) else "📖"
	icon.add_theme_font_size_override("font_size", 20)
	row.add_child(icon)
	var details := VBoxContainer.new()
	details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	details.add_theme_constant_override("separation", 2)
	row.add_child(details)
	var name := Label.new()
	name.text = str(slot.get("display_name", "未命名旅程"))
	name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name.add_theme_font_size_override("font_size", 14)
	name.add_theme_color_override("font_color", Color(data.text))
	details.add_child(name)
	var metadata := Label.new()
	var recovery := " · 部分恢复" if str(slot.get("recovery_kind", "complete")) == "conversation_only" else ""
	metadata.text = "%s · %d 条归档消息%s%s" % [
		CONVERSATION_ARCHIVE.format_local_timestamp(int(slot.get("updated_at", 0))),
		int(slot.get("message_count", 0)),
		recovery,
		" · 已归档" if bool(slot.get("archived", false)) else "",
	]
	metadata.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	metadata.add_theme_font_size_override("font_size", 12)
	metadata.add_theme_color_override("font_color", Color(data.secondary, 0.96))
	details.add_child(metadata)
	var slot_id := str(slot.get("save_id", ""))
	if bool(slot.get("archived", false)):
		var restore := Button.new()
		restore.text = "↩"
		restore.tooltip_text = "恢复旅程"
		restore.custom_minimum_size = Vector2(38, 34)
		restore.pressed.connect(func(): _restore_slot(slot_id), CONNECT_DEFERRED)
		row.add_child(restore)
		return
	var load_button := Button.new()
	load_button.text = "继续" if bool(slot.get("active", false)) else "载入"
	load_button.custom_minimum_size = Vector2(74, 34)
	load_button.disabled = not bool(slot.get("file_available", false))
	load_button.pressed.connect(func(): _select_slot(slot_id), CONNECT_DEFERRED)
	row.add_child(load_button)
	var rename := Button.new()
	rename.text = "✎"
	rename.tooltip_text = "重命名"
	rename.custom_minimum_size = Vector2(38, 34)
	rename.pressed.connect(
		func(): _request_rename(slot_id, str(slot.get("display_name", ""))),
		CONNECT_DEFERRED
	)
	row.add_child(rename)
	var archive := Button.new()
	archive.text = "🗄"
	archive.tooltip_text = "归档"
	archive.custom_minimum_size = Vector2(38, 34)
	archive.disabled = bool(slot.get("active", false))
	archive.pressed.connect(func(): _request_archive(slot_id), CONNECT_DEFERRED)
	row.add_child(archive)


func _build_recovery_row(summary: Dictionary) -> void:
	var data := ThemeMgr.get_current_theme_data()
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_rows.add_child(row)
	var details := Label.new()
	details.text = "%s · %d 条消息 · 属性和日程将使用默认值" % [
		CONVERSATION_ARCHIVE.format_local_timestamp(int(summary.get("updated_at", 0))),
		int(summary.get("message_count", 0)),
	]
	details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	details.add_theme_color_override("font_color", Color(data.text, 0.88))
	row.add_child(details)
	var recover := Button.new()
	recover.text = "恢复"
	recover.custom_minimum_size = Vector2(76, 34)
	var recovery_id := str(summary.get("save_id", ""))
	recover.pressed.connect(func(): _recover_journey(recovery_id), CONNECT_DEFERRED)
	row.add_child(recover)


func _select_slot(slot_id: String) -> void:
	hide()
	journey_selected.emit(slot_id)


func _request_new_journey() -> void:
	_new_name_input.text = ""
	_new_dialog.popup_centered(Vector2i(_dialog_width(500), 170))
	_new_name_input.call_deferred("grab_focus")


func _confirm_new_journey() -> void:
	hide()
	new_journey_requested.emit(_new_name_input.text.strip_edges())


func _request_rename(slot_id: String, current_name: String) -> void:
	_rename_save_id = slot_id
	_rename_input.text = current_name
	_rename_dialog.popup_centered(Vector2i(_dialog_width(500), 170))
	_rename_input.call_deferred("select_all")
	_rename_input.call_deferred("grab_focus")


func _confirm_rename() -> void:
	var result: Dictionary = Global.rename_save_slot(_rename_save_id, _rename_input.text)
	_set_status(str(result.get("message", "重命名失败")), bool(result.get("ok", false)))
	_refresh_rows()


func _request_archive(slot_id: String) -> void:
	_archive_save_id = slot_id
	_archive_dialog.popup_centered(Vector2i(_dialog_width(480), 190))


func _confirm_archive() -> void:
	var result: Dictionary = Global.set_save_slot_archived(_archive_save_id, true)
	_set_status(str(result.get("message", "归档失败")), bool(result.get("ok", false)))
	_refresh_rows()


func _restore_slot(slot_id: String) -> void:
	var result: Dictionary = Global.set_save_slot_archived(slot_id, false)
	_set_status(str(result.get("message", "恢复失败")), bool(result.get("ok", false)))
	_refresh_rows()


func _recover_journey(slot_id: String) -> void:
	var result: Dictionary = Global.recover_archived_journey(slot_id)
	_set_status(str(result.get("message", "恢复失败")), bool(result.get("ok", false)))
	_refresh_rows()


func _set_status(text: String, success := true) -> void:
	if not is_instance_valid(_status):
		return
	_status.text = text
	_status.add_theme_color_override(
		"font_color",
		Color(ThemeMgr.get_current_theme_data().text, 0.74) if success else Color("#D9534F")
	)


func _on_scrim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		close_panel()


func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close_panel()


func _on_theme_changed(_data: Dictionary) -> void:
	_apply_panel_style()
	_apply_control_colors()
	_refresh_rows()


func _apply_panel_style() -> void:
	if not is_instance_valid(_panel):
		return
	var data := ThemeMgr.get_current_theme_data()
	_panel.add_theme_stylebox_override(
		"panel", _style(Color(data.bg, 0.98), Color(data.text, 0.14), 8, 0)
	)


func _apply_control_colors() -> void:
	var data := ThemeMgr.get_current_theme_data()
	if is_instance_valid(_title):
		_title.add_theme_color_override("font_color", Color(data.text))
	if is_instance_valid(_close_button):
		for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
			_close_button.add_theme_color_override(state, Color(data.text))
	if is_instance_valid(_show_archived):
		_show_archived.add_theme_color_override("font_color", Color(data.text, 0.88))
		_show_archived.add_theme_color_override("font_hover_color", Color(data.primary))
	if is_instance_valid(_search_input):
		_search_input.add_theme_color_override("font_color", Color(data.text))
		_search_input.add_theme_color_override("font_placeholder_color", Color(data.text, 0.62))
		_search_input.add_theme_color_override("caret_color", Color(data.primary))
	if is_instance_valid(_status):
		_status.add_theme_color_override("font_color", Color(data.text, 0.74))


func _update_panel_size() -> void:
	if not is_instance_valid(_panel):
		return
	var viewport := get_viewport_rect().size
	_panel.custom_minimum_size = Vector2(
		minf(920.0, viewport.x - 24.0),
		minf(660.0, viewport.y - 24.0)
	)


func _dialog_width(preferred: int) -> int:
	return mini(preferred, maxi(320, int(get_viewport_rect().size.x) - 32))


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
