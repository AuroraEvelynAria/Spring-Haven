extends Node

signal interaction_tuning_changed(role: String, action: String)
signal ambient_dialogue_settings_changed(config: Dictionary)
signal runtime_tuning_changed(config: Dictionary)

const INTERACTION_RULES := preload("res://scripts/domain/InteractionRules.gd")
const TUNING_PROFILES := preload("res://scripts/domain/InteractionTuningProfiles.gd")
const RUNTIME_TUNING := preload("res://scripts/domain/DeveloperRuntimeTuning.gd")

# get_runtime_tuning_value 是每帧热路径（GameWorld/PortraitRig/LifeSim），
# 缓存 normalize 结果，避免每帧重建 38 项参数字典；源字典变化时自动失效。
var _runtime_tuning_raw_cache: Dictionary = {}
var _runtime_tuning_normalized_cache: Dictionary = {}

const RESOLUTIONS := {
	"1280x720 (16:9)": Vector2i(1280, 720),
	"1600x900 (16:9)": Vector2i(1600, 900),
	"1920x1080 (16:9)": Vector2i(1920, 1080),
	"2560x1440 (16:9)": Vector2i(2560, 1440),
	"1280x800 (16:10)": Vector2i(1280, 800),
	"1680x1050 (16:10)": Vector2i(1680, 1050),
	"1920x1200 (16:10)": Vector2i(1920, 1200),
	"2560x1600 (16:10)": Vector2i(2560, 1600)
}
const DEFAULT_RESOLUTION := "1280x720 (16:9)"
const INTERACTION_TUNING_SCHEMA_VERSION := TUNING_PROFILES.SCHEMA_VERSION
const SETTINGS_PATH := "user://settings.cfg"
const SETTINGS_TEMP_PATH := SETTINGS_PATH + ".tmp"
const SETTINGS_BACKUP_PATH := SETTINGS_PATH + ".bak"
const AMBIENT_DIALOGUE_DEFAULTS := {
	"enabled": true,
	"idle_minutes": 30,
	"cooldown_min_minutes": 30,
	"cooldown_max_minutes": 90,
	"turns_min": 2,
	"turns_max": 4,
	"notifications_enabled": true,
	"memory_enabled": true,
}
const AMBIENT_IDLE_MINUTES_MIN := 5
const AMBIENT_IDLE_MINUTES_MAX := 720
const AMBIENT_COOLDOWN_MINUTES_MIN := 10
const AMBIENT_COOLDOWN_MINUTES_MAX := 1440
const AMBIENT_TURNS_MIN := 2
const AMBIENT_TURNS_MAX := 8

var config := ConfigFile.new()
var settings: Dictionary = {
	"display": {"view_mode": "2d", "resolution": DEFAULT_RESOLUTION, "fullscreen": false, "vsync": true},
	"audio": {"master": 0.8, "music": 0.7, "voice": 1.0},
	"tts": {"voice_ling": "", "voice_nai": ""},
	"ui": {
		"theme": "amber",
		"font_size": 15,
		"font_family": "system",
		"language": "zh_CN",
		"custom_bg": "#1A120E",
		"custom_primary": "#F5A97F",
		"custom_accent": "#E8C97A"
	},
	"life_simulation": {
		"enabled": true,
		"idle_minutes": 30,
		"cooldown_min_minutes": 30,
		"cooldown_max_minutes": 90,
		"turns_min": 2,
		"turns_max": 4,
		"notifications_enabled": true,
		"memory_enabled": true,
	},
	"developer": {
		"interaction_schema_version": INTERACTION_TUNING_SCHEMA_VERSION,
		"interaction_delta_overrides": {},
		"runtime_tuning": RUNTIME_TUNING.defaults(),
		"role_default_stats": {},
	}
}

var _applying := false
var _settings_main_is_invalid := false
var last_save_error := ""

func _ready() -> void:
	load_config()

func load_config() -> void:
	_recover_interrupted_settings_commit()
	if FileAccess.file_exists(SETTINGS_PATH):
		var load_error := config.load(SETTINGS_PATH)
		if load_error != OK:
			var recovery_source := _load_valid_settings_recovery_candidate()
			if recovery_source.is_empty():
				config = ConfigFile.new()
				_settings_main_is_invalid = true
				last_save_error = "无法读取设置，且没有有效备份：%s" % error_string(load_error)
				push_warning(last_save_error)
				_normalize_developer_settings()
				apply_all()
				return
			push_warning(
				"无法读取设置主文件（%s），本次已改用%s"
				% [error_string(load_error), recovery_source]
			)
		for section in config.get_sections():
			if not settings.has(section):
				continue
			for key in config.get_section_keys(section):
				if settings[section].has(key):
					settings[section][key] = config.get_value(section, key)
	var previous_developer := _developer_settings_snapshot()
	var previous_config := _snapshot_config_developer_section()
	var developer_settings_changed := _normalize_developer_settings()
	var ambient_settings_changed := _normalize_ambient_dialogue_settings()
	if (developer_settings_changed or ambient_settings_changed) and not save():
		_restore_developer_settings(previous_developer, previous_config)
		push_warning("设置规范化结果尚未写入磁盘：%s" % last_save_error)
	apply_all()

func save() -> bool:
	for section in settings:
		for key in settings[section]:
			config.set_value(section, key, settings[section][key])
	var save_error := config.save(SETTINGS_TEMP_PATH)
	if save_error != OK:
		_discard_settings_temp_file()
		last_save_error = "无法保存设置：%s" % error_string(save_error)
		push_warning(last_save_error)
		return false
	if not _commit_settings_temp_file():
		return false
	last_save_error = ""
	return true

func apply_all() -> void:
	if _applying:
		return
	_applying = true
	apply_display()
	ThemeMgr.apply_theme(str(settings.ui.theme))
	Global.view_mode_changed.emit(str(settings.display.view_mode))
	Global.font_size_changed.emit(int(settings.ui.font_size))
	if has_node("/root/Audio"):
		Audio.apply_volume()
	_applying = false

func apply_display() -> void:
	var res_key := str(settings.display.get("resolution", DEFAULT_RESOLUTION))
	if RESOLUTIONS.has(res_key) and not bool(settings.display.fullscreen):
		var size: Vector2i = RESOLUTIONS[res_key]
		var screen := DisplayServer.window_get_current_screen()
		var usable_rect := DisplayServer.screen_get_usable_rect(screen)
		size.x = mini(size.x, usable_rect.size.x)
		size.y = mini(size.y, usable_rect.size.y)
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(size)
		DisplayServer.window_set_position(usable_rect.position + (usable_rect.size - size) / 2)
	if bool(settings.display.fullscreen):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if bool(settings.display.vsync) else DisplayServer.VSYNC_DISABLED)

func get_resolution() -> String:
	return str(settings.display.get("resolution", DEFAULT_RESOLUTION))

func set_resolution(key: String) -> void:
	if not RESOLUTIONS.has(key):
		return
	settings.display.resolution = key
	save()
	apply_display()

func get_setting(section: String, key: String):
	return settings.get(section, {}).get(key, null)

func get_tts_voices() -> Dictionary:
	var values: Dictionary = settings.get("tts", {})
	return {
		"ling": str(values.get("voice_ling", "")).strip_edges(),
		"nai": str(values.get("voice_nai", "")).strip_edges(),
	}

func set_tts_voices(voices: Dictionary) -> bool:
	if not settings.has("tts"):
		settings["tts"] = {"voice_ling": "", "voice_nai": ""}
	for role in ["ling", "nai"]:
		if voices.has(role):
			settings.tts["voice_%s" % role] = str(voices[role]).replace(String.chr(0), " ").strip_edges().left(512)
	return save()

func set_setting(section: String, key: String, value) -> void:
	if not settings.has(section) or not settings[section].has(key):
		return
	# Developer interaction tuning has stricter validation and rollback rules.
	# Keep it behind the dedicated API instead of allowing this generic setter
	# to bypass the sparse schema.
	if section in ["developer", "life_simulation"]:
		push_warning("开发者配置必须通过专用 API 修改")
		return
	settings[section][key] = value
	save()
	apply_all()

func set_custom_colors(bg: String, primary: String, accent: String) -> void:
	settings.ui.custom_bg = bg
	settings.ui.custom_primary = primary
	settings.ui.custom_accent = accent
	settings.ui.theme = "custom"
	save()
	ThemeMgr.apply_custom_theme(bg, primary, accent)

func get_ambient_dialogue_settings() -> Dictionary:
	var value = settings.get("life_simulation", {})
	return _normalized_ambient_dialogue_value(value)

func set_ambient_dialogue_settings(values: Dictionary) -> Dictionary:
	var merged := get_ambient_dialogue_settings()
	for key_variant in values:
		var key := str(key_variant)
		if not AMBIENT_DIALOGUE_DEFAULTS.has(key):
			return _developer_result(false, "未知后台互聊配置：%s" % key)
		merged[key] = values[key_variant]
	var validation_error := _ambient_dialogue_validation_error(merged)
	if not validation_error.is_empty():
		return _developer_result(false, validation_error)
	var normalized := _normalized_ambient_dialogue_value(merged)
	var previous = settings.get("life_simulation", {})
	var previous_settings := (
		(previous as Dictionary).duplicate(true)
		if previous is Dictionary
		else {}
	)
	var previous_config := _snapshot_config_section("life_simulation")
	settings["life_simulation"] = normalized.duplicate(true)
	if not save():
		settings["life_simulation"] = previous_settings
		_restore_config_section("life_simulation", previous_config)
		return _developer_result(false, last_save_error)
	ambient_dialogue_settings_changed.emit(normalized.duplicate(true))
	return {
		"ok": true,
		"message": "后台生活配置已保存",
		"settings": normalized.duplicate(true),
	}

func _normalize_ambient_dialogue_settings() -> bool:
	var raw = settings.get("life_simulation", {})
	var normalized := _normalized_ambient_dialogue_value(raw)
	var raw_dictionary: Dictionary = raw if raw is Dictionary else {}
	var changed := JSON.stringify(raw_dictionary) != JSON.stringify(normalized)
	settings["life_simulation"] = normalized
	return changed

func _normalized_ambient_dialogue_value(raw_value: Variant) -> Dictionary:
	var raw: Dictionary = raw_value if raw_value is Dictionary else {}
	var result := AMBIENT_DIALOGUE_DEFAULTS.duplicate(true)
	for key in ["enabled", "notifications_enabled", "memory_enabled"]:
		if raw.get(key) is bool:
			result[key] = bool(raw[key])
	result["idle_minutes"] = _normalized_setting_int(
		raw.get("idle_minutes"),
		int(AMBIENT_DIALOGUE_DEFAULTS.idle_minutes),
		AMBIENT_IDLE_MINUTES_MIN,
		AMBIENT_IDLE_MINUTES_MAX
	)
	result["cooldown_min_minutes"] = _normalized_setting_int(
		raw.get("cooldown_min_minutes"),
		int(AMBIENT_DIALOGUE_DEFAULTS.cooldown_min_minutes),
		AMBIENT_COOLDOWN_MINUTES_MIN,
		AMBIENT_COOLDOWN_MINUTES_MAX
	)
	result["cooldown_max_minutes"] = _normalized_setting_int(
		raw.get("cooldown_max_minutes"),
		int(AMBIENT_DIALOGUE_DEFAULTS.cooldown_max_minutes),
		AMBIENT_COOLDOWN_MINUTES_MIN,
		AMBIENT_COOLDOWN_MINUTES_MAX
	)
	result["turns_min"] = _normalized_setting_int(
		raw.get("turns_min"),
		int(AMBIENT_DIALOGUE_DEFAULTS.turns_min),
		AMBIENT_TURNS_MIN,
		AMBIENT_TURNS_MAX
	)
	result["turns_max"] = _normalized_setting_int(
		raw.get("turns_max"),
		int(AMBIENT_DIALOGUE_DEFAULTS.turns_max),
		AMBIENT_TURNS_MIN,
		AMBIENT_TURNS_MAX
	)
	if int(result.cooldown_max_minutes) < int(result.cooldown_min_minutes):
		result.cooldown_max_minutes = result.cooldown_min_minutes
	if int(result.turns_max) < int(result.turns_min):
		result.turns_max = result.turns_min
	return result

func _ambient_dialogue_validation_error(values: Dictionary) -> String:
	for key in ["enabled", "notifications_enabled", "memory_enabled"]:
		if not values.get(key) is bool:
			return "%s 必须是开关值" % key
	var ranges := {
		"idle_minutes": Vector2i(AMBIENT_IDLE_MINUTES_MIN, AMBIENT_IDLE_MINUTES_MAX),
		"cooldown_min_minutes": Vector2i(
			AMBIENT_COOLDOWN_MINUTES_MIN, AMBIENT_COOLDOWN_MINUTES_MAX
		),
		"cooldown_max_minutes": Vector2i(
			AMBIENT_COOLDOWN_MINUTES_MIN, AMBIENT_COOLDOWN_MINUTES_MAX
		),
		"turns_min": Vector2i(AMBIENT_TURNS_MIN, AMBIENT_TURNS_MAX),
		"turns_max": Vector2i(AMBIENT_TURNS_MIN, AMBIENT_TURNS_MAX),
	}
	for key_variant in ranges:
		var key := str(key_variant)
		var value = values.get(key)
		if value is bool or not (value is int or value is float) or not is_finite(float(value)):
			return "%s 必须是有限数字" % key
		var allowed: Vector2i = ranges[key]
		if int(value) < allowed.x or int(value) > allowed.y:
			return "%s 必须在 %d–%d 之间" % [key, allowed.x, allowed.y]
	if int(values.cooldown_min_minutes) > int(values.cooldown_max_minutes):
		return "最短冷却不能大于最长冷却"
	if int(values.turns_min) > int(values.turns_max):
		return "最少轮数不能大于最多轮数"
	return ""

func _normalized_setting_int(value: Variant, fallback: int, minimum: int, maximum: int) -> int:
	if value is bool or not (value is int or value is float):
		return fallback
	var numeric := float(value)
	if not is_finite(numeric):
		return fallback
	return clampi(int(numeric), minimum, maximum)

func get_interaction_overrides(role: String, action: String) -> Dictionary:
	if not _is_valid_interaction_path(role, action):
		return {}
	var save_id := _active_interaction_save_id()
	if save_id.is_empty() or not _ensure_interaction_settings_current(save_id):
		return {}
	var profile := _interaction_overrides_for_save(save_id)
	var role_overrides_variant = profile.get(role, {})
	if not role_overrides_variant is Dictionary:
		return {}
	var action_overrides_variant = (role_overrides_variant as Dictionary).get(action, {})
	return (
		(action_overrides_variant as Dictionary).duplicate(true)
		if action_overrides_variant is Dictionary
		else {}
	)

func get_effective_interaction_updates(role: String, action: String) -> Array:
	return INTERACTION_RULES.resolve_updates(
		role,
		action,
		get_interaction_overrides(role, action)
	)

func set_interaction_action_overrides(
	role: String,
	action: String,
	values: Dictionary
) -> Dictionary:
	if not _is_valid_interaction_path(role, action):
		return _developer_result(false, "未知角色或动作：%s/%s" % [role, action])
	var save_id := _active_interaction_save_id()
	if save_id.is_empty():
		return _developer_result(false, "当前没有已加载的旅程，无法保存互动数值")
	if not _ensure_interaction_settings_current(save_id):
		return _developer_result(false, last_save_error)
	var normalized_result := _normalize_action_overrides(role, action, values, true)
	if not bool(normalized_result.get("ok", false)):
		return normalized_result
	var previous_developer := _developer_settings_snapshot()
	var previous_config := _snapshot_config_developer_section()
	var normalized: Dictionary = normalized_result.get("overrides", {})
	_set_action_overrides_in_settings(save_id, role, action, normalized)
	if not save():
		_restore_developer_settings(previous_developer, previous_config)
		return _developer_result(false, last_save_error)
	interaction_tuning_changed.emit(role, action)
	return {
		"ok": true,
		"message": "已保存到当前旅程",
		"save_id": save_id,
		"overrides": normalized.duplicate(true)
	}

func reset_interaction_action_overrides(role: String, action: String) -> Dictionary:
	if not _is_valid_interaction_path(role, action):
		return _developer_result(false, "未知角色或动作：%s/%s" % [role, action])
	var save_id := _active_interaction_save_id()
	if save_id.is_empty():
		return _developer_result(false, "当前没有已加载的旅程，无法恢复互动数值")
	if not _ensure_interaction_settings_current(save_id):
		return _developer_result(false, last_save_error)
	var previous_developer := _developer_settings_snapshot()
	var previous_config := _snapshot_config_developer_section()
	_set_action_overrides_in_settings(save_id, role, action, {})
	if not save():
		_restore_developer_settings(previous_developer, previous_config)
		return _developer_result(false, last_save_error)
	interaction_tuning_changed.emit(role, action)
	return _developer_result(true, "当前旅程的这个动作已恢复默认")

func reset_all_interaction_overrides() -> Dictionary:
	var save_id := _active_interaction_save_id()
	if save_id.is_empty():
		return _developer_result(false, "当前没有已加载的旅程，无法恢复互动数值")
	if not _ensure_interaction_settings_current(save_id):
		return _developer_result(false, last_save_error)
	var previous_developer := _developer_settings_snapshot()
	var previous_config := _snapshot_config_developer_section()
	_set_profile_overrides_in_settings(save_id, {})
	if not save():
		_restore_developer_settings(previous_developer, previous_config)
		return _developer_result(false, last_save_error)
	interaction_tuning_changed.emit("", "")
	return _developer_result(true, "当前旅程的全部互动数值已恢复默认")

func get_interaction_scope_save_id() -> String:
	return _active_interaction_save_id()

func _runtime_tuning_normalized() -> Dictionary:
	var developer = settings.get("developer", {})
	var raw = (developer as Dictionary).get("runtime_tuning", {}) if developer is Dictionary else {}
	if _runtime_tuning_normalized_cache.is_empty() or raw != _runtime_tuning_raw_cache:
		_runtime_tuning_raw_cache = raw.duplicate(true)
		_runtime_tuning_normalized_cache = RUNTIME_TUNING.normalize(raw)
	return _runtime_tuning_normalized_cache

func get_runtime_tuning() -> Dictionary:
	return _runtime_tuning_normalized().duplicate(true)

func get_runtime_tuning_value(key: String, fallback: Variant = null) -> Variant:
	if not RUNTIME_TUNING.SPECS.has(key):
		return fallback
	return _runtime_tuning_normalized().get(key, fallback)

func set_runtime_tuning(values: Dictionary) -> Dictionary:
	for key_variant in values:
		if not RUNTIME_TUNING.SPECS.has(str(key_variant)):
			return _developer_result(false, "未知运行参数：%s" % str(key_variant))
	var previous_developer := _developer_settings_snapshot()
	var previous_config := _snapshot_config_developer_section()
	var merged := get_runtime_tuning()
	for key_variant in values:
		var key := str(key_variant)
		merged[key] = RUNTIME_TUNING.normalize_value(key, values[key_variant])
	merged = RUNTIME_TUNING.normalize(merged)
	var developer: Dictionary = settings.get("developer", {}).duplicate(true)
	developer["runtime_tuning"] = merged
	settings["developer"] = developer
	if not save():
		_restore_developer_settings(previous_developer, previous_config)
		return _developer_result(false, last_save_error)
	runtime_tuning_changed.emit(merged.duplicate(true))
	return {"ok": true, "message": "运行参数已保存", "values": merged.duplicate(true)}

func reset_runtime_tuning_group(group: String) -> Dictionary:
	var keys := RUNTIME_TUNING.specs_for_group(group)
	if keys.is_empty():
		return _developer_result(false, "未知运行参数分组：%s" % group)
	var defaults := RUNTIME_TUNING.defaults()
	var updates := {}
	for key in keys:
		updates[key] = defaults[key]
	var result := set_runtime_tuning(updates)
	if bool(result.get("ok", false)):
		result["message"] = "当前分组已恢复默认"
	return result

func get_role_default_stat_overrides(role: String) -> Dictionary:
	if not Global.ROLES.has(role):
		return {}
	var developer = settings.get("developer", {})
	var all_defaults = (developer as Dictionary).get("role_default_stats", {}) if developer is Dictionary else {}
	if not all_defaults is Dictionary:
		return {}
	var role_values = (all_defaults as Dictionary).get(role, {})
	return role_values.duplicate(true) if role_values is Dictionary else {}

func set_role_default_stats(role: String, values: Dictionary) -> Dictionary:
	if not Global.ROLES.has(role):
		return _developer_result(false, "未知角色：%s" % role)
	var normalized_role := _normalize_role_default_values(role, values)
	var previous_developer := _developer_settings_snapshot()
	var previous_config := _snapshot_config_developer_section()
	var developer: Dictionary = settings.get("developer", {}).duplicate(true)
	var all_defaults = developer.get("role_default_stats", {})
	var updated: Dictionary = all_defaults.duplicate(true) if all_defaults is Dictionary else {}
	updated[role] = normalized_role
	developer["role_default_stats"] = updated
	settings["developer"] = developer
	if not save():
		_restore_developer_settings(previous_developer, previous_config)
		return _developer_result(false, last_save_error)
	return _developer_result(true, "%s的新旅程默认属性已保存" % str(Global.ROLES[role].name))

func get_last_save_error() -> String:
	return last_save_error

func _normalize_developer_settings() -> bool:
	var raw_developer_variant = settings.get("developer", {})
	var raw_developer: Dictionary = (
		(raw_developer_variant as Dictionary).duplicate(true)
		if raw_developer_variant is Dictionary
		else {}
	)
	var version := TUNING_PROFILES.read_schema_version(
		raw_developer.get("interaction_schema_version", null)
	)
	if version not in [1, INTERACTION_TUNING_SCHEMA_VERSION]:
		push_warning("保留无法识别的开发者互动配置；运行时将使用默认值")
		settings["developer"] = raw_developer
		return false
	var active_save_id := _active_interaction_save_id()
	if version == 1 and active_save_id.is_empty():
		var legacy_profile := TUNING_PROFILES.normalize_role_action_overrides(
			raw_developer.get("interaction_delta_overrides", {})
		)
		if not legacy_profile.is_empty():
			push_warning("没有已加载的有效旅程；保留旧版互动数值等待之后迁移")
		settings["developer"] = raw_developer
		return false
	var normalized := _normalize_developer_settings_value(raw_developer, active_save_id)
	var changed := JSON.stringify(raw_developer) != JSON.stringify(normalized)
	settings["developer"] = normalized
	return changed

func _ensure_interaction_settings_current(active_save_id: String) -> bool:
	var developer := _developer_settings_snapshot()
	var version := TUNING_PROFILES.read_schema_version(
		developer.get("interaction_schema_version", null)
	)
	if version == INTERACTION_TUNING_SCHEMA_VERSION:
		return true
	if version != 1:
		last_save_error = "开发者互动配置版本不兼容；为避免覆盖原配置，本次使用默认值"
		return false
	if not Global.is_valid_save_id(active_save_id):
		last_save_error = "当前没有有效旅程，旧版互动配置尚未迁移"
		return false
	var previous_config := _snapshot_config_developer_section()
	settings["developer"] = _normalize_developer_settings_value(developer, active_save_id)
	if save():
		return true
	_restore_developer_settings(developer, previous_config)
	return false

func _normalize_developer_settings_value(
	raw_value: Variant,
	active_save_id: String
) -> Dictionary:
	var raw: Dictionary = raw_value if raw_value is Dictionary else {}
	var version := TUNING_PROFILES.read_schema_version(
		raw.get("interaction_schema_version", null)
	)
	if version == 1:
		var legacy_profile := TUNING_PROFILES.normalize_role_action_overrides(
			raw.get("interaction_delta_overrides", {})
		)
		if not legacy_profile.is_empty() and not Global.is_valid_save_id(active_save_id):
			push_warning("没有已加载的有效旅程；旧版互动数值暂时无法迁移")
	elif version != INTERACTION_TUNING_SCHEMA_VERSION:
		push_warning("忽略不兼容的开发者互动数值配置")
	var normalized := TUNING_PROFILES.normalize_developer_settings(raw, active_save_id)
	normalized["runtime_tuning"] = RUNTIME_TUNING.normalize(raw.get("runtime_tuning", {}))
	normalized["role_default_stats"] = _normalize_role_default_stats(
		raw.get("role_default_stats", {})
	)
	return normalized

func _normalize_role_default_stats(raw_value: Variant) -> Dictionary:
	var result := {}
	if not raw_value is Dictionary:
		return result
	for role in Global.ROLES:
		var raw_role = raw_value.get(role, {})
		if raw_role is Dictionary and not raw_role.is_empty():
			result[role] = _normalize_role_default_values(role, raw_role)
	return result

func _normalize_role_default_values(role: String, raw_value: Dictionary) -> Dictionary:
	var result := {}
	var defaults: Dictionary = Global.ROLE_DEFAULT_STATS.get(role, {})
	for stat_variant in defaults:
		var stat := str(stat_variant)
		var value = raw_value.get(stat, defaults[stat])
		if value is bool or not (value is int or value is float) or not is_finite(float(value)):
			value = defaults[stat]
		result[stat] = clampf(float(value), 0.0, 100.0)
	return result

func _normalize_action_overrides(
	role: String,
	action: String,
	raw_values: Dictionary,
	strict: bool
) -> Dictionary:
	return TUNING_PROFILES.normalize_action_overrides(
		role,
		action,
		raw_values,
		strict
	)

func _is_valid_interaction_path(role: String, action: String) -> bool:
	return (
		INTERACTION_RULES.ROLE_MULTIPLIERS.has(role)
		and INTERACTION_RULES.has_action(action)
	)

func _active_interaction_save_id() -> String:
	if not Global.is_state_loaded():
		return ""
	var active_save_id := str(Global.save_id).strip_edges()
	return active_save_id if Global.is_valid_save_id(active_save_id) else ""

func _all_interaction_profiles() -> Dictionary:
	var developer: Dictionary = settings.get("developer", {})
	var value = developer.get("interaction_delta_overrides", {})
	return value if value is Dictionary else {}

func _interaction_overrides_for_save(save_id: String) -> Dictionary:
	return TUNING_PROFILES.interaction_overrides_for_save(
		_all_interaction_profiles(),
		save_id
	)

func _profiles_with_overrides(
	profiles: Dictionary,
	save_id: String,
	profile_overrides: Dictionary
) -> Dictionary:
	return TUNING_PROFILES.profiles_with_overrides(
		profiles,
		save_id,
		profile_overrides
	)

func _set_profile_overrides_in_settings(
	save_id: String,
	profile_overrides: Dictionary
) -> void:
	settings.developer.interaction_delta_overrides = _profiles_with_overrides(
		_all_interaction_profiles(),
		save_id,
		profile_overrides
	)

func _set_action_overrides_in_settings(
	save_id: String,
	role: String,
	action: String,
	action_overrides: Dictionary
) -> void:
	if not Global.is_valid_save_id(save_id):
		return
	var profile := _interaction_overrides_for_save(save_id)
	profile = TUNING_PROFILES.profile_with_action_overrides(
		profile,
		role,
		action,
		action_overrides
	)
	_set_profile_overrides_in_settings(save_id, profile)

func _developer_settings_snapshot() -> Dictionary:
	var developer = settings.get("developer", {})
	return (
		(developer as Dictionary).duplicate(true)
		if developer is Dictionary
		else {}
	)

func _snapshot_config_developer_section() -> Dictionary:
	var snapshot := {
		"had_section": config.has_section("developer"),
		"values": {}
	}
	if not bool(snapshot.had_section):
		return snapshot
	var values: Dictionary = snapshot.values
	for key in config.get_section_keys("developer"):
		var value = config.get_value("developer", key)
		if value is Dictionary or value is Array:
			value = value.duplicate(true)
		values[key] = value
	return snapshot

func _snapshot_config_section(section: String) -> Dictionary:
	var snapshot := {
		"had_section": config.has_section(section),
		"values": {},
	}
	if not bool(snapshot.had_section):
		return snapshot
	var values: Dictionary = snapshot.values
	for key in config.get_section_keys(section):
		var value = config.get_value(section, key)
		if value is Dictionary or value is Array:
			value = value.duplicate(true)
		values[key] = value
	return snapshot

func _restore_config_section(section: String, snapshot: Dictionary) -> void:
	config.erase_section(section)
	if not bool(snapshot.get("had_section", false)):
		return
	var values = snapshot.get("values", {})
	if not values is Dictionary:
		return
	for key in values:
		var value = values[key]
		if value is Dictionary or value is Array:
			value = value.duplicate(true)
		config.set_value(section, key, value)

func _restore_developer_settings(
	previous_developer: Dictionary,
	previous_config: Dictionary
) -> void:
	settings["developer"] = previous_developer.duplicate(true)
	config.erase_section("developer")
	if not bool(previous_config.get("had_section", false)):
		return
	var values_variant = previous_config.get("values", {})
	if not values_variant is Dictionary:
		return
	for key in values_variant:
		var value = values_variant[key]
		if value is Dictionary or value is Array:
			value = value.duplicate(true)
		config.set_value("developer", key, value)

func _recover_interrupted_settings_commit() -> void:
	if FileAccess.file_exists(SETTINGS_PATH):
		return
	var temp_exists := FileAccess.file_exists(SETTINGS_TEMP_PATH)
	var backup_exists := FileAccess.file_exists(SETTINGS_BACKUP_PATH)
	if not temp_exists and not backup_exists:
		return
	var settings_absolute := ProjectSettings.globalize_path(SETTINGS_PATH)
	var temp_absolute := ProjectSettings.globalize_path(SETTINGS_TEMP_PATH)
	var backup_absolute := ProjectSettings.globalize_path(SETTINGS_BACKUP_PATH)
	var backup_is_valid := backup_exists and _config_file_is_valid(SETTINGS_BACKUP_PATH)
	var temp_is_valid := temp_exists and _config_file_is_valid(SETTINGS_TEMP_PATH)
	if backup_is_valid:
		var restore_error := DirAccess.rename_absolute(backup_absolute, settings_absolute)
		if restore_error != OK:
			last_save_error = "检测到未完成的设置写入，但无法恢复备份：%s" % error_string(restore_error)
			push_warning(last_save_error)
			return
		if temp_exists:
			var cleanup_error := DirAccess.remove_absolute(temp_absolute)
			if cleanup_error != OK:
				push_warning("旧设置已恢复，但无法清理未提交的临时文件：%s" % error_string(cleanup_error))
		push_warning("检测到上次设置写入中断，已恢复原设置")
		return
	if not temp_is_valid:
		last_save_error = "检测到未完成的设置写入，但备份和临时文件都无效"
		push_warning(last_save_error)
		return
	var promote_error := DirAccess.rename_absolute(temp_absolute, settings_absolute)
	if promote_error != OK:
		last_save_error = "检测到未完成的设置写入，但无法提交有效临时文件：%s" % error_string(promote_error)
		push_warning(last_save_error)
		return
	push_warning("检测到上次设置写入中断，已从有效临时文件完成恢复")

func _load_valid_settings_recovery_candidate() -> String:
	for candidate in [
		{"path": SETTINGS_BACKUP_PATH, "label": "有效备份"},
		{"path": SETTINGS_TEMP_PATH, "label": "有效临时文件"}
	]:
		var path := str(candidate.path)
		if not FileAccess.file_exists(path):
			continue
		var recovered_config := ConfigFile.new()
		if recovered_config.load(path) != OK:
			continue
		config = recovered_config
		_settings_main_is_invalid = true
		return str(candidate.label)
	return ""

func _config_file_is_valid(path: String) -> bool:
	var candidate := ConfigFile.new()
	return candidate.load(path) == OK

func _discard_settings_temp_file() -> void:
	if not FileAccess.file_exists(SETTINGS_TEMP_PATH):
		return
	var cleanup_error := DirAccess.remove_absolute(
		ProjectSettings.globalize_path(SETTINGS_TEMP_PATH)
	)
	if cleanup_error != OK:
		push_warning("无法清理未提交的设置临时文件：%s" % error_string(cleanup_error))

func _commit_settings_temp_file() -> bool:
	var temp_absolute := ProjectSettings.globalize_path(SETTINGS_TEMP_PATH)
	var settings_absolute := ProjectSettings.globalize_path(SETTINGS_PATH)
	var backup_absolute := ProjectSettings.globalize_path(SETTINGS_BACKUP_PATH)
	var had_existing_settings := FileAccess.file_exists(SETTINGS_PATH)
	if had_existing_settings and _settings_main_is_invalid:
		var discard_error := DirAccess.remove_absolute(settings_absolute)
		if discard_error != OK:
			_discard_settings_temp_file()
			last_save_error = "无法替换损坏的设置主文件：%s" % error_string(discard_error)
			push_warning(last_save_error)
			return false
		var recovery_commit_error := DirAccess.rename_absolute(temp_absolute, settings_absolute)
		if recovery_commit_error != OK:
			_discard_settings_temp_file()
			last_save_error = "无法提交从备份恢复的新设置：%s" % error_string(recovery_commit_error)
			push_warning(last_save_error)
			return false
		_settings_main_is_invalid = false
		return true
	if had_existing_settings:
		if FileAccess.file_exists(SETTINGS_BACKUP_PATH):
			var remove_error := DirAccess.remove_absolute(backup_absolute)
			if remove_error != OK:
				DirAccess.remove_absolute(temp_absolute)
				last_save_error = "无法轮换设置备份：%s" % error_string(remove_error)
				push_warning(last_save_error)
				return false
		var backup_error := DirAccess.rename_absolute(settings_absolute, backup_absolute)
		if backup_error != OK:
			DirAccess.remove_absolute(temp_absolute)
			last_save_error = "无法备份当前设置：%s" % error_string(backup_error)
			push_warning(last_save_error)
			return false
	var commit_error := DirAccess.rename_absolute(temp_absolute, settings_absolute)
	if commit_error == OK:
		_settings_main_is_invalid = false
		return true
	var restore_detail := ""
	if had_existing_settings and FileAccess.file_exists(SETTINGS_BACKUP_PATH):
		var restore_error := DirAccess.rename_absolute(backup_absolute, settings_absolute)
		if restore_error != OK:
			restore_detail = "；恢复旧设置也失败：%s" % error_string(restore_error)
	DirAccess.remove_absolute(temp_absolute)
	last_save_error = "无法提交新设置：%s%s" % [
		error_string(commit_error),
		restore_detail
	]
	push_warning(last_save_error)
	return false

func _developer_result(ok: bool, message: String) -> Dictionary:
	return {"ok": ok, "message": message}

func get_font_path() -> String:
	match str(settings.ui.get("font_family", "wenkai")):
		"mono":
			return "res://assets/fonts/LXGWWenKaiMono-Regular.ttf"
		"light":
			return "res://assets/fonts/LXGWWenKai-Light.ttf"
		_:
			return "res://assets/fonts/LXGWWenKai-Regular.ttf"
