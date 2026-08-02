class_name DeveloperRuntimeTuning
extends RefCounted

const GROUPS := [
	{"id": "attributes", "label": "角色属性与时间"},
	{"id": "autonomy", "label": "自主生活"},
	{"id": "conversation", "label": "对话调度"},
	{"id": "reliability", "label": "Core 与可靠性"},
	{"id": "navigation", "label": "3D 行为"},
	{"id": "visual", "label": "UI 动效"},
	{"id": "physiology", "label": "生理模拟"},
]

const SPECS := {
	"life_time_scale": {"group": "attributes", "label": "现实时间变化倍率", "type": "float", "default": 1.0, "min": 0.0, "max": 10.0, "step": 0.1, "suffix": "×"},
	"ling_need_rate_scale": {"group": "attributes", "label": "小玲需求变化倍率", "type": "float", "default": 1.0, "min": 0.0, "max": 5.0, "step": 0.1, "suffix": "×"},
	"nai_need_rate_scale": {"group": "attributes", "label": "小奈需求变化倍率", "type": "float", "default": 1.0, "min": 0.0, "max": 5.0, "step": 0.1, "suffix": "×"},

	"self_care_enabled": {"group": "autonomy", "label": "允许自主饮食、休息和如厕", "type": "bool", "default": true},
	"self_care_cooldown_minutes": {"group": "autonomy", "label": "自主照顾最短间隔", "type": "int", "default": 15, "min": 1, "max": 1440, "step": 1, "suffix": " 分钟"},
	"thirst_care_threshold": {"group": "autonomy", "label": "口渴触发喝水", "type": "float", "default": 72.0, "min": 1.0, "max": 100.0, "step": 1.0},
	"hunger_care_threshold": {"group": "autonomy", "label": "饥饿触发进食", "type": "float", "default": 74.0, "min": 1.0, "max": 100.0, "step": 1.0},
	"urine_care_threshold": {"group": "autonomy", "label": "如厕需求触发处理", "type": "float", "default": 86.0, "min": 1.0, "max": 100.0, "step": 1.0},
	"stamina_care_threshold": {"group": "autonomy", "label": "体力低于此值休息", "type": "float", "default": 24.0, "min": 0.0, "max": 99.0, "step": 1.0},
	"self_care_message_chance": {"group": "autonomy", "label": "自主行为后主动发消息概率", "type": "percent", "default": 0.30, "min": 0.0, "max": 1.0, "step": 0.05},
	"personality_cooldown_minutes": {"group": "autonomy", "label": "个性生活行为最短间隔", "type": "int", "default": 90, "min": 5, "max": 1440, "step": 5, "suffix": " 分钟"},
	"personality_message_chance": {"group": "autonomy", "label": "个性生活后主动分享概率", "type": "percent", "default": 0.18, "min": 0.0, "max": 1.0, "step": 0.05},
	"proactive_enabled": {"group": "autonomy", "label": "允许主动给玩家发消息", "type": "bool", "default": true},
	"proactive_idle_minutes": {"group": "autonomy", "label": "玩家空闲后允许主动消息", "type": "int", "default": 30, "min": 1, "max": 1440, "step": 1, "suffix": " 分钟"},
	"proactive_min_minutes": {"group": "autonomy", "label": "主动消息最短间隔", "type": "int", "default": 60, "min": 5, "max": 1440, "step": 5, "suffix": " 分钟"},
	"proactive_max_minutes": {"group": "autonomy", "label": "主动消息最长间隔", "type": "int", "default": 180, "min": 5, "max": 2880, "step": 5, "suffix": " 分钟"},

	"default_reply_mode": {"group": "conversation", "label": "未点名时回复方式", "type": "option", "default": "selected", "options": [{"value": "selected", "label": "当前选择角色"}, {"value": "both", "label": "两个人都回复"}]},
	"both_names_trigger_dual": {"group": "conversation", "label": "同时提到两人时触发双人回复", "type": "bool", "default": false},
	"request_timeout_seconds": {"group": "conversation", "label": "单次回复等待上限", "type": "int", "default": 90, "min": 15, "max": 175, "step": 5, "suffix": " 秒"},
	"auto_retry_count": {"group": "conversation", "label": "可重试错误的自动重试次数", "type": "int", "default": 0, "min": 0, "max": 3, "step": 1, "suffix": " 次"},

	"core_autostart_enabled": {"group": "reliability", "label": "本机 Core 离线时自动启动", "type": "bool", "default": true},
	"core_restart_cooldown_seconds": {"group": "reliability", "label": "Core 崩溃重启冷却", "type": "int", "default": 10, "min": 3, "max": 120, "step": 1, "suffix": " 秒"},

	"movement_speed_scale": {"group": "navigation", "label": "AI 移动速度倍率", "type": "float", "default": 1.0, "min": 0.25, "max": 3.0, "step": 0.05, "suffix": "×"},
	"follow_distance_m": {"group": "navigation", "label": "跟随停止距离", "type": "float", "default": 1.6, "min": 0.5, "max": 5.0, "step": 0.1, "suffix": " 米"},
	"exploration_min_seconds": {"group": "navigation", "label": "自主探索最短间隔", "type": "int", "default": 45, "min": 5, "max": 600, "step": 5, "suffix": " 秒"},
	"exploration_max_seconds": {"group": "navigation", "label": "自主探索最长间隔", "type": "int", "default": 120, "min": 5, "max": 1200, "step": 5, "suffix": " 秒"},
	"life_lab_min_seconds": {"group": "navigation", "label": "生活测试场景最短行动间隔", "type": "int", "default": 8, "min": 3, "max": 120, "step": 1, "suffix": " 秒"},
	"life_lab_max_seconds": {"group": "navigation", "label": "生活测试场景最长行动间隔", "type": "int", "default": 16, "min": 3, "max": 180, "step": 1, "suffix": " 秒"},
	"obstacle_retry_limit": {"group": "navigation", "label": "阻塞后的重新寻路次数", "type": "int", "default": 3, "min": 0, "max": 10, "step": 1, "suffix": " 次"},

	"particle_count_scale": {"group": "visual", "label": "属性粒子数量倍率", "type": "float", "default": 1.0, "min": 0.0, "max": 3.0, "step": 0.1, "suffix": "×"},
	"particle_lifetime_scale": {"group": "visual", "label": "属性粒子持续时间倍率", "type": "float", "default": 1.0, "min": 0.25, "max": 3.0, "step": 0.05, "suffix": "×"},
	"full_stat_effects_enabled": {"group": "visual", "label": "启用属性满值粒子和脉冲", "type": "bool", "default": true},
	"thinking_intensity": {"group": "visual", "label": "思考动画强度", "type": "float", "default": 1.0, "min": 0.0, "max": 2.0, "step": 0.1, "suffix": "×"},

	"cycle_time_scale": {"group": "physiology", "label": "生理周期时间倍率", "type": "float", "default": 1.0, "min": 0.1, "max": 10.0, "step": 0.1, "suffix": "×"},
	"ling_cycle_length_days": {"group": "physiology", "label": "小玲周期长度", "type": "int", "default": 29, "min": 21, "max": 40, "step": 1, "suffix": " 天"},
	"ling_period_length_days": {"group": "physiology", "label": "小玲经期长度", "type": "int", "default": 5, "min": 2, "max": 8, "step": 1, "suffix": " 天"},
	"ling_initial_cycle_day": {"group": "physiology", "label": "小玲初始周期日", "type": "int", "default": 3, "min": 1, "max": 40, "step": 1, "suffix": " 日"},
	"ling_symptom_scale": {"group": "physiology", "label": "小玲症状强度", "type": "float", "default": 1.0, "min": 0.0, "max": 2.0, "step": 0.05, "suffix": "×"},
	"nai_cycle_length_days": {"group": "physiology", "label": "小奈周期长度", "type": "int", "default": 27, "min": 21, "max": 40, "step": 1, "suffix": " 天"},
	"nai_period_length_days": {"group": "physiology", "label": "小奈经期长度", "type": "int", "default": 4, "min": 2, "max": 8, "step": 1, "suffix": " 天"},
	"nai_initial_cycle_day": {"group": "physiology", "label": "小奈初始周期日", "type": "int", "default": 17, "min": 1, "max": 40, "step": 1, "suffix": " 日"},
	"nai_symptom_scale": {"group": "physiology", "label": "小奈症状强度", "type": "float", "default": 0.84, "min": 0.0, "max": 2.0, "step": 0.05, "suffix": "×"},
}

static func defaults() -> Dictionary:
	var result := {}
	for key_variant in SPECS:
		var key := str(key_variant)
		result[key] = (SPECS[key] as Dictionary).get("default")
	return result

static func normalize(raw_value: Variant) -> Dictionary:
	var raw: Dictionary = raw_value if raw_value is Dictionary else {}
	var result := defaults()
	for key_variant in SPECS:
		var key := str(key_variant)
		if raw.has(key):
			result[key] = normalize_value(key, raw[key])
	_enforce_relations(result)
	return result

static func normalize_value(key: String, value: Variant) -> Variant:
	if not SPECS.has(key):
		return null
	var spec: Dictionary = SPECS[key]
	match str(spec.type):
		"bool":
			return value if value is bool else bool(spec.default)
		"option":
			for option_variant in spec.options:
				var option: Dictionary = option_variant
				if value is String and str(value) == str(option.value):
					return str(value)
			return str(spec.default)
		"int", "float", "percent":
			if value is bool or not (value is int or value is float):
				return spec.default
			var numeric := float(value)
			if not is_finite(numeric):
				return spec.default
			numeric = clampf(numeric, float(spec.min), float(spec.max))
			return int(round(numeric)) if str(spec.type) == "int" else snappedf(numeric, float(spec.step))
		_:
			return spec.default

static func specs_for_group(group: String) -> Array[String]:
	var result: Array[String] = []
	for key_variant in SPECS:
		var key := str(key_variant)
		if str((SPECS[key] as Dictionary).get("group", "")) == group:
			result.append(key)
	return result

static func _enforce_relations(values: Dictionary) -> void:
	values["proactive_max_minutes"] = maxi(
		int(values.proactive_min_minutes), int(values.proactive_max_minutes)
	)
	values["exploration_max_seconds"] = maxi(
		int(values.exploration_min_seconds), int(values.exploration_max_seconds)
	)
	values["life_lab_max_seconds"] = maxi(
		int(values.life_lab_min_seconds), int(values.life_lab_max_seconds)
	)
	for role in ["ling", "nai"]:
		var cycle_key := "%s_cycle_length_days" % role
		var period_key := "%s_period_length_days" % role
		var initial_key := "%s_initial_cycle_day" % role
		values[period_key] = mini(int(values[period_key]), int(values[cycle_key]) - 15)
		values[initial_key] = mini(int(values[initial_key]), int(values[cycle_key]))
