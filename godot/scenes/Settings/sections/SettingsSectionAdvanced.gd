extends "res://scenes/Settings/sections/SettingsSectionBase.gd"
## 设置面板 · 高级/生活分节：Core 可靠性与备份、脱敏诊断包、当前旅程属性、
## 运行参数、互动数值覆盖、后台生活（life 类别 autonomy 子页）。

const KIT := preload("res://scenes/Settings/sections/SettingsUIKit.gd")
const RUNTIME_TUNING := preload("res://scripts/domain/DeveloperRuntimeTuning.gd")
const INTERACTION_RULES := preload("res://scripts/domain/InteractionRules.gd")
const PLAYTEST_DIAGNOSTICS := preload("res://scripts/domain/PlaytestDiagnostics.gd")
const DEVELOPER_ROLES := ["ling", "nai"]
const STAT_LABELS := {
	"health": "健康", "stamina": "体力", "hunger": "饥饿", "thirst": "口渴",
	"awake": "清醒", "urine": "尿液", "intimacy": "好感度", "mood": "心情",
	"stress": "压力", "fertility": "内膜容受性", "implantation": "服药后着床倾向"
}

var _active_page := ""
var _developer_reset_all_dialog: ConfirmationDialog

var _maintenance_status_label: Label
var _maintenance_run_button: Button
var _maintenance_backup_list: VBoxContainer
var _maintenance_backup_status: Label
var _diagnostic_bundle_button: Button
var _diagnostic_open_button: Button
var _diagnostic_bundle_status: Label
var _last_diagnostic_bundle_path := ""

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

var _developer_role_select: OptionButton
var _developer_action_select: OptionButton
var _developer_delta_rows: VBoxContainer
var _developer_status: Label
var _developer_scope_label: Label
var _developer_spinboxes: Dictionary = {}
var _developer_role := "ling"
var _developer_action := "hug"
var _developer_scope_save_id := ""
var _developer_dirty := false
var _developer_loaded_values: Dictionary = {}

var _ambient_controls: Dictionary = {}
var _ambient_status: Label
var _ambient_dirty := false
var _ambient_loaded_values: Dictionary = {}


func _prepare() -> void:
	_developer_reset_all_dialog = ConfirmationDialog.new()
	_developer_reset_all_dialog.title = "恢复当前旅程的全部互动默认值"
	_developer_reset_all_dialog.ok_button_text = "全部恢复默认"
	_developer_reset_all_dialog.cancel_button_text = "取消"
	_developer_reset_all_dialog.confirmed.connect(_reset_all_developer_interactions)
	host.add_child(_developer_reset_all_dialog)


func build_advanced_page(parent: VBoxContainer, data: Dictionary, subcategory: String) -> void:
	_active_page = "advanced"
	_add_page_block(parent, subcategory == "reliability", func(): _build_core_reliability_section(parent, data))
	_add_page_block(parent, subcategory == "state", func(): _build_current_stats_editor(parent, data))
	_add_page_block(parent, subcategory == "runtime", func(): _build_developer_runtime_section(parent, data, false))
	_add_page_block(parent, subcategory == "interaction", func(): _build_developer_interaction_section(parent, data))


func build_life_ambient_page(parent: VBoxContainer, data: Dictionary, subcategory: String) -> void:
	_active_page = "life"
	_add_page_block(parent, subcategory == "autonomy", func(): _build_developer_ambient_section(parent, data))


func _add_page_block(parent: VBoxContainer, visible_now: bool, builder: Callable) -> void:
	var start := parent.get_child_count()
	builder.call()
	for index in range(start, parent.get_child_count()):
		(parent.get_child(index) as CanvasItem).visible = visible_now


func capture_draft() -> Dictionary:
	match _active_page:
		"life":
			return {"ambient": _collect_ambient_values()}
		"advanced":
			return {
				"runtime": _collect_runtime_values(),
				"stats": _collect_current_stats(),
				"stat_role": _stat_role,
				"interaction_values": _collect_developer_values(),
				"interaction_role": _developer_role,
				"interaction_action": _developer_action,
			}
	return {}


func restore_draft(draft: Dictionary) -> void:
	if draft.is_empty():
		return
	match _active_page:
		"life":
			var ambient = draft.get("ambient", {})
			if ambient is Dictionary:
				_restore_ambient_draft(ambient as Dictionary)
		"advanced":
			var runtime = draft.get("runtime", {})
			if runtime is Dictionary:
				_apply_runtime_values_to_controls(runtime as Dictionary)
				_update_runtime_dirty_state()
			var stats = draft.get("stats", {})
			if stats is Dictionary:
				for stat_variant in stats:
					var stat := str(stat_variant)
					if _stat_controls.has(stat):
						(_stat_controls[stat] as SpinBox).set_value_no_signal(float((stats as Dictionary)[stat_variant]))
				_update_stat_dirty_state()
			var values = draft.get("interaction_values", {})
			if values is Dictionary:
				_restore_developer_draft(values as Dictionary)


func has_unsaved_changes() -> bool:
	return _developer_dirty or _ambient_dirty or _runtime_dirty or _stat_dirty


func reset_draft_state() -> void:
	_developer_dirty = false
	_ambient_dirty = false
	_runtime_dirty = false
	_stat_dirty = false


func reset_for_show(scope_save_id: String) -> void:
	_developer_scope_save_id = scope_save_id
	reset_draft_state()


func release_controls() -> void:
	_maintenance_status_label = null
	_maintenance_run_button = null
	_maintenance_backup_list = null
	_maintenance_backup_status = null
	_diagnostic_bundle_button = null
	_diagnostic_open_button = null
	_diagnostic_bundle_status = null
	_runtime_controls.clear()
	_runtime_status = null
	_runtime_group_reset_buttons.clear()
	_stat_role_select = null
	_stat_controls.clear()
	_stat_status = null
	_developer_role_select = null
	_developer_action_select = null
	_developer_delta_rows = null
	_developer_status = null
	_developer_scope_label = null
	_developer_spinboxes.clear()
	_ambient_controls.clear()
	_ambient_status = null


func handle_scope_change(active_save_id: String) -> bool:
	if active_save_id == _developer_scope_save_id:
		return false
	_developer_scope_save_id = active_save_id
	_developer_dirty = false
	_stat_dirty = false
	if is_instance_valid(_developer_reset_all_dialog) and _developer_reset_all_dialog.visible:
		_developer_reset_all_dialog.hide()
	return true


func _build_core_reliability_section(parent: VBoxContainer, data: Dictionary) -> void:
	parent.add_child(KIT.section_label("Companion Core 与数据可靠性", data))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)
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
	parent.add_child(_maintenance_backup_status)
	_maintenance_backup_list = VBoxContainer.new()
	_maintenance_backup_list.add_theme_constant_override("separation", 5)
	parent.add_child(_maintenance_backup_list)
	var diagnostics_row := HBoxContainer.new()
	diagnostics_row.add_theme_constant_override("separation", 10)
	parent.add_child(diagnostics_row)
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
	parent.add_child(_diagnostic_bundle_status)
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

func _build_developer_runtime_section(parent: VBoxContainer, data: Dictionary, include_current_stats := true) -> void:
	parent.add_child(KIT.section_label("开发者 · 运行参数", data))
	var notice := Label.new()
	notice.text = "运行参数全局保存并即时生效；当前属性只写入正在使用的旅程。"
	notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	notice.add_theme_font_size_override("font_size", 11)
	notice.add_theme_color_override("font_color", Color(data.secondary, 0.96))
	parent.add_child(notice)

	_runtime_loaded_values = Settings.get_runtime_tuning()
	_runtime_controls.clear()
	_runtime_group_reset_buttons.clear()
	if include_current_stats:
		_build_current_stats_editor(parent, data)
	for group_variant in RUNTIME_TUNING.GROUPS:
		var group: Dictionary = group_variant
		var group_id := str(group.id)
		var heading := HBoxContainer.new()
		heading.add_theme_constant_override("separation", 8)
		parent.add_child(heading)
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
		parent.add_child(grid)
		for key in RUNTIME_TUNING.specs_for_group(group_id):
			_add_runtime_control(grid, key, data)

	var command_row := HBoxContainer.new()
	command_row.add_theme_constant_override("separation", 8)
	parent.add_child(command_row)
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

func _build_current_stats_editor(parent: VBoxContainer, data: Dictionary) -> void:
	var heading := HBoxContainer.new()
	heading.add_theme_constant_override("separation", 8)
	parent.add_child(heading)
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
	parent.add_child(commands)
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
	parent.add_child(grid)
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
	parent.add_child(_stat_status)
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

func _build_developer_interaction_section(parent: VBoxContainer, data: Dictionary) -> void:
	parent.add_child(KIT.section_label("开发者 · 互动数值", data))
	_developer_scope_label = Label.new()
	_developer_scope_label.text = _developer_scope_text(_developer_scope_save_id)
	_developer_scope_label.tooltip_text = (
		"完整旅程 ID：%s" % _developer_scope_save_id
		if not _developer_scope_save_id.is_empty()
		else "当前没有可用的已加载旅程"
	)
	_developer_scope_label.add_theme_font_size_override("font_size", 11)
	_developer_scope_label.add_theme_color_override("font_color", Color(data.accent, 0.92))
	parent.add_child(_developer_scope_label)
	var notice := PanelContainer.new()
	notice.add_theme_stylebox_override(
		"panel",
		KIT.style(Color(data.accent, 0.08), Color(data.accent, 0.28), 10, 9)
	)
	parent.add_child(notice)
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
	parent.add_child(selectors)
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
	parent.add_child(_developer_delta_rows)
	_rebuild_developer_delta_rows(data)

	var command_row := HBoxContainer.new()
	command_row.add_theme_constant_override("separation", 8)
	parent.add_child(command_row)
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

func _build_developer_ambient_section(parent: VBoxContainer, data: Dictionary) -> void:
	parent.add_child(KIT.section_label("开发者 · 后台生活", data))
	var notice := Label.new()
	notice.text = (
		"两位角色只会在玩家空闲后互聊；时间配置为全局设置。"
		+ "关闭记忆整理时，对话仍保留在当前旅程聊天记录中，但不会交给 Heartloom。"
	)
	notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	notice.add_theme_font_size_override("font_size", 11)
	notice.add_theme_color_override("font_color", Color(data.secondary, 0.96))
	parent.add_child(notice)

	_ambient_loaded_values = Settings.get_ambient_dialogue_settings()
	_ambient_controls.clear()
	_add_ambient_toggle(
		parent,
		"enabled",
		"允许小玲和小奈在后台自然聊天",
		bool(_ambient_loaded_values.enabled),
		data
	)
	_add_ambient_number(
		parent,
		"idle_minutes", "玩家空闲多久后允许互聊", int(_ambient_loaded_values.idle_minutes),
		Settings.AMBIENT_IDLE_MINUTES_MIN, Settings.AMBIENT_IDLE_MINUTES_MAX, " 分钟", data
	)
	_add_ambient_number(
		parent,
		"cooldown_min_minutes", "两次互聊最短间隔", int(_ambient_loaded_values.cooldown_min_minutes),
		Settings.AMBIENT_COOLDOWN_MINUTES_MIN, Settings.AMBIENT_COOLDOWN_MINUTES_MAX, " 分钟", data
	)
	_add_ambient_number(
		parent,
		"cooldown_max_minutes", "两次互聊最长间隔", int(_ambient_loaded_values.cooldown_max_minutes),
		Settings.AMBIENT_COOLDOWN_MINUTES_MIN, Settings.AMBIENT_COOLDOWN_MINUTES_MAX, " 分钟", data
	)
	_add_ambient_number(
		parent,
		"turns_min", "每次互聊最少消息数", int(_ambient_loaded_values.turns_min),
		Settings.AMBIENT_TURNS_MIN, Settings.AMBIENT_TURNS_MAX, " 条", data
	)
	_add_ambient_number(
		parent,
		"turns_max", "每次互聊最多消息数", int(_ambient_loaded_values.turns_max),
		Settings.AMBIENT_TURNS_MIN, Settings.AMBIENT_TURNS_MAX, " 条", data
	)
	_add_ambient_toggle(
		parent,
		"notifications_enabled",
		"整轮结束后发送一次 Windows 通知",
		bool(_ambient_loaded_values.notifications_enabled),
		data
	)
	_add_ambient_toggle(
		parent,
		"memory_enabled",
		"将自然化后的角色间对话交给 Heartloom 整理",
		bool(_ambient_loaded_values.memory_enabled),
		data
	)

	var command_row := HBoxContainer.new()
	command_row.add_theme_constant_override("separation", 8)
	parent.add_child(command_row)
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
	parent: VBoxContainer,
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
	parent.add_child(toggle)
	_ambient_controls[key] = toggle

func _add_ambient_number(
	parent: VBoxContainer,
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
	parent.add_child(row)
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
	var defaults := KIT.updates_to_dictionary(
		INTERACTION_RULES.default_updates(_developer_role, _developer_action)
	)
	var effective := KIT.updates_to_dictionary(
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
		default_label.text = "默认 %s" % KIT.format_delta(float(defaults.get(stat, 0.0)))
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
		% KIT.short_save_id(_developer_scope_save_id)
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
	request_rebuild.call()
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
	return "仅作用于当前旅程 · ID %s" % KIT.short_save_id(save_id)

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
