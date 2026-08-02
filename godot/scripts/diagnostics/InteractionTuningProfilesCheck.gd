extends SceneTree

const PROFILES := preload("res://scripts/domain/InteractionTuningProfiles.gd")

var _failures: Array[String] = []
var _checks := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var legacy_input := {
		"interaction_schema_version": 1,
		"interaction_delta_overrides": {
			"ling": {"hug": {"intimacy": 7.3}},
			"nai": {"eat": {"hunger": -12.3}}
		}
	}
	var legacy_snapshot := JSON.stringify(legacy_input)
	var migrated: Dictionary = PROFILES.normalize_developer_settings(
		legacy_input,
		"save-A"
	)
	_expect(int(migrated.get("interaction_schema_version", 0)) == 2, "v1→v2 版本错误")
	var migrated_profiles: Dictionary = migrated.get("interaction_delta_overrides", {})
	_expect(migrated_profiles.size() == 1 and migrated_profiles.has("save-A"), "旧配置没有只迁入当前旅程")
	_expect(not migrated_profiles.has("save-B"), "旧配置串入了其他旅程")
	_expect(JSON.stringify(legacy_input) == legacy_snapshot, "迁移原地修改了输入字典")
	var deferred_legacy := PROFILES.normalize_developer_settings(legacy_input, "")
	_expect(
		JSON.stringify(deferred_legacy) == legacy_snapshot,
		"没有有效旅程时不应清空或升级旧配置"
	)
	var empty_legacy := {
		"interaction_schema_version": 1,
		"interaction_delta_overrides": {}
	}
	_expect(
		JSON.stringify(PROFILES.normalize_developer_settings(empty_legacy, ""))
		== JSON.stringify(empty_legacy),
		"没有有效旅程时空的旧配置也应原样保留"
	)
	var migrated_again: Dictionary = PROFILES.normalize_developer_settings(
		migrated,
		"save-A"
	)
	_expect(JSON.stringify(migrated_again) == JSON.stringify(migrated), "v2 规范化不幂等")
	var future_config := {
		"interaction_schema_version": 3,
		"interaction_delta_overrides": {"future": {"opaque": true}}
	}
	_expect(
		JSON.stringify(PROFILES.normalize_developer_settings(future_config, "save-A"))
		== JSON.stringify(future_config),
		"未来版本配置不应被降级覆盖"
	)

	var two_profiles_raw := {
		"interaction_schema_version": 2,
		"interaction_delta_overrides": {
			"save-A": {
				"ling": {
					"hug": {"intimacy": 7.3},
					"praise": {"mood": 4.2}
				}
			},
			"save-B": {"nai": {"drink": {"thirst": -22.0}}}
		}
	}
	var normalized: Dictionary = PROFILES.normalize_developer_settings(
		two_profiles_raw,
		"save-A"
	)
	var profiles_before: Dictionary = normalized.get("interaction_delta_overrides", {})
	var save_b_snapshot := JSON.stringify(profiles_before.get("save-B", {}))
	var updated_a := PROFILES.profile_with_action_overrides(
		profiles_before.get("save-A", {}),
		"ling",
		"hug",
		{"intimacy": 8.8}
	)
	var profiles_after := PROFILES.profiles_with_overrides(
		profiles_before,
		"save-A",
		updated_a
	)
	_expect(JSON.stringify(profiles_after.get("save-B", {})) == save_b_snapshot, "修改 A 污染了 B")
	_expect(
		float(profiles_after.get("save-A", {}).get("ling", {}).get("hug", {}).get("intimacy", 0.0)) == 8.8,
		"修改 A 没有生效"
	)
	_expect(
		profiles_after.get("save-A", {}).get("ling", {}).has("praise"),
		"修改动作时丢失了 A 的其他动作"
	)
	var detached := PROFILES.interaction_overrides_for_save(profiles_after, "save-B")
	detached["tampered"] = true
	_expect(not (profiles_after["save-B"] as Dictionary).has("tampered"), "getter 没有返回深拷贝")

	var reset_profiles := PROFILES.profiles_with_overrides(
		profiles_after,
		"save-A",
		{}
	)
	_expect(not reset_profiles.has("save-A"), "重置 A 后仍残留 A profile")
	_expect(JSON.stringify(reset_profiles.get("save-B", {})) == save_b_snapshot, "重置 A 污染了 B")

	var invalid_profiles := {}
	for invalid_id in ["", "-bad", "_bad", "has space", "a/b", "中文", "a".repeat(65)]:
		invalid_profiles[invalid_id] = {"ling": {"hug": {"intimacy": 9.0}}}
	invalid_profiles[42] = {"ling": {"hug": {"intimacy": 9.0}}}
	invalid_profiles["A-0_1"] = {"ling": {"hug": {"intimacy": 9.0}}}
	invalid_profiles["a".repeat(64)] = {"nai": {"praise": {"mood": 9.0}}}
	var invalid_result: Dictionary = PROFILES.normalize_developer_settings(
		{
			"interaction_schema_version": 2,
			"interaction_delta_overrides": invalid_profiles
		},
		"save-A"
	)
	var accepted_profiles: Dictionary = invalid_result.get("interaction_delta_overrides", {})
	_expect(accepted_profiles.size() == 2, "非法 save_id 没有被完整过滤")
	_expect(accepted_profiles.has("A-0_1"), "合法混合 save_id 被错误过滤")
	_expect(accepted_profiles.has("a".repeat(64)), "64 字符边界 save_id 被错误过滤")

	if _failures.is_empty():
		print("INTERACTION_TUNING_PROFILES_CHECK passed=", _checks)
		quit(0)
		return
	for failure in _failures:
		printerr("INTERACTION_TUNING_PROFILES_CHECK failure=", failure)
	quit(1)

func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
