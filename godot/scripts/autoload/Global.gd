extends Node

const MENSTRUAL_CYCLE := preload("res://scripts/domain/MenstrualCycle.gd")
const TEXT_SANITIZER := preload("res://scripts/domain/TextSanitizer.gd")
const CONVERSATION_ARCHIVE := preload("res://scripts/domain/ConversationArchive.gd")

# ===== Core signals =====
signal theme_changed(theme_data: Dictionary)
signal view_mode_changed(mode: String)
signal ai_response_received(text: String, character_id: String)
signal voice_input_received(text: String)
signal mod_loaded(mod_id: String)
signal scene_transition_finished
signal stat_changed(role: String, stat: String, value: float)
signal role_switched(role: String)
signal action_triggered(action: String, role: String)
signal font_size_changed(new_size: int)
signal life_stat_changed(role: String, stat: String, value: float)
signal save_catalog_changed
signal save_slot_loaded(save_id: String)

# ===== Character definitions =====
const ROLES = {
	ling = { name = "小玲", full_name = "春日 鈴音", icon = "🐾", sub = "猫娘 · 21岁", mood = "☀️ 暖洋洋", color = "#F5A97F" },
	nai  = { name = "小奈", full_name = "白瀬 雪奈", icon = "🐇", sub = "兔娘 · 19岁", mood = "🌸 活力满满", color = "#B8A6D9" }
}

const SAVE_VERSION := 6
const BALANCE_VERSION := 5
const SAVE_CATALOG_VERSION := 1
const DEFAULT_SAVE_PATH := "user://SpringHaven/saves/default.json"
const DEFAULT_SAVE_TEMP_PATH := DEFAULT_SAVE_PATH + ".tmp"
const DEFAULT_SAVE_BACKUP_PATH := DEFAULT_SAVE_PATH + ".bak"
const DIAGNOSTIC_SAVE_DIR := "user://SpringHaven/diagnostics"
const RECOVERY_DIR := "user://SpringHaven/recovery"
const MAX_CONVERSATION_HISTORY := 64
const MAX_APPLIED_LOCAL_EFFECT_IDS := 256
const ROLE_DEFAULT_STATS := {
	"ling": {
		"health": 76.0,
		"stamina": 46.0,
		"hunger": 48.0,
		"thirst": 34.0,
		"awake": 54.0,
		"urine": 24.0,
		"intimacy": 100.0,
		"mood": 62.0,
		"stress": 18.0,
		"fertility": 10.0,
		"implantation": 0.5,
		"arousal": 8.0,
		"climax": 0.0
	},
	"nai": {
		"health": 72.0,
		"stamina": 68.0,
		"hunger": 34.0,
		"thirst": 46.0,
		"awake": 78.0,
		"urine": 20.0,
		"intimacy": 100.0,
		"mood": 70.0,
		"stress": 30.0,
		"fertility": 14.0,
		"implantation": 0.7,
		"arousal": 14.0,
		"climax": 0.0
	}
}

# ===== Global state =====
var current_character: String = "ling"
var game_data_path: String = "user://SpringHaven/"
var save_id: String = ""
var stats_by_role: Dictionary = {}
var conversation_history: Array[Dictionary] = []
var applied_local_effect_ids: Array[String] = []
var full_stat_milestones: Dictionary = {}
var life_runtime: Dictionary = {}
var journey_created_at := 0
var journey_recovery_kind := "complete"
var state_loaded := false
var last_save_error := ""
var _last_archived_history_snapshot := ""
var _save_catalog: Dictionary = {}
var _pending_save_display_name := ""
var _save_root_override := ""

func _ready() -> void:
	_ensure_data_directories()
	load_default_state()

func _ensure_data_directories() -> bool:
	var succeeded := true
	var paths := [
		game_data_path,
		game_data_path.path_join("mods"),
		_save_directory_path(),
		_save_directory_path().path_join("trash"),
		game_data_path.path_join("diagnostics"),
		game_data_path.path_join("recovery"),
		game_data_path.path_join("conversation_archive"),
	]
	for path_variant in paths:
		var path := str(path_variant)
		var absolute_path := ProjectSettings.globalize_path(path)
		var error := DirAccess.make_dir_recursive_absolute(absolute_path)
		if error != OK and error != ERR_ALREADY_EXISTS:
			succeeded = false
			push_warning("无法创建游戏数据目录 %s：%s" % [path, error_string(error)])
	return succeeded

func load_default_state() -> bool:
	state_loaded = false
	last_save_error = ""
	_last_archived_history_snapshot = ""
	_save_catalog = _load_or_rebuild_save_catalog()
	var loaded_data: Dictionary = {}
	var should_rewrite := false
	var active_id := str(_save_catalog.get("active_save_id", ""))
	var source_path := _save_path_for_id(active_id) if is_valid_save_id(active_id) else ""
	if source_path.is_empty() or not FileAccess.file_exists(source_path):
		if not source_path.is_empty() and FileAccess.file_exists(source_path + ".bak"):
			source_path += ".bak"
			should_rewrite = true
		elif FileAccess.file_exists(_legacy_save_path()):
			source_path = _legacy_save_path()
			should_rewrite = true
		elif FileAccess.file_exists(_legacy_save_path() + ".bak"):
			source_path = _legacy_save_path() + ".bak"
			should_rewrite = true
		else:
			source_path = ""
	if FileAccess.file_exists(source_path):
		var file := FileAccess.open(source_path, FileAccess.READ)
		if not file:
			return _reject_loaded_state("无法读取默认存档：%s" % error_string(FileAccess.get_open_error()))
		var serialized := file.get_as_text()
		file.close()
		var parsed = JSON.parse_string(serialized)
		if not parsed is Dictionary:
			return _reject_loaded_state("默认存档不是有效的 JSON 对象；原文件已保留")
		loaded_data = parsed
		var loaded_version := _read_save_version(loaded_data)
		if loaded_version < 0:
			return _reject_loaded_state("默认存档的版本字段无效；原文件已保留")
		if loaded_version > SAVE_VERSION:
			return _reject_loaded_state(
				"默认存档版本 %d 高于当前支持的版本 %d；请使用兼容版本打开"
				% [loaded_version, SAVE_VERSION]
			)
		while loaded_version < SAVE_VERSION:
			match loaded_version:
				0:
					loaded_data = _migrate_v0_to_v1(loaded_data)
				1:
					loaded_data = _migrate_v1_to_v2(loaded_data)
				2:
					loaded_data = _migrate_v2_to_v3(loaded_data)
				3:
					loaded_data = _migrate_v3_to_v4(loaded_data)
				4:
					loaded_data = _migrate_v4_to_v5(loaded_data)
				5:
					loaded_data = _migrate_v5_to_v6(loaded_data)
				_:
					return _reject_loaded_state(
						"默认存档缺少从版本 %d 到版本 %d 的迁移路径"
						% [loaded_version, SAVE_VERSION]
					)
			loaded_version = _read_save_version(loaded_data)
			if loaded_version < 0:
				return _reject_loaded_state("迁移后的默认存档版本字段无效")
			should_rewrite = true
		var repaired_data := _repair_diagnostic_pollution(loaded_data)
		if not repaired_data.is_empty():
			loaded_data = repaired_data
			should_rewrite = true
		if not _is_current_balance_version(loaded_data.get("balance_version", 0)):
			should_rewrite = true
	else:
		should_rewrite = true

	save_id = str(loaded_data.get("save_id", "")).strip_edges()
	if not is_valid_save_id(save_id):
		save_id = _generate_save_id()
		should_rewrite = true
	journey_created_at = int(loaded_data.get(
		"created_at", loaded_data.get("updated_at", Time.get_unix_time_from_system())
	))
	if journey_created_at <= 0:
		journey_created_at = int(Time.get_unix_time_from_system())
		should_rewrite = true
	journey_recovery_kind = str(loaded_data.get("recovery_kind", "complete"))
	if journey_recovery_kind not in ["complete", "conversation_only"]:
		journey_recovery_kind = "complete"
		should_rewrite = true

	current_character = str(loaded_data.get("current_role", "ling"))
	if not ROLES.has(current_character):
		current_character = "ling"
		should_rewrite = true

	stats_by_role = _normalize_stats_by_role(loaded_data.get("stats_by_role", {}))
	conversation_history = _normalize_conversation_history(loaded_data.get("conversation_history", []))
	var raw_effect_ids = loaded_data.get("applied_local_effect_ids", [])
	applied_local_effect_ids = _normalize_applied_local_effect_ids(
		raw_effect_ids,
		conversation_history
	)
	if (
		not loaded_data.has("applied_local_effect_ids")
		or not _is_normalized_effect_id_ledger(raw_effect_ids, applied_local_effect_ids)
	):
		should_rewrite = true
	var raw_full_milestones = loaded_data.get("full_stat_milestones", {})
	full_stat_milestones = _normalize_full_stat_milestones(
		raw_full_milestones,
		stats_by_role,
		save_id
	)
	if (
		not raw_full_milestones is Dictionary
		or JSON.stringify(raw_full_milestones) != JSON.stringify(full_stat_milestones)
	):
		should_rewrite = true
	var raw_life_runtime = loaded_data.get("life_runtime", {})
	life_runtime = _normalize_life_runtime(raw_life_runtime)
	if not raw_life_runtime is Dictionary or JSON.stringify(raw_life_runtime) != JSON.stringify(life_runtime):
		should_rewrite = true
	state_loaded = true
	if should_rewrite and not save_default_state():
		state_loaded = false
		return false
	_archive_current_conversation()
	save_slot_loaded.emit(save_id)
	return true

func save_default_state() -> bool:
	if not state_loaded:
		_set_save_error("当前没有可保存的已加载状态")
		return false
	if not is_valid_save_id(save_id):
		_set_save_error("当前存档 ID 不符合 Bridge 协议，拒绝写入")
		return false
	if not _ensure_data_directories():
		_set_save_error("无法创建存档目录")
		return false
	applied_local_effect_ids = _normalize_applied_local_effect_ids(
		applied_local_effect_ids,
		[]
	)
	full_stat_milestones = _normalize_full_stat_milestones(
		full_stat_milestones,
		stats_by_role,
		save_id
	)
	life_runtime = _normalize_life_runtime(life_runtime)
	var updated_at := int(Time.get_unix_time_from_system())
	var payload := {
		"version": SAVE_VERSION,
		"balance_version": BALANCE_VERSION,
		"save_id": save_id,
		"created_at": journey_created_at if journey_created_at > 0 else updated_at,
		"current_role": current_character,
		"stats_by_role": stats_by_role,
		"conversation_history": conversation_history,
		"applied_local_effect_ids": applied_local_effect_ids,
		"full_stat_milestones": full_stat_milestones,
		"life_runtime": life_runtime,
		"recovery_kind": journey_recovery_kind,
		"updated_at": updated_at,
	}
	var saved := _atomic_write_save(
		JSON.stringify(payload, "\t"),
		_save_path_for_id(save_id)
	)
	if saved and not _is_diagnostic_save_id(save_id):
		if not _upsert_active_save_metadata(payload, _pending_save_display_name):
			return false
		_pending_save_display_name = ""
	if saved:
		_archive_current_conversation()
	return saved

func get_role_stats(role: String) -> Dictionary:
	if not stats_by_role.has(role):
		stats_by_role[role] = _default_stats_for_role(role)
	return stats_by_role[role] as Dictionary

func apply_life_updates(
	role: String,
	updates: Dictionary,
	event_id: String,
	persist := true
) -> Dictionary:
	if not ROLES.has(role):
		return _commit_error("未知生命状态角色：%s" % role)
	var normalized_event_id := event_id.strip_edges()
	if normalized_event_id.is_empty() or normalized_event_id.length() > 128:
		return _commit_error("生命状态事件 ID 无效")
	var runtime := _normalize_life_runtime(life_runtime)
	var applied_events: Array = runtime.get("applied_event_ids", [])
	if normalized_event_id in applied_events:
		return {"ok": true, "duplicate": true, "stat_changes": []}
	var working_stats := _normalize_role_stats(role, stats_by_role.get(role, {}))
	var changes: Array[Dictionary] = []
	for stat_variant in updates:
		var stat := str(stat_variant)
		if not working_stats.has(stat):
			continue
		var raw_delta = updates[stat_variant]
		if raw_delta is bool or not (raw_delta is int or raw_delta is float):
			continue
		var delta := float(raw_delta)
		if not is_finite(delta):
			continue
		var old_value := float(working_stats[stat])
		var new_value := clampf(old_value + delta, 0.0, 100.0)
		if is_equal_approx(old_value, new_value):
			continue
		working_stats[stat] = new_value
		changes.append({
			"stat": stat,
			"old_value": old_value,
			"new_value": new_value,
			"delta": new_value - old_value,
		})
	var previous_stats := stats_by_role.duplicate(true)
	var previous_runtime := life_runtime.duplicate(true)
	stats_by_role[role] = working_stats
	applied_events.append(normalized_event_id)
	while applied_events.size() > 512:
		applied_events.pop_front()
	runtime["applied_event_ids"] = applied_events
	life_runtime = runtime
	if persist and not save_default_state():
		stats_by_role = previous_stats
		life_runtime = previous_runtime
		return _commit_error(last_save_error)
	for change in changes:
		life_stat_changed.emit(role, str(change.stat), float(change.new_value))
	return {"ok": true, "duplicate": false, "stat_changes": changes}

func update_life_runtime(changes: Dictionary, persist := true) -> bool:
	var previous := life_runtime.duplicate(true)
	var merged := _normalize_life_runtime(life_runtime)
	for key in changes:
		merged[key] = changes[key]
	life_runtime = _normalize_life_runtime(merged)
	if persist and not save_default_state():
		life_runtime = previous
		return false
	return true

func get_active_save_id() -> String:
	if not is_valid_save_id(save_id):
		save_id = _generate_save_id()
	return save_id

func is_state_loaded() -> bool:
	return state_loaded

func get_last_save_error() -> String:
	return last_save_error

func has_default_save() -> bool:
	return not list_save_slots(false).is_empty() or FileAccess.file_exists(_legacy_save_path())

func reset_default_state(display_name := "") -> Dictionary:
	if state_loaded and is_valid_save_id(save_id) and not save_default_state():
		return {
			"ok": false,
			"previous_save_id": save_id,
			"message": last_save_error if not last_save_error.is_empty() else "无法保存当前旅程",
		}
	var previous_save_id := save_id
	var previous_character := current_character
	var previous_stats := stats_by_role.duplicate(true)
	var previous_history: Array[Dictionary] = conversation_history.duplicate(true)
	var previous_effect_ids: Array[String] = applied_local_effect_ids.duplicate()
	var previous_full_milestones: Dictionary = full_stat_milestones.duplicate(true)
	var previous_life_runtime: Dictionary = life_runtime.duplicate(true)
	var previous_created_at := journey_created_at
	var previous_recovery_kind := journey_recovery_kind
	var previous_state_loaded := state_loaded
	var previous_catalog := _save_catalog.duplicate(true)
	var previous_pending_name := _pending_save_display_name
	save_id = _generate_save_id()
	journey_created_at = int(Time.get_unix_time_from_system())
	journey_recovery_kind = "complete"
	_pending_save_display_name = _normalized_save_display_name(display_name)
	current_character = "ling"
	stats_by_role = _normalize_stats_by_role({})
	conversation_history.clear()
	applied_local_effect_ids.clear()
	full_stat_milestones.clear()
	life_runtime = _normalize_life_runtime({})
	state_loaded = true
	if save_default_state():
		return {
			"ok": true,
			"previous_save_id": previous_save_id,
			"save_id": save_id
		}
	save_id = previous_save_id
	current_character = previous_character
	stats_by_role = previous_stats
	conversation_history = previous_history
	applied_local_effect_ids = previous_effect_ids
	full_stat_milestones = previous_full_milestones
	life_runtime = previous_life_runtime
	journey_created_at = previous_created_at
	journey_recovery_kind = previous_recovery_kind
	state_loaded = previous_state_loaded
	_save_catalog = previous_catalog
	_pending_save_display_name = previous_pending_name
	_write_save_catalog(_save_catalog)
	return {
		"ok": false,
		"previous_save_id": previous_save_id,
		"message": last_save_error if not last_save_error.is_empty() else "无法写入新存档"
	}

func persist_role_stats(role: String, stats: Dictionary) -> bool:
	if not ROLES.has(role):
		return false
	var normalized := _default_stats_for_role(role)
	for stat_key in normalized:
		if stats.has(stat_key):
			normalized[stat_key] = _normalize_stat_value(
				stats[stat_key],
				float(normalized[stat_key])
			)
	stats_by_role[role] = normalized
	return save_default_state()

func set_current_character(role: String, persist := true) -> bool:
	if not ROLES.has(role):
		return false
	current_character = role
	if persist:
		return save_default_state()
	return true

func append_conversation_entry(entry: Dictionary, persist := true) -> bool:
	conversation_history.append(entry.duplicate(true))
	while conversation_history.size() > MAX_CONVERSATION_HISTORY:
		conversation_history.pop_front()
	if persist:
		return save_default_state()
	return true

func commit_user_message(
	entry: Dictionary,
	role: String,
	effect_spec: Dictionary,
	append_history := true
) -> Dictionary:
	if not state_loaded:
		return _commit_error("当前没有可写入的已加载状态")
	if not ROLES.has(role):
		return _commit_error("未知角色：%s" % role)

	var committed_entry: Dictionary = entry.duplicate(true)
	var text := str(committed_entry.get("text", ""))
	if text.strip_edges().is_empty():
		return _commit_error("用户消息不能为空")
	var entry_id := str(committed_entry.get("id", "")).strip_edges()
	if entry_id.is_empty():
		entry_id = new_local_id("user")
	committed_entry["id"] = entry_id
	committed_entry["sender"] = "user"
	committed_entry["role"] = role
	committed_entry["text"] = text
	committed_entry["status"] = str(committed_entry.get("status", "pending"))

	var has_local_effect := not effect_spec.is_empty()
	var event_id := str(effect_spec.get("event_id", effect_spec.get("id", ""))).strip_edges()
	if has_local_effect:
		if event_id.is_empty():
			return _commit_error("本地效果缺少 event_id")
		if event_id.length() > 128 or TEXT_SANITIZER.contains_nul(event_id):
			return _commit_error("本地效果 event_id 无效")
		if event_id in applied_local_effect_ids:
			var existing_entry := _find_history_entry_by_effect_id(event_id)
			var existing_effect = existing_entry.get("local_effect", {})
			var existing_state = existing_entry.get("state", {})
			return {
				"ok": true,
				"duplicate": true,
				"event_id": event_id,
				"entry": existing_entry.duplicate(true),
				"stat_changes": (
					(existing_effect as Dictionary).get("stat_changes", []).duplicate(true)
					if existing_effect is Dictionary
					else []
				),
				"state": existing_state.duplicate(true) if existing_state is Dictionary else {}
			}

	var parsed_effect := _parse_effect_deltas(effect_spec, role)
	if not bool(parsed_effect.get("ok", false)):
		return _commit_error(str(parsed_effect.get("message", "本地效果格式无效")))
	var deltas: Dictionary = parsed_effect.get("deltas", {})
	var role_defaults := _default_stats_for_role(role)
	var current_stats = stats_by_role.get(role, {})
	var working_stats := _normalize_role_stats(role, current_stats)
	var action := str(effect_spec.get("action", ""))
	var arousal_was_full := float(working_stats.get("arousal", 0.0)) >= 100.0
	if action in ["kiss", "sex"]:
		if arousal_was_full:
			deltas["arousal"] = 0.0
		else:
			deltas.erase("climax")
	var stat_changes: Array[Dictionary] = []
	var cycle_events: Array[Dictionary] = []
	for stat_key_variant in role_defaults:
		var stat_key := str(stat_key_variant)
		if not deltas.has(stat_key):
			continue
		var old_value := float(working_stats[stat_key])
		var requested_delta := float(deltas[stat_key])
		var new_value := clampf(old_value + requested_delta, 0.0, 100.0)
		if stat_key == "climax" and arousal_was_full and new_value >= 100.0:
			var reset_value := _deterministic_climax_reset(event_id, role)
			cycle_events.append({
				"kind": "climax_cycle_completed",
				"role_id": role,
				"event_id": event_id,
				"old_value": old_value,
				"reached_value": 100.0,
				"reset_value": reset_value,
				"occurred_at": int(Time.get_unix_time_from_system()),
			})
			new_value = reset_value
		working_stats[stat_key] = new_value
		stat_changes.append({
			"stat": stat_key,
			"old_value": old_value,
			"new_value": new_value,
			"delta": new_value - old_value,
			"requested_delta": requested_delta
		})
	var first_full_milestones: Array[Dictionary] = []
	if has_local_effect:
		first_full_milestones = _build_first_full_milestones(
			role,
			entry_id,
			event_id,
			stat_changes
		)

	if has_local_effect:
		var local_effect := {
			"event_id": event_id,
			"role_id": role,
			"balance_version": BALANCE_VERSION,
			"requested_deltas": deltas.duplicate(true),
			"stat_changes": stat_changes.duplicate(true),
			"applied_at": int(Time.get_unix_time_from_system())
		}
		for metadata_key in [
			"schema_version",
			"matcher_version",
			"source",
			"source_message_id",
			"rule_id",
			"action",
			"kind",
			"intensity",
			"intensity_multiplier"
		]:
			if effect_spec.has(metadata_key):
				local_effect[metadata_key] = effect_spec[metadata_key]
		if not first_full_milestones.is_empty():
			local_effect["first_full_milestones"] = first_full_milestones.duplicate(true)
		if not cycle_events.is_empty():
			local_effect["cycle_events"] = cycle_events.duplicate(true)
		var frozen_state := {
			"event_id": event_id,
			"role_id": role,
			"balance_version": BALANCE_VERSION,
			"stats": working_stats.duplicate(true),
			"stat_changes": stat_changes.duplicate(true),
			"local_effect": local_effect.duplicate(true)
		}
		if not first_full_milestones.is_empty():
			frozen_state["first_full_milestones"] = first_full_milestones.duplicate(true)
		if not cycle_events.is_empty():
			frozen_state["cycle_events"] = cycle_events.duplicate(true)
		committed_entry["local_effect"] = local_effect
		committed_entry["state"] = frozen_state

	var previous_stats := stats_by_role.duplicate(true)
	var previous_history: Array[Dictionary] = conversation_history.duplicate(true)
	var previous_effect_ids: Array[String] = applied_local_effect_ids.duplicate()
	var previous_full_milestones: Dictionary = full_stat_milestones.duplicate(true)
	stats_by_role[role] = working_stats
	if append_history:
		conversation_history.append(committed_entry)
		while conversation_history.size() > MAX_CONVERSATION_HISTORY:
			conversation_history.pop_front()
	if has_local_effect:
		applied_local_effect_ids.append(event_id)
		applied_local_effect_ids = _normalize_applied_local_effect_ids(
			applied_local_effect_ids,
			[]
		)
		for milestone_variant in first_full_milestones:
			if not milestone_variant is Dictionary:
				continue
			var milestone: Dictionary = milestone_variant
			var milestone_key := _full_milestone_key(
				str(milestone.get("role_id", "")),
				str(milestone.get("stat_key", ""))
			)
			if not milestone_key.is_empty():
				full_stat_milestones[milestone_key] = milestone.duplicate(true)

	if not save_default_state():
		stats_by_role = previous_stats
		conversation_history = previous_history
		applied_local_effect_ids = previous_effect_ids
		full_stat_milestones = previous_full_milestones
		return _commit_error(
			last_save_error if not last_save_error.is_empty() else "本地消息提交失败"
		)
	return {
		"ok": true,
		"duplicate": false,
		"event_id": event_id,
		"entry": committed_entry.duplicate(true),
		"stat_changes": stat_changes.duplicate(true),
		"first_full_milestones": first_full_milestones.duplicate(true),
		"cycle_events": cycle_events.duplicate(true),
		"state": (
			(committed_entry.get("state", {}) as Dictionary).duplicate(true)
			if committed_entry.get("state", {}) is Dictionary
			else {}
		)
	}

func update_conversation_entry(message_id: String, changes: Dictionary, persist := true) -> bool:
	if message_id.is_empty():
		return false
	for index in range(conversation_history.size() - 1, -1, -1):
		var entry: Dictionary = conversation_history[index]
		if str(entry.get("id", "")) != message_id:
			continue
		for key in changes:
			entry[key] = changes[key]
		conversation_history[index] = entry
		if persist:
			return save_default_state()
		return true
	return false

func new_local_id(prefix := "entry") -> String:
	return "%s-%d-%d" % [prefix, Time.get_ticks_usec(), randi()]

func is_valid_save_id(value: String) -> bool:
	if value.is_empty() or value.length() > 64:
		return false
	for index in value.length():
		var code := value.unicode_at(index)
		var is_ascii_letter := (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
		var is_ascii_digit := code >= 48 and code <= 57
		if is_ascii_letter or is_ascii_digit:
			continue
		if index > 0 and code in [45, 95]:
			continue
		return false
	return true

func _read_save_version(data: Dictionary) -> int:
	if not data.has("version"):
		return 0
	var raw_version = data.get("version")
	if raw_version is bool or not (raw_version is int or raw_version is float):
		return -1
	var version := int(raw_version)
	if version < 0 or float(version) != float(raw_version):
		return -1
	return version

func _migrate_v0_to_v1(data: Dictionary) -> Dictionary:
	var migrated := data.duplicate(true)
	if not migrated.has("current_role") and migrated.has("current_character"):
		migrated["current_role"] = migrated.get("current_character")
	if not migrated.get("stats_by_role") is Dictionary:
		var legacy_stats = migrated.get("stats", {})
		if legacy_stats is Dictionary:
			migrated["stats_by_role"] = {
				"ling": legacy_stats.duplicate(true),
				"nai": legacy_stats.duplicate(true)
			}
	migrated["version"] = 1
	return migrated

func _migrate_v1_to_v2(data: Dictionary) -> Dictionary:
	var migrated := data.duplicate(true)
	var raw_stats = migrated.get("stats_by_role", {})
	var migrated_stats: Dictionary = raw_stats.duplicate(true) if raw_stats is Dictionary else {}
	for role_key_variant in ROLES:
		var role := str(role_key_variant)
		var role_defaults := _default_stats_for_role(role)
		var existing_role = migrated_stats.get(role, {})
		var preserved_role: Dictionary = (
			existing_role.duplicate(true) if existing_role is Dictionary else {}
		)
		for stat_key in role_defaults:
			if not preserved_role.has(stat_key):
				preserved_role[stat_key] = role_defaults[stat_key]
		migrated_stats[role] = preserved_role
	migrated["stats_by_role"] = migrated_stats
	var raw_history = migrated.get("conversation_history", [])
	migrated["applied_local_effect_ids"] = _normalize_applied_local_effect_ids(
		migrated.get("applied_local_effect_ids", []),
		raw_history if raw_history is Array else []
	)
	migrated["balance_version"] = BALANCE_VERSION
	migrated["version"] = 2
	return migrated

func _migrate_v2_to_v3(data: Dictionary) -> Dictionary:
	var migrated := data.duplicate(true)
	var migrated_stats := _normalize_stats_by_role(migrated.get("stats_by_role", {}))
	var migrated_save_id := str(migrated.get("save_id", "")).strip_edges()
	migrated["full_stat_milestones"] = _normalize_full_stat_milestones(
		migrated.get("full_stat_milestones", {}),
		migrated_stats,
		migrated_save_id
	)
	migrated["version"] = 3
	return migrated

func _migrate_v3_to_v4(data: Dictionary) -> Dictionary:
	var migrated := data.duplicate(true)
	migrated["life_runtime"] = _normalize_life_runtime(migrated.get("life_runtime", {}))
	migrated["version"] = 4
	return migrated

func _migrate_v4_to_v5(data: Dictionary) -> Dictionary:
	var migrated := data.duplicate(true)
	migrated["stats_by_role"] = _normalize_stats_by_role(
		migrated.get("stats_by_role", {})
	)
	migrated["life_runtime"] = _normalize_life_runtime(
		migrated.get("life_runtime", {})
	)
	migrated["balance_version"] = BALANCE_VERSION
	migrated["version"] = 5
	return migrated

func _migrate_v5_to_v6(data: Dictionary) -> Dictionary:
	var migrated := data.duplicate(true)
	var raw_stats = migrated.get("stats_by_role", {})
	var migrated_stats: Dictionary = raw_stats.duplicate(true) if raw_stats is Dictionary else {}
	for role_variant in ROLES:
		var role := str(role_variant)
		var raw_role = migrated_stats.get(role, {})
		var role_stats: Dictionary = raw_role.duplicate(true) if raw_role is Dictionary else {}
		role_stats["intimacy"] = 100.0
		migrated_stats[role] = role_stats
	migrated["stats_by_role"] = migrated_stats
	migrated["balance_version"] = BALANCE_VERSION
	migrated["version"] = 6
	return migrated

func _reject_loaded_state(message: String) -> bool:
	save_id = ""
	current_character = "ling"
	stats_by_role = _normalize_stats_by_role({})
	conversation_history.clear()
	applied_local_effect_ids.clear()
	full_stat_milestones.clear()
	life_runtime.clear()
	journey_created_at = 0
	journey_recovery_kind = "complete"
	state_loaded = false
	_set_save_error(message)
	return false

func _atomic_write_save(serialized: String, save_path: String) -> bool:
	var temp_path := save_path + ".tmp"
	var backup_path := save_path + ".bak"
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if not file:
		_set_save_error("无法创建临时存档：%s" % error_string(FileAccess.get_open_error()))
		return false
	file.store_string(serialized)
	file.flush()
	var write_error := file.get_error()
	file.close()
	var temp_absolute := ProjectSettings.globalize_path(temp_path)
	var save_absolute := ProjectSettings.globalize_path(save_path)
	var backup_absolute := ProjectSettings.globalize_path(backup_path)
	if write_error != OK:
		DirAccess.remove_absolute(temp_absolute)
		_set_save_error("写入临时存档失败：%s" % error_string(write_error))
		return false

	var had_existing_save := FileAccess.file_exists(save_path)
	if had_existing_save:
		if FileAccess.file_exists(backup_path):
			var remove_error := DirAccess.remove_absolute(backup_absolute)
			if remove_error != OK:
				DirAccess.remove_absolute(temp_absolute)
				_set_save_error("无法轮换存档备份：%s" % error_string(remove_error))
				return false
		var backup_error := DirAccess.rename_absolute(save_absolute, backup_absolute)
		if backup_error != OK:
			DirAccess.remove_absolute(temp_absolute)
			_set_save_error("无法备份当前存档：%s" % error_string(backup_error))
			return false

	var commit_error := DirAccess.rename_absolute(temp_absolute, save_absolute)
	if commit_error != OK:
		var restore_detail := ""
		if had_existing_save and FileAccess.file_exists(backup_path):
			var restore_error := DirAccess.rename_absolute(backup_absolute, save_absolute)
			if restore_error != OK:
				restore_detail = "；恢复旧存档也失败：%s" % error_string(restore_error)
		_set_save_error("无法提交新存档：%s%s" % [error_string(commit_error), restore_detail])
		return false
	last_save_error = ""
	return true

func _save_path_for_id(active_save_id: String) -> String:
	if _is_diagnostic_save_id(active_save_id):
		return game_data_path.path_join("diagnostics").path_join("%s.json" % active_save_id)
	if not is_valid_save_id(active_save_id):
		return ""
	return _save_directory_path().path_join("%s.json" % active_save_id)

func _save_directory_path() -> String:
	if not _save_root_override.strip_edges().is_empty():
		return _save_root_override.strip_edges()
	return game_data_path.path_join("saves")

func _legacy_save_path() -> String:
	return _save_directory_path().path_join("default.json")

func _save_catalog_path() -> String:
	return _save_directory_path().path_join("index.json")

func _empty_save_catalog() -> Dictionary:
	return {
		"version": SAVE_CATALOG_VERSION,
		"active_save_id": "",
		"updated_at": int(Time.get_unix_time_from_system()),
		"slots": [],
	}

func _load_or_rebuild_save_catalog() -> Dictionary:
	for path in [_save_catalog_path(), _save_catalog_path() + ".bak"]:
		if not FileAccess.file_exists(path):
			continue
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			continue
		var parsed = JSON.parse_string(file.get_as_text())
		file.close()
		if parsed is Dictionary:
			return _normalize_save_catalog(parsed as Dictionary)
	var rebuilt := _rebuild_save_catalog_from_slot_files()
	if not (rebuilt.get("slots", []) as Array).is_empty():
		_write_save_catalog(rebuilt)
	return rebuilt

func _normalize_save_catalog(raw: Dictionary) -> Dictionary:
	var result := _empty_save_catalog()
	var seen := {}
	var slots: Array[Dictionary] = []
	var raw_slots = raw.get("slots", [])
	if raw_slots is Array:
		for slot_variant in raw_slots:
			if not slot_variant is Dictionary:
				continue
			var slot := _normalize_save_slot_metadata(slot_variant as Dictionary)
			var slot_id := str(slot.get("save_id", ""))
			if slot.is_empty() or seen.has(slot_id):
				continue
			seen[slot_id] = true
			slots.append(slot)
	result.slots = slots
	var requested_active := str(raw.get("active_save_id", ""))
	if seen.has(requested_active):
		for slot in slots:
			if str(slot.save_id) == requested_active and not bool(slot.archived):
				result.active_save_id = requested_active
				break
	if str(result.active_save_id).is_empty():
		var newest := _newest_unarchived_slot(slots)
		result.active_save_id = str(newest.get("save_id", ""))
	result.updated_at = int(raw.get("updated_at", Time.get_unix_time_from_system()))
	return result

func _normalize_save_slot_metadata(raw: Dictionary) -> Dictionary:
	var slot_id := str(raw.get("save_id", "")).strip_edges()
	if not is_valid_save_id(slot_id) or _is_diagnostic_save_id(slot_id):
		return {}
	var recovery_kind := str(raw.get("recovery_kind", "complete"))
	if recovery_kind not in ["complete", "conversation_only"]:
		recovery_kind = "complete"
	var last_role := str(raw.get("last_role", "ling"))
	if not ROLES.has(last_role):
		last_role = "ling"
	return {
		"save_id": slot_id,
		"display_name": _normalized_save_display_name(str(raw.get("display_name", ""))),
		"created_at": maxi(0, int(raw.get("created_at", 0))),
		"updated_at": maxi(0, int(raw.get("updated_at", 0))),
		"last_role": last_role,
		"message_count": maxi(0, int(raw.get("message_count", 0))),
		"archived": bool(raw.get("archived", false)),
		"recovery_kind": recovery_kind,
	}

func _newest_unarchived_slot(slots: Array[Dictionary]) -> Dictionary:
	var newest: Dictionary = {}
	for slot in slots:
		if bool(slot.get("archived", false)):
			continue
		if newest.is_empty() or int(slot.get("updated_at", 0)) > int(newest.get("updated_at", 0)):
			newest = slot
	return newest

func _rebuild_save_catalog_from_slot_files() -> Dictionary:
	var catalog := _empty_save_catalog()
	var directory := DirAccess.open(_save_directory_path())
	if directory == null:
		return catalog
	var slots: Array[Dictionary] = []
	for file_name_variant in directory.get_files():
		var file_name := str(file_name_variant)
		if not file_name.ends_with(".json") or file_name in ["default.json", "index.json"]:
			continue
		var path := _save_directory_path().path_join(file_name)
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			continue
		var parsed = JSON.parse_string(file.get_as_text())
		file.close()
		if not parsed is Dictionary:
			continue
		var slot_id := str((parsed as Dictionary).get("save_id", ""))
		if not is_valid_save_id(slot_id) or file_name != "%s.json" % slot_id:
			continue
		slots.append(_metadata_from_save_payload(parsed as Dictionary, ""))
	catalog.slots = slots
	var newest := _newest_unarchived_slot(slots)
	catalog.active_save_id = str(newest.get("save_id", ""))
	return catalog

func _metadata_from_save_payload(payload: Dictionary, requested_name: String) -> Dictionary:
	var slot_id := str(payload.get("save_id", ""))
	var existing := _find_save_slot_metadata(slot_id)
	var display_name := _normalized_save_display_name(requested_name)
	if display_name.is_empty():
		display_name = str(existing.get("display_name", ""))
	if display_name.is_empty():
		display_name = "旅程 %d" % (_catalog_slots().size() + 1)
	var recovery_kind := str(payload.get("recovery_kind", existing.get("recovery_kind", "complete")))
	if recovery_kind not in ["complete", "conversation_only"]:
		recovery_kind = "complete"
	return {
		"save_id": slot_id,
		"display_name": display_name,
		"created_at": int(payload.get("created_at", existing.get("created_at", Time.get_unix_time_from_system()))),
		"updated_at": int(payload.get("updated_at", Time.get_unix_time_from_system())),
		"last_role": str(payload.get("current_role", existing.get("last_role", "ling"))),
		"message_count": maxi(
			int(existing.get("message_count", 0)),
			(payload.get("conversation_history", []) as Array).size()
			if payload.get("conversation_history", []) is Array else 0
		),
		"archived": false,
		"recovery_kind": recovery_kind,
	}

func _catalog_slots() -> Array:
	var slots = _save_catalog.get("slots", [])
	return slots if slots is Array else []

func _find_save_slot_metadata(target_save_id: String) -> Dictionary:
	for slot_variant in _catalog_slots():
		if slot_variant is Dictionary and str((slot_variant as Dictionary).get("save_id", "")) == target_save_id:
			return (slot_variant as Dictionary).duplicate(true)
	return {}

func _upsert_active_save_metadata(payload: Dictionary, requested_name := "") -> bool:
	return _upsert_save_metadata(payload, requested_name, true)

func _upsert_save_metadata(payload: Dictionary, requested_name: String, make_active: bool) -> bool:
	if _save_catalog.is_empty():
		_save_catalog = _load_or_rebuild_save_catalog()
	var metadata := _metadata_from_save_payload(payload, requested_name)
	if metadata.is_empty():
		_set_save_error("无法生成旅程索引")
		return false
	var slots: Array = _catalog_slots().duplicate(true)
	var replaced := false
	for index in slots.size():
		if slots[index] is Dictionary and str((slots[index] as Dictionary).get("save_id", "")) == str(metadata.save_id):
			slots[index] = metadata
			replaced = true
			break
	if not replaced:
		slots.append(metadata)
	_save_catalog.slots = slots
	if make_active:
		_save_catalog.active_save_id = str(metadata.save_id)
	if not _write_save_catalog(_save_catalog):
		return false
	save_catalog_changed.emit()
	return true

func _write_save_catalog(catalog: Dictionary) -> bool:
	var normalized := _normalize_save_catalog(catalog)
	normalized.updated_at = int(Time.get_unix_time_from_system())
	if not _atomic_write_save(JSON.stringify(normalized, "\t"), _save_catalog_path()):
		return false
	_save_catalog = normalized
	return true

func _normalized_save_display_name(value: String) -> String:
	var result := TEXT_SANITIZER.strip_nul(value).strip_edges()
	result = result.replace("\n", " ").replace("\r", " ").replace("\t", " ")
	while "  " in result:
		result = result.replace("  ", " ")
	return result.left(48)

func list_save_slots(include_archived := false) -> Array[Dictionary]:
	if _save_catalog.is_empty():
		_save_catalog = _load_or_rebuild_save_catalog()
	var archive_counts := {}
	for summary in CONVERSATION_ARCHIVE.journey_summaries():
		archive_counts[str(summary.get("save_id", ""))] = int(summary.get("message_count", 0))
	var result: Array[Dictionary] = []
	for slot_variant in _catalog_slots():
		if not slot_variant is Dictionary:
			continue
		var slot: Dictionary = (slot_variant as Dictionary).duplicate(true)
		if bool(slot.get("archived", false)) and not include_archived:
			continue
		slot.message_count = maxi(
			int(slot.get("message_count", 0)),
			int(archive_counts.get(str(slot.get("save_id", "")), 0))
		)
		slot.active = str(slot.get("save_id", "")) == str(_save_catalog.get("active_save_id", ""))
		slot.file_available = (
			FileAccess.file_exists(_save_path_for_id(str(slot.get("save_id", ""))))
			or FileAccess.file_exists(_save_path_for_id(str(slot.get("save_id", ""))) + ".bak")
		)
		result.append(slot)
	result.sort_custom(func(a: Dictionary, b: Dictionary): return int(a.updated_at) > int(b.updated_at))
	return result

func rename_save_slot(target_save_id: String, display_name: String) -> Dictionary:
	var normalized_name := _normalized_save_display_name(display_name)
	if normalized_name.is_empty():
		return {"ok": false, "message": "旅程名称不能为空"}
	var slots: Array = _catalog_slots().duplicate(true)
	var found := false
	for index in slots.size():
		if slots[index] is Dictionary and str((slots[index] as Dictionary).get("save_id", "")) == target_save_id:
			var slot: Dictionary = (slots[index] as Dictionary).duplicate(true)
			slot.display_name = normalized_name
			slots[index] = slot
			found = true
			break
	if not found:
		return {"ok": false, "message": "找不到指定旅程"}
	_save_catalog.slots = slots
	if not _write_save_catalog(_save_catalog):
		return {"ok": false, "message": last_save_error}
	save_catalog_changed.emit()
	return {"ok": true, "message": "旅程已重命名"}

func set_save_slot_archived(target_save_id: String, archived: bool) -> Dictionary:
	if archived and target_save_id == str(_save_catalog.get("active_save_id", "")):
		return {"ok": false, "message": "正在使用的旅程不能归档"}
	var slots: Array = _catalog_slots().duplicate(true)
	var found := false
	for index in slots.size():
		if slots[index] is Dictionary and str((slots[index] as Dictionary).get("save_id", "")) == target_save_id:
			var slot: Dictionary = (slots[index] as Dictionary).duplicate(true)
			slot.archived = archived
			slots[index] = slot
			found = true
			break
	if not found:
		return {"ok": false, "message": "找不到指定旅程"}
	_save_catalog.slots = slots
	if not _write_save_catalog(_save_catalog):
		return {"ok": false, "message": last_save_error}
	save_catalog_changed.emit()
	return {"ok": true, "message": "旅程已恢复" if not archived else "旅程已归档"}

func load_save_slot(target_save_id: String) -> Dictionary:
	if not is_valid_save_id(target_save_id):
		return {"ok": false, "message": "旅程 ID 无效"}
	var metadata := _find_save_slot_metadata(target_save_id)
	if metadata.is_empty() or bool(metadata.get("archived", false)):
		return {"ok": false, "message": "旅程不存在或已归档"}
	var target_path := _save_path_for_id(target_save_id)
	if not FileAccess.file_exists(target_path) and not FileAccess.file_exists(target_path + ".bak"):
		return {"ok": false, "message": "旅程文件不存在，可尝试从旧记录恢复"}
	if target_save_id == save_id and state_loaded:
		return {"ok": true, "save_id": target_save_id, "message": "旅程已经载入"}
	if state_loaded and is_valid_save_id(save_id) and not save_default_state():
		return {"ok": false, "message": last_save_error}
	var previous_catalog := _save_catalog.duplicate(true)
	var previous_save_id := save_id
	_save_catalog.active_save_id = target_save_id
	if not _write_save_catalog(_save_catalog):
		_save_catalog = previous_catalog
		return {"ok": false, "message": last_save_error}
	if load_default_state():
		return {"ok": true, "save_id": target_save_id, "message": "旅程已载入"}
	var target_error := last_save_error
	_save_catalog = previous_catalog
	_write_save_catalog(_save_catalog)
	if is_valid_save_id(previous_save_id):
		load_default_state()
	return {"ok": false, "message": target_error if not target_error.is_empty() else "旅程载入失败"}

func list_recoverable_journeys() -> Array[Dictionary]:
	var known := {}
	for slot_variant in _catalog_slots():
		if slot_variant is Dictionary:
			known[str((slot_variant as Dictionary).get("save_id", ""))] = true
	var result: Array[Dictionary] = []
	for summary in CONVERSATION_ARCHIVE.journey_summaries():
		var target_save_id := str(summary.get("save_id", ""))
		if (
			not is_valid_save_id(target_save_id)
			or target_save_id.ends_with("_life_lab")
			or target_save_id == "archive-check-save"
			or known.has(target_save_id)
		):
			continue
		var item: Dictionary = summary.duplicate(true)
		item.display_name = "恢复的旧旅程"
		item.recovery_kind = "conversation_only"
		result.append(item)
	return result

func recover_archived_journey(target_save_id: String, display_name := "") -> Dictionary:
	var summary: Dictionary = {}
	for item in list_recoverable_journeys():
		if str(item.get("save_id", "")) == target_save_id:
			summary = item
			break
	if summary.is_empty():
		return {"ok": false, "message": "找不到可恢复的旧旅程"}
	var restored_history := CONVERSATION_ARCHIVE.entries_for_save(
		target_save_id, MAX_CONVERSATION_HISTORY
	)
	var restored_role := "ling"
	for index in range(restored_history.size() - 1, -1, -1):
		var candidate := str(restored_history[index].get("role", ""))
		if ROLES.has(candidate):
			restored_role = candidate
			break
	var restored_stats := _normalize_stats_by_role({})
	var created_at := int(summary.get("created_at", Time.get_unix_time_from_system()))
	var updated_at := int(summary.get("updated_at", created_at))
	var payload := {
		"version": SAVE_VERSION,
		"balance_version": BALANCE_VERSION,
		"save_id": target_save_id,
		"created_at": created_at,
		"current_role": restored_role,
		"stats_by_role": restored_stats,
		"conversation_history": restored_history,
		"applied_local_effect_ids": [],
		"full_stat_milestones": _normalize_full_stat_milestones({}, restored_stats, target_save_id),
		"life_runtime": _normalize_life_runtime({}),
		"recovery_kind": "conversation_only",
		"updated_at": updated_at,
	}
	if not _atomic_write_save(JSON.stringify(payload, "\t"), _save_path_for_id(target_save_id)):
		return {"ok": false, "message": last_save_error}
	var recovered_name := _normalized_save_display_name(display_name)
	if recovered_name.is_empty():
		recovered_name = "恢复的旧旅程"
	if not _upsert_save_metadata(payload, recovered_name, false):
		return {"ok": false, "message": last_save_error}
	return {
		"ok": true,
		"save_id": target_save_id,
		"message": "旧旅程已恢复；属性和日程使用默认值，聊天与心织记忆已重新接回",
	}

func _is_diagnostic_save_id(value: String) -> bool:
	return value.begins_with("diagnostic-")

func _repair_diagnostic_pollution(loaded_data: Dictionary) -> Dictionary:
	var loaded_save_id := str(loaded_data.get("save_id", "")).strip_edges()
	if not _is_diagnostic_save_id(loaded_save_id):
		return {}
	_quarantine_diagnostic_state(loaded_data, loaded_save_id)
	var repaired := loaded_data.duplicate(true)
	var cleaned_history: Array[Dictionary] = []
	var raw_history = repaired.get("conversation_history", [])
	if raw_history is Array:
		for entry_variant in raw_history:
			if not entry_variant is Dictionary:
				continue
			var entry: Dictionary = entry_variant
			if _is_known_diagnostic_entry(entry):
				continue
			cleaned_history.append(entry.duplicate(true))
	repaired["save_id"] = _generate_save_id()
	repaired["conversation_history"] = cleaned_history
	repaired["updated_at"] = int(Time.get_unix_time_from_system())
	push_warning("检测到诊断状态写入默认旅程，已隔离并清理测试消息")
	return repaired

func _is_known_diagnostic_entry(entry: Dictionary) -> bool:
	var entry_id := str(entry.get("id", ""))
	var text := str(entry.get("text", ""))
	return (
		(entry_id == "seed" and text == "今天的阳光落在餐桌边，绿植看起来很精神。")
		or (
			entry_id == "ambient-seed"
			and text == "小玲姐姐，等会儿一起去看看窗边的花吧。"
		)
	)

func _quarantine_diagnostic_state(data: Dictionary, diagnostic_id: String) -> void:
	var directory_error := DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(RECOVERY_DIR)
	)
	if directory_error not in [OK, ERR_ALREADY_EXISTS]:
		push_warning("无法创建诊断污染恢复目录：%s" % error_string(directory_error))
		return
	var now := Time.get_datetime_dict_from_system()
	var file_name := "%04d-%02d-%02d_%02d-%02d-%02d_%s.json" % [
		int(now.year), int(now.month), int(now.day),
		int(now.hour), int(now.minute), int(now.second), diagnostic_id,
	]
	var file := FileAccess.open(RECOVERY_DIR.path_join(file_name), FileAccess.WRITE)
	if file == null:
		push_warning("无法保留诊断污染存档副本：%s" % error_string(FileAccess.get_open_error()))
		return
	file.store_string(JSON.stringify(data, "\t"))
	file.close()

func _archive_current_conversation() -> void:
	if _is_diagnostic_save_id(save_id) or not _save_root_override.is_empty():
		return
	var snapshot := JSON.stringify(conversation_history)
	if snapshot == _last_archived_history_snapshot:
		return
	if CONVERSATION_ARCHIVE.upsert_entries(conversation_history, save_id):
		_last_archived_history_snapshot = snapshot
		return
	var archive_error := CONVERSATION_ARCHIVE.get_last_error()
	push_warning(
		"聊天归档写入失败%s" % (
			"：%s" % archive_error if not archive_error.is_empty() else ""
		)
	)

func _set_save_error(message: String) -> void:
	last_save_error = message
	push_warning(message)

func _commit_error(message: String) -> Dictionary:
	return {"ok": false, "duplicate": false, "message": message}

func _is_current_balance_version(value: Variant) -> bool:
	if value is bool or not (value is int or value is float):
		return false
	return int(value) == BALANCE_VERSION and float(value) == float(BALANCE_VERSION)

func _default_stats_for_role(role: String) -> Dictionary:
	var normalized_role := role if ROLE_DEFAULT_STATS.has(role) else "ling"
	var defaults := (ROLE_DEFAULT_STATS[normalized_role] as Dictionary).duplicate(true)
	var settings_node := get_node_or_null("/root/Settings")
	if is_instance_valid(settings_node) and settings_node.has_method("get_role_default_stat_overrides"):
		var overrides = settings_node.call("get_role_default_stat_overrides", normalized_role)
		if overrides is Dictionary:
			for stat_variant in defaults:
				var stat := str(stat_variant)
				if overrides.has(stat):
					defaults[stat] = _normalize_stat_value(overrides[stat], float(defaults[stat]))
	return defaults

func _normalize_stat_value(value: Variant, fallback: float) -> float:
	if value is bool or not (value is int or value is float):
		return fallback
	var numeric := float(value)
	if not is_finite(numeric):
		return fallback
	return clampf(numeric, 0.0, 100.0)

func _normalize_role_stats(role: String, raw_value: Variant) -> Dictionary:
	var normalized := _default_stats_for_role(role)
	if raw_value is Dictionary:
		for stat_key in normalized:
			if raw_value.has(stat_key):
				normalized[stat_key] = _normalize_stat_value(
					raw_value[stat_key],
					float(normalized[stat_key])
				)
	return normalized

func _normalize_life_runtime(raw_value: Variant) -> Dictionary:
	var raw: Dictionary = raw_value if raw_value is Dictionary else {}
	var now := int(Time.get_unix_time_from_system())
	var last_update := _normalized_unix_time(raw.get("last_update_unix", now), now)
	var last_user_activity := _normalized_unix_time(
		raw.get("last_user_activity_unix", now), now
	)
	var roles: Dictionary = {}
	var raw_roles = raw.get("roles", {})
	for role_variant in ROLES:
		var role := str(role_variant)
		var raw_role: Dictionary = (
			raw_roles.get(role, {}) if raw_roles is Dictionary and raw_roles.get(role, {}) is Dictionary else {}
		)
		roles[role] = {
			"last_self_care_unix": _normalized_unix_time(raw_role.get("last_self_care_unix", 0), 0),
			"last_personality_action_unix": _normalized_unix_time(
				raw_role.get("last_personality_action_unix", 0), 0
			),
			"last_proactive_unix": _normalized_unix_time(raw_role.get("last_proactive_unix", 0), 0),
			"next_proactive_unix": _normalized_unix_time(raw_role.get("next_proactive_unix", 0), 0),
			"active_intent": str(raw_role.get("active_intent", "")).left(64),
			"current_intent": _normalize_life_intent(raw_role.get("current_intent", {}), role),
			"routine_days": _normalize_routine_days(raw_role.get("routine_days", {})),
			"last_life_event": str(raw_role.get("last_life_event", "")).left(64),
			"menstrual_cycle": MENSTRUAL_CYCLE.normalize_runtime(
				role,
				raw_role.get("menstrual_cycle", {}),
				now
			),
		}
	var event_ids: Array[String] = []
	var raw_event_ids = raw.get("applied_event_ids", [])
	if raw_event_ids is Array:
		for id_variant in raw_event_ids:
			var id := str(id_variant).strip_edges()
			if not id.is_empty() and id.length() <= 128 and id not in event_ids:
				event_ids.append(id)
	while event_ids.size() > 512:
		event_ids.pop_front()
	var raw_ambient: Dictionary = (
		raw.get("ambient_dialogue", {})
		if raw.get("ambient_dialogue", {}) is Dictionary
		else {}
	)
	var last_starter_role := str(raw_ambient.get("last_starter_role", ""))
	if last_starter_role not in ["ling", "nai"]:
		last_starter_role = ""
	var completed_sessions := 0
	var raw_completed_sessions = raw_ambient.get("completed_sessions", 0)
	if (
		not raw_completed_sessions is bool
		and (raw_completed_sessions is int or raw_completed_sessions is float)
		and is_finite(float(raw_completed_sessions))
	):
		completed_sessions = clampi(int(raw_completed_sessions), 0, 2147483647)
	var message_scheduler := _normalize_message_scheduler(raw.get("message_scheduler", {}))
	return {
		"last_update_unix": last_update,
		"last_user_activity_unix": last_user_activity,
		"roles": roles,
		"applied_event_ids": event_ids,
		"ambient_dialogue": {
			"last_session_unix": _normalized_unix_time(
				raw_ambient.get("last_session_unix", 0), 0
			),
			"next_session_unix": _normalized_unix_time(
				raw_ambient.get("next_session_unix", 0), 0
			),
			"last_starter_role": last_starter_role,
			"completed_sessions": completed_sessions,
		},
		"message_scheduler": message_scheduler,
	}

func _normalize_message_scheduler(raw_value: Variant) -> Dictionary:
	var raw: Dictionary = raw_value if raw_value is Dictionary else {}
	var queued: Array[Dictionary] = []
	var seen_queued: Dictionary = {}
	var raw_queue = raw.get("queued_deliveries", [])
	if raw_queue is Array:
		for item_variant in raw_queue:
			if not item_variant is Dictionary:
				continue
			var item: Dictionary = item_variant
			var delivery_id := str(item.get("id", "")).strip_edges().left(128)
			var payload_variant = item.get("payload", {})
			if delivery_id.is_empty() or seen_queued.has(delivery_id) or not payload_variant is Dictionary:
				continue
			queued.append({
				"id": delivery_id,
				"payload": (payload_variant as Dictionary).duplicate(true),
				"queued_at_unix": _normalized_unix_time(item.get("queued_at_unix", 0), 0),
			})
			seen_queued[delivery_id] = true
	while queued.size() > 64:
		queued.pop_front()
	var delivered_ids: Array[String] = []
	var raw_delivered = raw.get("delivered_ids", [])
	if raw_delivered is Array:
		for id_variant in raw_delivered:
			var delivery_id := str(id_variant).strip_edges().left(128)
			if not delivery_id.is_empty() and delivery_id not in delivered_ids:
				delivered_ids.append(delivery_id)
	while delivered_ids.size() > 256:
		delivered_ids.pop_front()
	return {
		"queued_deliveries": queued,
		"delivered_ids": delivered_ids,
	}

func _normalized_unix_time(value: Variant, fallback: int) -> int:
	if value is bool or not (value is int or value is float):
		return fallback
	var numeric := float(value)
	if not is_finite(numeric) or numeric < 0.0:
		return fallback
	return int(numeric)

func _normalize_life_intent(raw_value: Variant, role: String) -> Dictionary:
	if not raw_value is Dictionary:
		return {}
	var raw: Dictionary = raw_value
	var intent_id := str(raw.get("id", "")).strip_edges().left(128)
	var action := str(raw.get("action", "")).strip_edges().left(64)
	var status := str(raw.get("status", "")).strip_edges()
	if intent_id.is_empty() or action.is_empty() or status not in [
		"planned", "executing", "completed", "failed", "expired"
	]:
		return {}
	var target_role := str(raw.get("target_role", ""))
	if target_role not in ["", "ling", "nai"] or target_role == role:
		target_role = ""
	return {
		"id": intent_id,
		"role_id": role,
		"action": action,
		"status": status,
		"reason": str(raw.get("reason", "")).strip_edges().left(160),
		"target_role": target_role,
		"routine_slot": str(raw.get("routine_slot", "")).strip_edges().left(32),
		"description": str(raw.get("description", "")).strip_edges().left(240),
		"created_at_unix": _normalized_unix_time(raw.get("created_at_unix", 0), 0),
		"updated_at_unix": _normalized_unix_time(raw.get("updated_at_unix", 0), 0),
		"expires_at_unix": _normalized_unix_time(raw.get("expires_at_unix", 0), 0),
	}

func _normalize_routine_days(raw_value: Variant) -> Dictionary:
	if not raw_value is Dictionary:
		return {}
	var result := {}
	for key_variant in raw_value:
		if result.size() >= 16:
			break
		var key := str(key_variant).strip_edges().left(32)
		var day := str((raw_value as Dictionary)[key_variant]).strip_edges().left(16)
		if not key.is_empty() and not day.is_empty():
			result[key] = day
	return result

func _parse_effect_deltas(effect_spec: Dictionary, role: String) -> Dictionary:
	var deltas: Dictionary = {}
	var raw_updates = effect_spec.get(
		"updates",
		effect_spec.get("deltas", effect_spec.get("stat_changes", []))
	)
	if raw_updates == null:
		return {"ok": true, "deltas": deltas}
	if raw_updates is Dictionary:
		for stat_key_variant in raw_updates:
			var error := _merge_effect_delta(
				deltas,
				role,
				str(stat_key_variant),
				raw_updates[stat_key_variant]
			)
			if not error.is_empty():
				return {"ok": false, "message": error}
	elif raw_updates is Array:
		for raw_update in raw_updates:
			var stat_key := ""
			var raw_delta: Variant = null
			if raw_update is Dictionary:
				stat_key = str(raw_update.get("stat", ""))
				raw_delta = raw_update.get("delta")
			elif raw_update is Array and raw_update.size() >= 2:
				stat_key = str(raw_update[0])
				raw_delta = raw_update[1]
			else:
				return {"ok": false, "message": "本地效果 updates 包含无效条目"}
			var error := _merge_effect_delta(deltas, role, stat_key, raw_delta)
			if not error.is_empty():
				return {"ok": false, "message": error}
	else:
		return {"ok": false, "message": "本地效果 updates 必须是字典或数组"}
	return {"ok": true, "deltas": deltas}

func _merge_effect_delta(
	deltas: Dictionary,
	role: String,
	stat_key: String,
	raw_delta: Variant
) -> String:
	var defaults := _default_stats_for_role(role)
	if not defaults.has(stat_key):
		return "未知属性：%s" % stat_key
	if raw_delta is bool or not (raw_delta is int or raw_delta is float):
		return "属性 %s 的变化量不是数字" % stat_key
	var numeric_delta := float(raw_delta)
	if not is_finite(numeric_delta):
		return "属性 %s 的变化量不是有限数字" % stat_key
	deltas[stat_key] = float(deltas.get(stat_key, 0.0)) + numeric_delta
	return ""

func _build_first_full_milestones(
	role: String,
	source_message_id: String,
	source_event_id: String,
	stat_changes: Array[Dictionary]
) -> Array[Dictionary]:
	var milestones: Array[Dictionary] = []
	for change in stat_changes:
		var stat_key := str(change.get("stat", ""))
		var milestone_key := _full_milestone_key(role, stat_key)
		if milestone_key.is_empty() or full_stat_milestones.has(milestone_key):
			continue
		var old_value := float(change.get("old_value", 0.0))
		var new_value := float(change.get("new_value", old_value))
		if old_value >= 100.0 or new_value < 100.0:
			continue
		milestones.append({
			"milestone_id": _deterministic_full_milestone_id(save_id, role, stat_key),
			"kind": "first_stat_max",
			"role_id": role,
			"stat_key": stat_key,
			"old_value": old_value,
			"new_value": 100.0,
			"source_event_id": source_event_id,
			"source_message_id": source_message_id,
			"reached_at": int(Time.get_unix_time_from_system())
		})
	return milestones

func _full_milestone_key(role: String, stat_key: String) -> String:
	if not ROLE_DEFAULT_STATS.has(role):
		return ""
	var defaults: Dictionary = ROLE_DEFAULT_STATS[role]
	if not defaults.has(stat_key):
		return ""
	return "%s:%s" % [role, stat_key]

func _deterministic_full_milestone_id(
	source_save_id: String,
	role: String,
	stat_key: String
) -> String:
	var source := "%s|%s|%s|first-100" % [source_save_id, role, stat_key]
	return "full-" + source.sha256_text().left(48)

func _deterministic_climax_reset(source_event_id: String, role: String) -> float:
	var digest := (source_event_id + "|" + role + "|climax-reset").sha256_buffer()
	return float(int(digest[0]) % 21) if not digest.is_empty() else 0.0

func _normalize_full_stat_milestones(
	raw_value: Variant,
	normalized_stats: Dictionary,
	source_save_id: String
) -> Dictionary:
	var normalized: Dictionary = {}
	if raw_value is Dictionary:
		for raw_key_variant in raw_value:
			var parts := str(raw_key_variant).split(":", false, 1)
			if parts.size() != 2:
				continue
			var role := str(parts[0])
			var stat_key := str(parts[1])
			var milestone_key := _full_milestone_key(role, stat_key)
			var raw_record = raw_value[raw_key_variant]
			if milestone_key.is_empty() or not raw_record is Dictionary:
				continue
			normalized[milestone_key] = _normalize_full_milestone_record(
				raw_record,
				role,
				stat_key,
				source_save_id
			)
	for role_variant in ROLE_DEFAULT_STATS:
		var role := str(role_variant)
		var role_stats = normalized_stats.get(role, {})
		if not role_stats is Dictionary:
			continue
		for stat_variant in ROLE_DEFAULT_STATS[role]:
			var stat_key := str(stat_variant)
			var milestone_key := _full_milestone_key(role, stat_key)
			if normalized.has(milestone_key):
				continue
			if float(role_stats.get(stat_key, 0.0)) < 100.0:
				continue
			normalized[milestone_key] = {
				"milestone_id": _deterministic_full_milestone_id(
					source_save_id,
					role,
					stat_key
				),
				"kind": "preexisting_stat_max",
				"role_id": role,
				"stat_key": stat_key,
				"old_value": 100.0,
				"new_value": 100.0,
				"reached_at": 0
			}
	return normalized

func _normalize_full_milestone_record(
	raw_record: Dictionary,
	role: String,
	stat_key: String,
	source_save_id: String
) -> Dictionary:
	var milestone_id := str(raw_record.get("milestone_id", "")).strip_edges()
	if (
		milestone_id.is_empty()
		or milestone_id.length() > 128
		or TEXT_SANITIZER.contains_nul(milestone_id)
	):
		milestone_id = _deterministic_full_milestone_id(source_save_id, role, stat_key)
	var kind := str(raw_record.get("kind", "preexisting_stat_max"))
	if kind not in ["first_stat_max", "preexisting_stat_max"]:
		kind = "preexisting_stat_max"
	var old_value := _normalize_stat_value(raw_record.get("old_value", 100.0), 100.0)
	var reached_at := 0
	var raw_reached_at = raw_record.get("reached_at", 0)
	if raw_reached_at is int or raw_reached_at is float:
		if is_finite(float(raw_reached_at)):
			reached_at = maxi(0, int(raw_reached_at))
	var normalized := {
		"milestone_id": milestone_id,
		"kind": kind,
		"role_id": role,
		"stat_key": stat_key,
		"old_value": old_value,
		"new_value": 100.0,
		"reached_at": reached_at
	}
	for reference_key in ["source_event_id", "source_message_id"]:
		var reference := str(raw_record.get(reference_key, "")).strip_edges()
		if (
			not reference.is_empty()
			and reference.length() <= 128
			and not TEXT_SANITIZER.contains_nul(reference)
		):
			normalized[reference_key] = reference
	return normalized

func _normalize_applied_local_effect_ids(
	raw_value: Variant,
	history_value: Variant
) -> Array[String]:
	var normalized: Array[String] = []
	if raw_value is Array:
		for raw_id in raw_value:
			_append_normalized_effect_id(normalized, str(raw_id))
	if history_value is Array:
		for raw_entry in history_value:
			if raw_entry is Dictionary:
				_append_normalized_effect_id(
					normalized,
					_extract_effect_id_from_history_entry(raw_entry)
				)
	while normalized.size() > MAX_APPLIED_LOCAL_EFFECT_IDS:
		normalized.pop_front()
	return normalized

func _is_normalized_effect_id_ledger(
	raw_value: Variant,
	normalized: Array[String]
) -> bool:
	if not raw_value is Array:
		return false
	var raw_ids: Array = raw_value
	if raw_ids.size() != normalized.size():
		return false
	for index in normalized.size():
		if not raw_ids[index] is String or raw_ids[index] != normalized[index]:
			return false
	return true

func _append_normalized_effect_id(target: Array[String], raw_id: String) -> void:
	var event_id := raw_id.strip_edges()
	if event_id.is_empty() or event_id.length() > 128 or TEXT_SANITIZER.contains_nul(event_id):
		return
	if event_id in target:
		target.erase(event_id)
	target.append(event_id)
	while target.size() > MAX_APPLIED_LOCAL_EFFECT_IDS:
		target.pop_front()

func _extract_effect_id_from_history_entry(entry: Dictionary) -> String:
	var local_effect = entry.get("local_effect", {})
	if local_effect is Dictionary:
		var local_event_id := str(local_effect.get("event_id", "")).strip_edges()
		if not local_event_id.is_empty():
			return local_event_id
	var action_event = entry.get("action_event", {})
	if action_event is Dictionary:
		var legacy_action_id := str(action_event.get("id", "")).strip_edges()
		if not legacy_action_id.is_empty():
			return legacy_action_id
	var frozen_state = entry.get("state", {})
	if frozen_state is Dictionary:
		var state_event_id := str(
			frozen_state.get("event_id", frozen_state.get("action_id", ""))
		).strip_edges()
		if not state_event_id.is_empty():
			return state_event_id
	return str(entry.get("event_id", "")).strip_edges()

func _find_history_entry_by_effect_id(event_id: String) -> Dictionary:
	for index in range(conversation_history.size() - 1, -1, -1):
		var entry: Dictionary = conversation_history[index]
		if _extract_effect_id_from_history_entry(entry) == event_id:
			return entry
	return {}

func _normalize_stats_by_role(raw_value) -> Dictionary:
	var normalized := {}
	for role_key in ROLES:
		var role := str(role_key)
		var saved_role = raw_value.get(role, {}) if raw_value is Dictionary else {}
		normalized[role] = _normalize_role_stats(role, saved_role)
	return normalized

func _normalize_conversation_history(raw_value) -> Array[Dictionary]:
	var normalized: Array[Dictionary] = []
	if raw_value is Array:
		for raw_entry in raw_value:
			if not raw_entry is Dictionary:
				continue
			var text := str(raw_entry.get("text", "")).strip_edges()
			var sender := str(raw_entry.get("sender", ""))
			if text.is_empty() or sender not in ["user", "ai"]:
				continue
			var entry: Dictionary = raw_entry.duplicate(true)
			var entry_id := str(entry.get("id", "")).strip_edges()
			entry["id"] = entry_id if not entry_id.is_empty() else new_local_id("history")
			entry["sender"] = sender
			entry["role"] = str(entry.get("role", ""))
			entry["text"] = text
			var status := str(entry.get("status", "sent"))
			if status == "pending":
				status = "failed"
				entry["error"] = "应用在发送过程中关闭"
			entry["status"] = status if status in ["sent", "failed"] else "sent"
			normalized.append(entry)
	while normalized.size() > MAX_CONVERSATION_HISTORY:
		normalized.pop_front()
	return normalized

func _generate_save_id() -> String:
	var random := RandomNumberGenerator.new()
	random.randomize()
	return "%d-%d" % [int(Time.get_unix_time_from_system()), random.randi()]
