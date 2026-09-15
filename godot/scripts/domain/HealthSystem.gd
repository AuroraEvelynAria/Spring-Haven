class_name HealthSystem
extends RefCounted

"""健康/小病系统：淋雨或过劳触发感冒，影响生活，自动恢复。

状态持久化在 life_runtime.health：{ "ling": {...}, "nai": {...} }
条目：{ "illness": ""|"cold"|"fatigue", "since_day": "YYYY-MM-DD", "severity": 1|2 }
"""

const ILLNESS_LABELS := {
	"": "",
	"cold": "有点着凉",
	"fatigue": "累得不太舒服",
}

# 生病持续时间（天）
const COLD_DAYS := 2
const FATIGUE_DAYS := 1


static func normalize_runtime(raw_value: Variant) -> Dictionary:
	var raw: Dictionary = raw_value if raw_value is Dictionary else {}
	var result: Dictionary = {}
	for role in ["ling", "nai"]:
		var entry: Dictionary = (
			raw.get(role, {}) if raw.get(role, {}) is Dictionary else {}
		)
		result[role] = {
			"illness": str(entry.get("illness", "")).left(16),
			"since_day": str(entry.get("since_day", "")).left(10),
			"severity": int(clampi(int(entry.get("severity", 1)), 1, 2)),
			"last_cold_roll_day": str(entry.get("last_cold_roll_day", "")).left(10),
			"last_fatigue_roll_day": str(entry.get("last_fatigue_roll_day", "")).left(10),
		}
	return result


static func is_sick(health: Dictionary, role: String) -> bool:
	var entry: Dictionary = health.get(role, {}) if health.get(role, {}) is Dictionary else {}
	return not str(entry.get("illness", "")).is_empty()


static func illness_label(health: Dictionary, role: String) -> String:
	var entry: Dictionary = health.get(role, {}) if health.get(role, {}) is Dictionary else {}
	var illness := str(entry.get("illness", ""))
	return str(ILLNESS_LABELS.get(illness, illness))


static func try_catch_cold(health: Dictionary, role: String, day_key: String, rng: RandomNumberGenerator) -> Dictionary:
	"""淋雨后 25% 概率感冒；已生病则不变。"""
	if is_sick(health, role):
		return health
	var entry: Dictionary = health.get(role, {}) if health.get(role, {}) is Dictionary else {}
	if str(entry.get("last_cold_roll_day", "")) == day_key:
		return health
	entry["last_cold_roll_day"] = day_key
	if rng.randf() < 0.25:
		entry["illness"] = "cold"
		entry["since_day"] = day_key
		entry["severity"] = 1
	health[role] = entry
	return health


static func try_fatigue(health: Dictionary, role: String, day_key: String, stamina: float, rng: RandomNumberGenerator) -> Dictionary:
	"""stamina 长期低于 20 时有概率过劳不适。"""
	if is_sick(health, role):
		return health
	var entry: Dictionary = health.get(role, {}) if health.get(role, {}) is Dictionary else {}
	if str(entry.get("last_fatigue_roll_day", "")) == day_key:
		return health
	entry["last_fatigue_roll_day"] = day_key
	if stamina <= 20.0 and rng.randf() < 0.10:
		entry["illness"] = "fatigue"
		entry["since_day"] = day_key
		entry["severity"] = 1
	health[role] = entry
	return health


static func maybe_recover(health: Dictionary, role: String, day_key: String, rng: RandomNumberGenerator) -> Dictionary:
	"""生病超过持续天数后恢复。"""
	if not is_sick(health, role):
		return health
	var entry: Dictionary = health.get(role, {}) if health.get(role, {}) is Dictionary else {}
	var illness := str(entry.get("illness", ""))
	var since := str(entry.get("since_day", ""))
	var days_sick := _days_between(since, day_key)
	var needed := COLD_DAYS if illness == "cold" else FATIGUE_DAYS
	if days_sick >= needed:
		health[role] = {"illness": "", "since_day": "", "severity": 1}
	return health


static func sick_effect(health: Dictionary, role: String) -> Dictionary:
	"""生病时的每小时属性影响。"""
	if not is_sick(health, role):
		return {}
	var entry: Dictionary = health.get(role, {}) if health.get(role, {}) is Dictionary else {}
	var illness := str(entry.get("illness", ""))
	if illness == "cold":
		return {"stamina": -1.5, "awake": -1.0, "stress": 0.8}
	return {"stamina": -1.0, "stress": 0.5}


static func _days_between(from_day: String, to_day: String) -> int:
	"""Return the exact Gregorian day difference for two YYYY-MM-DD values."""
	var f := from_day.split("-")
	var t := to_day.split("-")
	if f.size() != 3 or t.size() != 3:
		return 0
	var f_days := _serial_day(int(f[0]), int(f[1]), int(f[2]))
	var t_days := _serial_day(int(t[0]), int(t[1]), int(t[2]))
	return maxi(0, t_days - f_days)


static func _serial_day(year: int, month: int, day: int) -> int:
	if year < 1 or month < 1 or month > 12 or day < 1:
		return 0
	var month_offsets := [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
	var previous_year := year - 1
	var result := previous_year * 365 + int(previous_year / 4) - int(previous_year / 100) + int(previous_year / 400)
	result += int(month_offsets[month - 1]) + day
	var leap := (year % 4 == 0 and year % 100 != 0) or year % 400 == 0
	if leap and month > 2:
		result += 1
	return result
