class_name PlaytestDiagnostics
extends RefCounted

const SCHEMA_VERSION := 1
const MAX_LOG_FILES_PER_DIRECTORY := 3
const MAX_LOG_BYTES_PER_FILE := 196608


static func create_bundle(
	core_client: Node,
	settings_snapshot: Dictionary,
	state_summary: Dictionary,
	options: Dictionary = {}
) -> Dictionary:
	var output_directory := str(options.get(
		"output_directory", "user://SpringHaven/diagnostics"
	)).strip_edges()
	if output_directory.is_empty():
		return {"ok": false, "message": "诊断包输出目录为空"}
	var absolute_output := ProjectSettings.globalize_path(output_directory).simplify_path()
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute_output)
	if directory_error != OK:
		return {"ok": false, "message": "无法创建诊断目录：%s" % error_string(directory_error)}

	var managed_status: Dictionary = {}
	if is_instance_valid(core_client) and core_client.has_method("get_managed_core_status"):
		var managed_variant = core_client.call("get_managed_core_status")
		if managed_variant is Dictionary:
			managed_status = managed_variant
	var provider_result: Dictionary = {"ok": false, "message": "Core 客户端不可用"}
	if is_instance_valid(core_client) and core_client.has_method("get_provider_status"):
		var provider_variant = await core_client.call("get_provider_status")
		if provider_variant is Dictionary:
			provider_result = provider_variant
	var maintenance_result: Dictionary = {"ok": false, "message": "Core 客户端不可用"}
	if is_instance_valid(core_client) and core_client.has_method("get_maintenance_status"):
		var maintenance_variant = await core_client.call("get_maintenance_status")
		if maintenance_variant is Dictionary:
			maintenance_result = maintenance_variant

	var now := Time.get_datetime_dict_from_system()
	var stamp := str(options.get("file_stamp", "")).strip_edges()
	if stamp.is_empty():
		stamp = "%04d%02d%02d-%02d%02d%02d" % [
			int(now.year), int(now.month), int(now.day),
			int(now.hour), int(now.minute), int(now.second),
		]
	var output_path := absolute_output.path_join("spring-haven-diagnostics-%s.zip" % stamp)
	var include_sanitized_logs := bool(options.get("include_sanitized_logs", false))
	var entries := {
		"manifest.json": {
			"schema_version": SCHEMA_VERSION,
			"generated_at_unix": int(Time.get_unix_time_from_system()),
			"application": str(ProjectSettings.get_setting("application/config/name", "Spring Haven")),
			"application_version": str(ProjectSettings.get_setting("application/config/version", "0.6.0")),
			"engine": Engine.get_version_info(),
			"system": {
				"os": OS.get_name(),
				"os_version": OS.get_version(),
				"locale": OS.get_locale(),
				"processor_count": OS.get_processor_count(),
				"rendering_method": str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "")),
			},
			"privacy": {
				"contains_chat_text": false,
				"contains_persona": false,
				"contains_knowledge_documents": false,
				"contains_database": false,
				"contains_api_keys": false,
				"contains_log_text": include_sanitized_logs,
				"log_text_policy": "pattern-redacted" if include_sanitized_logs else "inventory-only",
			},
		},
		"core-status.json": {
			"active": bool(core_client.call("is_active"))
				if is_instance_valid(core_client) and core_client.has_method("is_active")
				else false,
			"managed": _managed_status_summary(managed_status),
			"provider": provider_result,
			"maintenance": maintenance_result,
		},
		"settings-summary.json": settings_snapshot,
		"state-summary.json": state_summary,
	}
	var log_directories: Array[String] = []
	var configured_logs = options.get("log_directories", null)
	if configured_logs is Array:
		for directory_variant in configured_logs:
			var directory := str(directory_variant).strip_edges()
			if not directory.is_empty() and directory not in log_directories:
				log_directories.append(directory)
	else:
		log_directories = _default_log_directories(managed_status)
	_collect_log_inventory(entries, log_directories)
	if include_sanitized_logs:
		_collect_log_entries(entries, log_directories)

	var packer := ZIPPacker.new()
	var open_error := packer.open(output_path)
	if open_error != OK:
		return {"ok": false, "message": "无法创建诊断包：%s" % error_string(open_error)}
	for entry_name_variant in entries:
		var entry_name := str(entry_name_variant)
		var content_variant = sanitize_for_export(entries[entry_name_variant])
		var content := (
			JSON.stringify(content_variant, "  ") + "\n"
			if entry_name.ends_with(".json")
			else str(content_variant)
		)
		var start_error := packer.start_file(entry_name)
		if start_error != OK:
			packer.close()
			return {"ok": false, "message": "无法写入诊断条目：%s" % entry_name}
		packer.write_file(content.to_utf8_buffer())
		packer.close_file()
	packer.close()
	return {"ok": true, "path": output_path, "entry_count": entries.size()}


static func sanitize_for_export(value: Variant, key_hint: String = "") -> Variant:
	var normalized_key := key_hint.to_lower()
	if _is_sensitive_key(normalized_key):
		if value is bool and (
			"configured" in normalized_key
			or "enabled" in normalized_key
			or "ready" in normalized_key
		):
			return value
		return "[redacted]"
	if _is_private_content_key(normalized_key):
		return "[redacted-private-content]"
	if _is_path_key(normalized_key) and value is String and not str(value).is_empty():
		return "<local path>"
	if value is Dictionary:
		var sanitized := {}
		for child_key_variant in value:
			var child_key := str(child_key_variant)
			sanitized[child_key] = sanitize_for_export(value[child_key_variant], child_key)
		return sanitized
	if value is Array:
		var sanitized_array: Array = []
		for item in value:
			sanitized_array.append(sanitize_for_export(item, key_hint))
		return sanitized_array
	if value is String:
		return _sanitize_text(value)
	return value


static func _managed_status_summary(status: Dictionary) -> Dictionary:
	return {
		"owned": bool(status.get("owned", false)),
		"running": bool(status.get("running", false)),
		"start_count": int(status.get("start_count", 0)),
		"last_error": str(status.get("last_error", "")),
		"runtime_created": bool(status.get("runtime_created", false)),
		"runtime_error": str(status.get("runtime_error", "")),
	}


static func _default_log_directories(managed_status: Dictionary) -> Array[String]:
	var directories: Array[String] = ["user://logs"]
	var runtime_root := str(managed_status.get("runtime_root", "")).strip_edges()
	if not runtime_root.is_empty():
		var core_logs := runtime_root.path_join("logs")
		if core_logs not in directories:
			directories.append(core_logs)
	return directories


static func _collect_log_entries(entries: Dictionary, directories: Array[String]) -> void:
	for directory_index in directories.size():
		var directory := directories[directory_index]
		if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(directory)):
			continue
		var paths: Array[String] = []
		for filename_variant in DirAccess.get_files_at(directory):
			var filename := str(filename_variant)
			if filename.get_extension().to_lower() != "log":
				continue
			paths.append(directory.path_join(filename))
		paths.sort_custom(func(left: String, right: String) -> bool:
			return FileAccess.get_modified_time(left) > FileAccess.get_modified_time(right)
		)
		for index in mini(MAX_LOG_FILES_PER_DIRECTORY, paths.size()):
			var source_path := paths[index]
			var bytes := FileAccess.get_file_as_bytes(source_path)
			if bytes.size() > MAX_LOG_BYTES_PER_FILE:
				bytes = bytes.slice(bytes.size() - MAX_LOG_BYTES_PER_FILE)
			var entry_name := "logs/source-%d-%d-%s" % [
				directory_index,
				index,
				source_path.get_file().validate_filename(),
			]
			entries[entry_name] = bytes.get_string_from_utf8()


static func _collect_log_inventory(entries: Dictionary, directories: Array[String]) -> void:
	var inventory: Array[Dictionary] = []
	for directory_index in directories.size():
		var directory := directories[directory_index]
		if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(directory)):
			continue
		for filename_variant in DirAccess.get_files_at(directory):
			var filename := str(filename_variant)
			if filename.get_extension().to_lower() != "log":
				continue
			var source_path := directory.path_join(filename)
			inventory.append({
				"source": directory_index,
				"filename": filename.validate_filename(),
				"bytes": FileAccess.get_size(source_path),
				"modified_at_unix": FileAccess.get_modified_time(source_path),
			})
	inventory.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return int(left.get("modified_at_unix", 0)) > int(right.get("modified_at_unix", 0))
	)
	entries["logs/inventory.json"] = inventory


static func _is_sensitive_key(key: String) -> bool:
	return (
		"api_key" in key
		or "apikey" in key
		or "authorization" in key
		or "access_token" in key
		or "refresh_token" in key
		or key == "token"
		or key.ends_with("_secret")
		or key == "secret"
		or key == "password"
	)


static func _is_path_key(key: String) -> bool:
	return key == "path" or key.ends_with("_path") or key.ends_with("_root")


static func _is_private_content_key(key: String) -> bool:
	return key in [
		"chat_text", "conversation_history", "history", "messages", "message_text",
		"prompt", "system_prompt", "content", "reply", "request_body", "response_body",
		"persona", "persona_prompt", "knowledge_text", "document_text", "source_text",
	]


static func _sanitize_text(value: String) -> String:
	var sanitized := value
	var replacements := [
		{"pattern": "(?i)sk-[A-Za-z0-9._-]{12,}", "replacement": "[redacted-api-key]"},
		{"pattern": "(?i)Bearer\\s+[A-Za-z0-9._-]{12,}", "replacement": "Bearer [redacted]"},
		{"pattern": "(?i)(X-API-Key\\s*[:=]\\s*)[^\\s,;]+", "replacement": "$1[redacted]"},
		{"pattern": "(?i)((?:api[_-]?key|access[_-]?token|refresh[_-]?token|secret|password)\\s*[:=]\\s*)[^\\s,;]+", "replacement": "$1[redacted]"},
		{"pattern": "(?i)[A-Z]:[\\\\/]Users[\\\\/][^\\\\/\\r\\n]+", "replacement": "<USER_HOME>"},
		{"pattern": "(?im)^([^\\r\\n]{0,120}(?:reply|prompt|history|conversation|user_text|message_text|request_body|response_body|content)\\s*[:=]\\s*).*$", "replacement": "$1[redacted-conversation]"},
	]
	for replacement_variant in replacements:
		var replacement: Dictionary = replacement_variant
		var regex := RegEx.new()
		if regex.compile(str(replacement.pattern)) == OK:
			sanitized = regex.sub(sanitized, str(replacement.replacement), true)
	return sanitized
