class_name InteractionTuningProfiles
extends RefCounted

const RULES := preload("res://scripts/domain/InteractionRules.gd")
const SCHEMA_VERSION := 2

static func normalize_developer_settings(
	raw_value: Variant,
	active_save_id: String
) -> Dictionary:
	var raw: Dictionary = raw_value if raw_value is Dictionary else {}
	var version := read_schema_version(raw.get("interaction_schema_version", null))
	var profiles: Dictionary = {}
	if version == 1:
		if not is_valid_save_id(active_save_id):
			return raw.duplicate(true)
		var legacy_profile := normalize_role_action_overrides(
			raw.get("interaction_delta_overrides", {})
		)
		if not legacy_profile.is_empty():
			profiles[active_save_id] = legacy_profile
	elif version == SCHEMA_VERSION:
		profiles = normalize_profiles(raw.get("interaction_delta_overrides", {}))
	else:
		return raw.duplicate(true)
	return {
		"interaction_schema_version": SCHEMA_VERSION,
		"interaction_delta_overrides": profiles
	}

static func read_schema_version(raw_value: Variant) -> int:
	if raw_value is bool or not (raw_value is int or raw_value is float):
		return -1
	var numeric := float(raw_value)
	if not is_finite(numeric) or numeric != float(int(numeric)):
		return -1
	return int(numeric)

static func normalize_profiles(raw_value: Variant) -> Dictionary:
	var profiles: Dictionary = {}
	if not raw_value is Dictionary:
		return profiles
	for save_id_variant in raw_value:
		if not save_id_variant is String:
			continue
		var save_id := str(save_id_variant)
		if not is_valid_save_id(save_id):
			continue
		var profile := normalize_role_action_overrides(raw_value[save_id_variant])
		if not profile.is_empty():
			profiles[save_id] = profile
	return profiles

static func normalize_role_action_overrides(raw_value: Variant) -> Dictionary:
	var normalized: Dictionary = {}
	if not raw_value is Dictionary:
		return normalized
	for role_variant in raw_value:
		var role := str(role_variant)
		if not RULES.ROLE_MULTIPLIERS.has(role):
			continue
		var raw_role_variant = raw_value[role_variant]
		if not raw_role_variant is Dictionary:
			continue
		for action_variant in raw_role_variant:
			var action := str(action_variant)
			if not RULES.has_action(action):
				continue
			var raw_action_variant = raw_role_variant[action_variant]
			if not raw_action_variant is Dictionary:
				continue
			var result := normalize_action_overrides(
				role,
				action,
				raw_action_variant,
				false
			)
			var action_overrides: Dictionary = result.get("overrides", {})
			if action_overrides.is_empty():
				continue
			if not normalized.has(role):
				normalized[role] = {}
			(normalized[role] as Dictionary)[action] = action_overrides
	return normalized

static func normalize_action_overrides(
	role: String,
	action: String,
	raw_values: Dictionary,
	strict: bool
) -> Dictionary:
	if not RULES.ROLE_MULTIPLIERS.has(role) or not RULES.has_action(action):
		return _result(false, "未知角色或动作：%s/%s" % [role, action])
	var normalized := {}
	var allowed_stats := RULES.action_stat_keys(action)
	for stat_variant in raw_values:
		var stat := str(stat_variant)
		if stat not in allowed_stats:
			if strict:
				return _result(false, "动作 %s 不包含属性 %s" % [action, stat])
			continue
		var raw_value = raw_values[stat_variant]
		if raw_value is bool or not (raw_value is int or raw_value is float):
			if strict:
				return _result(false, "属性 %s 的 delta 不是数字" % stat)
			continue
		var numeric_value := float(raw_value)
		if (
			not is_finite(numeric_value)
			or numeric_value < RULES.MIN_CUSTOM_DELTA
			or numeric_value > RULES.MAX_CUSTOM_DELTA
		):
			if strict:
				return _result(
					false,
					"属性 %s 的 delta 必须在 %.1f 到 %.1f 之间" % [
						stat,
						RULES.MIN_CUSTOM_DELTA,
						RULES.MAX_CUSTOM_DELTA
					]
				)
			continue
		var rounded_value := roundf(numeric_value * 10.0) / 10.0
		var default_value = RULES.default_delta(role, action, stat)
		if default_value != null and is_equal_approx(rounded_value, float(default_value)):
			continue
		normalized[stat] = rounded_value
	return {"ok": true, "message": "", "overrides": normalized}

static func interaction_overrides_for_save(
	profiles: Dictionary,
	save_id: String
) -> Dictionary:
	if not is_valid_save_id(save_id):
		return {}
	var profile = profiles.get(save_id, {})
	return (
		(profile as Dictionary).duplicate(true)
		if profile is Dictionary
		else {}
	)

static func profiles_with_overrides(
	profiles: Dictionary,
	save_id: String,
	profile_overrides: Dictionary
) -> Dictionary:
	var updated := profiles.duplicate(true)
	if not is_valid_save_id(save_id):
		return updated
	if profile_overrides.is_empty():
		updated.erase(save_id)
	else:
		updated[save_id] = profile_overrides.duplicate(true)
	return updated

static func profile_with_action_overrides(
	profile: Dictionary,
	role: String,
	action: String,
	action_overrides: Dictionary
) -> Dictionary:
	var updated := profile.duplicate(true)
	if not RULES.ROLE_MULTIPLIERS.has(role) or not RULES.has_action(action):
		return updated
	var role_overrides: Dictionary = (
		(updated.get(role, {}) as Dictionary).duplicate(true)
		if updated.get(role, {}) is Dictionary
		else {}
	)
	if action_overrides.is_empty():
		role_overrides.erase(action)
	else:
		role_overrides[action] = action_overrides.duplicate(true)
	if role_overrides.is_empty():
		updated.erase(role)
	else:
		updated[role] = role_overrides
	return updated

static func is_valid_save_id(value: String) -> bool:
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

static func _result(ok: bool, message: String) -> Dictionary:
	return {"ok": ok, "message": message, "overrides": {}}
