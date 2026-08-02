class_name ConversationArchiveStore
extends RefCounted

const TEXT_SANITIZER := preload("res://scripts/domain/TextSanitizer.gd")
const ARCHIVE_VERSION := 1
const ARCHIVE_DIR := "user://SpringHaven/conversation_archive"
const MAX_SEARCH_RESULTS := 2000

static var _last_error := ""

static func upsert_entries(entries: Array, save_id: String) -> bool:
	_last_error = ""
	if save_id.begins_with("diagnostic-") or entries.is_empty():
		return true
	if not _ensure_archive_directory():
		return false
	var grouped := {}
	for entry_variant in entries:
		if not entry_variant is Dictionary:
			continue
		var entry := _normalize_entry(entry_variant as Dictionary, save_id)
		if entry.is_empty():
			continue
		var date_key := str(entry.archive_date)
		if not grouped.has(date_key):
			grouped[date_key] = []
		(grouped[date_key] as Array).append(entry)
	for date_variant in grouped:
		var date_key := str(date_variant)
		var document := _load_date_document(date_key)
		var merged: Array = document.get("entries", []).duplicate(true)
		var index_by_id := {}
		for index in merged.size():
			var current = merged[index]
			if current is Dictionary:
				index_by_id[str(current.get("id", ""))] = index
		for entry_variant in grouped[date_key]:
			var entry: Dictionary = entry_variant
			var entry_id := str(entry.id)
			if index_by_id.has(entry_id):
				merged[int(index_by_id[entry_id])] = entry
			else:
				index_by_id[entry_id] = merged.size()
				merged.append(entry)
		merged.sort_custom(_entry_before)
		document = {
			"version": ARCHIVE_VERSION,
			"date": date_key,
			"updated_at": int(Time.get_unix_time_from_system()),
			"entries": merged,
		}
		if not _atomic_write(_date_path(date_key), JSON.stringify(document, "\t")):
			return false
	return true

static func list_dates(save_filter := "") -> Array[Dictionary]:
	_last_error = ""
	var result: Array[Dictionary] = []
	if not _ensure_archive_directory():
		return result
	var directory := DirAccess.open(ARCHIVE_DIR)
	if directory == null:
		_last_error = "无法读取聊天归档目录"
		return result
	for file_name_variant in directory.get_files():
		var file_name := str(file_name_variant)
		if not file_name.ends_with(".json"):
			continue
		var date_key := file_name.trim_suffix(".json")
		if not _is_date_key(date_key):
			continue
		var document := _load_date_document(date_key)
		var entries = document.get("entries", [])
		if not entries is Array:
			continue
		var matching_count := 0
		var latest_at := 0
		for entry_variant in entries:
			if not entry_variant is Dictionary:
				continue
			if not save_filter.is_empty() and str(entry_variant.get("archive_save_id", "")) != save_filter:
				continue
			matching_count += 1
			latest_at = maxi(latest_at, int(entry_variant.get("created_at", 0)))
		if matching_count == 0:
			continue
		result.append({
			"date": date_key,
			"count": matching_count,
			"latest_at": latest_at,
		})
	result.sort_custom(func(a: Dictionary, b: Dictionary): return str(a.date) > str(b.date))
	return result

static func load_date(date_key: String) -> Array[Dictionary]:
	if not _is_date_key(date_key):
		return []
	var result: Array[Dictionary] = []
	var entries = _load_date_document(date_key).get("entries", [])
	if entries is Array:
		for entry_variant in entries:
			if entry_variant is Dictionary:
				result.append((entry_variant as Dictionary).duplicate(true))
	return result

static func search_entries(
	query: String,
	date_filter := "",
	role_filter := "",
	sender_filter := "",
	save_filter := "",
	limit := MAX_SEARCH_RESULTS
) -> Array[Dictionary]:
	var normalized_query := TEXT_SANITIZER.strip_nul(query).strip_edges()
	var date_keys: Array[String] = []
	if _is_date_key(date_filter):
		date_keys.append(date_filter)
	else:
		for summary in list_dates():
			date_keys.append(str(summary.date))
	var result: Array[Dictionary] = []
	for date_key in date_keys:
		var entries := load_date(date_key)
		for index in range(entries.size() - 1, -1, -1):
			var entry: Dictionary = entries[index]
			if not save_filter.is_empty() and str(entry.get("archive_save_id", "")) != save_filter:
				continue
			if not role_filter.is_empty() and str(entry.get("role", "")) != role_filter:
				continue
			if not sender_filter.is_empty() and str(entry.get("sender", "")) != sender_filter:
				continue
			if not normalized_query.is_empty() and str(entry.get("text", "")).findn(normalized_query) < 0:
				continue
			result.append(entry.duplicate(true))
			if result.size() >= maxi(1, limit):
				return result
	return result

static func journey_summaries() -> Array[Dictionary]:
	var grouped := {}
	for date_summary in list_dates():
		for entry in load_date(str(date_summary.get("date", ""))):
			var journey_id := str(entry.get("archive_save_id", "")).strip_edges()
			if journey_id.is_empty() or journey_id.begins_with("diagnostic-"):
				continue
			var summary: Dictionary = grouped.get(journey_id, {
				"save_id": journey_id,
				"message_count": 0,
				"created_at": 0,
				"updated_at": 0,
				"role_ids": [],
			})
			var created_at := int(entry.get("created_at", 0))
			summary.message_count = int(summary.message_count) + 1
			if int(summary.created_at) <= 0 or (created_at > 0 and created_at < int(summary.created_at)):
				summary.created_at = created_at
			summary.updated_at = maxi(int(summary.updated_at), created_at)
			var role := str(entry.get("role", ""))
			var roles: Array = summary.role_ids
			if role in ["ling", "nai"] and role not in roles:
				roles.append(role)
			summary.role_ids = roles
			grouped[journey_id] = summary
	var result: Array[Dictionary] = []
	for summary_variant in grouped.values():
		if summary_variant is Dictionary:
			result.append((summary_variant as Dictionary).duplicate(true))
	result.sort_custom(func(a: Dictionary, b: Dictionary): return int(a.updated_at) > int(b.updated_at))
	return result

static func entries_for_save(save_id: String, limit := 64) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var requested := clampi(limit, 1, MAX_SEARCH_RESULTS)
	for date_summary in list_dates():
		var entries := load_date(str(date_summary.get("date", "")))
		for index in range(entries.size() - 1, -1, -1):
			var entry: Dictionary = entries[index]
			if str(entry.get("archive_save_id", "")) != save_id:
				continue
			result.append(entry.duplicate(true))
			if result.size() >= requested:
				result.reverse()
				return result
	result.reverse()
	return result

static func date_key_from_unix(unix_time: int) -> String:
	var zone := Time.get_time_zone_from_system()
	var local_unix := maxi(0, unix_time) + int(zone.get("bias", 0)) * 60
	var value := Time.get_datetime_dict_from_unix_time(local_unix)
	return "%04d-%02d-%02d" % [int(value.year), int(value.month), int(value.day)]

static func format_local_timestamp(unix_time: int) -> String:
	if unix_time <= 0:
		return "时间未知"
	var zone := Time.get_time_zone_from_system()
	var local_unix := unix_time + int(zone.get("bias", 0)) * 60
	var value := Time.get_datetime_dict_from_unix_time(local_unix)
	return "%04d-%02d-%02d  %02d:%02d:%02d" % [
		int(value.year), int(value.month), int(value.day),
		int(value.hour), int(value.minute), int(value.second),
	]

static func get_last_error() -> String:
	return _last_error

static func _normalize_entry(raw: Dictionary, save_id: String) -> Dictionary:
	var text := TEXT_SANITIZER.strip_nul(str(raw.get("text", ""))).strip_edges()
	var sender := str(raw.get("sender", ""))
	var entry_id := TEXT_SANITIZER.strip_nul(str(raw.get("id", ""))).strip_edges()
	if text.is_empty() or sender not in ["user", "ai"] or entry_id.is_empty():
		return {}
	var result := raw.duplicate(true)
	var created_at := int(result.get("created_at", Time.get_unix_time_from_system()))
	if created_at <= 0:
		created_at = int(Time.get_unix_time_from_system())
	result["id"] = entry_id
	result["sender"] = sender
	result["text"] = text
	result["created_at"] = created_at
	result["archive_date"] = date_key_from_unix(created_at)
	result["archive_save_id"] = save_id
	result["archived_at"] = int(Time.get_unix_time_from_system())
	return result

static func _load_date_document(date_key: String) -> Dictionary:
	var fallback := {
		"version": ARCHIVE_VERSION,
		"date": date_key,
		"updated_at": 0,
		"entries": [],
	}
	if not _is_date_key(date_key):
		return fallback
	for path in [_date_path(date_key), _date_path(date_key) + ".bak"]:
		if not FileAccess.file_exists(path):
			continue
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			continue
		var parsed = JSON.parse_string(file.get_as_text())
		file.close()
		if parsed is Dictionary and parsed.get("entries", []) is Array:
			return (parsed as Dictionary).duplicate(true)
	return fallback

static func _date_path(date_key: String) -> String:
	return ARCHIVE_DIR.path_join("%s.json" % date_key)

static func _is_date_key(value: String) -> bool:
	if value.length() != 10 or value.substr(4, 1) != "-" or value.substr(7, 1) != "-":
		return false
	for index in value.length():
		if index in [4, 7]:
			continue
		var code := value.unicode_at(index)
		if code < 48 or code > 57:
			return false
	var month := value.substr(5, 2).to_int()
	var day := value.substr(8, 2).to_int()
	return month >= 1 and month <= 12 and day >= 1 and day <= 31

static func _entry_before(a: Dictionary, b: Dictionary) -> bool:
	var a_time := int(a.get("created_at", 0))
	var b_time := int(b.get("created_at", 0))
	if a_time == b_time:
		return str(a.get("id", "")) < str(b.get("id", ""))
	return a_time < b_time

static func _ensure_archive_directory() -> bool:
	var error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ARCHIVE_DIR))
	if error not in [OK, ERR_ALREADY_EXISTS]:
		_last_error = "无法创建聊天归档目录：%s" % error_string(error)
		return false
	return true

static func _atomic_write(path: String, serialized: String) -> bool:
	var temp_path := path + ".tmp"
	var backup_path := path + ".bak"
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		_last_error = "无法创建聊天归档临时文件：%s" % error_string(FileAccess.get_open_error())
		return false
	file.store_string(serialized)
	file.flush()
	var write_error := file.get_error()
	file.close()
	var temp_absolute := ProjectSettings.globalize_path(temp_path)
	var path_absolute := ProjectSettings.globalize_path(path)
	var backup_absolute := ProjectSettings.globalize_path(backup_path)
	if write_error != OK:
		DirAccess.remove_absolute(temp_absolute)
		_last_error = "写入聊天归档失败：%s" % error_string(write_error)
		return false
	var had_existing := FileAccess.file_exists(path)
	if had_existing:
		if FileAccess.file_exists(backup_path):
			DirAccess.remove_absolute(backup_absolute)
		var backup_error := DirAccess.rename_absolute(path_absolute, backup_absolute)
		if backup_error != OK:
			DirAccess.remove_absolute(temp_absolute)
			_last_error = "备份聊天归档失败：%s" % error_string(backup_error)
			return false
	var commit_error := DirAccess.rename_absolute(temp_absolute, path_absolute)
	if commit_error != OK:
		if had_existing and FileAccess.file_exists(backup_path):
			DirAccess.rename_absolute(backup_absolute, path_absolute)
		_last_error = "提交聊天归档失败：%s" % error_string(commit_error)
		return false
	_last_error = ""
	return true
