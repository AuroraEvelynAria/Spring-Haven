class_name WeatherSystem
extends RefCounted

"""天气系统：按天滚动生成（季节倾向 + 随机），影响生活与心情。

状态持久化在 life_runtime.weather：
{ "code": "sunny"|"cloudy"|"rain"|"snow"|"windy",
  "temperature": 0-40, "day_key": "YYYY-MM-DD", "updated_at": unix }
"""

const WEATHER_CODES := ["sunny", "cloudy", "rain", "snow", "windy"]
const WEATHER_LABELS := {
	"sunny": "晴天", "cloudy": "多云", "rain": "下雨", "snow": "下雪", "windy": "大风",
}
const WEATHER_ICONS := {
	"sunny": "☀️", "cloudy": "☁️", "rain": "🌧️", "snow": "❄️", "windy": "💨",
}

# 季节倾向：month -> 权重分布（index 对应 WEATHER_CODES）
const SEASON_WEIGHTS := {
	1: [0.45, 0.25, 0.10, 0.10, 0.10],   # 冬
	2: [0.45, 0.25, 0.10, 0.10, 0.10],
	3: [0.50, 0.25, 0.12, 0.03, 0.10],   # 春
	4: [0.50, 0.25, 0.15, 0.00, 0.10],
	5: [0.45, 0.25, 0.20, 0.00, 0.10],
	6: [0.40, 0.20, 0.28, 0.00, 0.12],   # 夏
	7: [0.35, 0.20, 0.32, 0.00, 0.13],
	8: [0.40, 0.20, 0.28, 0.00, 0.12],
	9: [0.50, 0.25, 0.15, 0.00, 0.10],   # 秋
	10: [0.50, 0.25, 0.12, 0.00, 0.13],
	11: [0.45, 0.25, 0.12, 0.03, 0.15],
	12: [0.45, 0.25, 0.10, 0.08, 0.12],
}

# 季节基准温度（摄氏）
const SEASON_TEMPS := {
	1: 4.0, 2: 6.0, 3: 12.0, 4: 18.0, 5: 23.0, 6: 27.0,
	7: 30.0, 8: 29.0, 9: 25.0, 10: 19.0, 11: 12.0, 12: 6.0,
}

# 坏天气（影响户外活动 + 心情）
const BAD_WEATHER := ["rain", "snow", "windy"]
const OUTDOOR_ACTIONS := ["walk_outside", "sunbathe"]


static func normalize_runtime(raw_value: Variant, now: int) -> Dictionary:
	var raw: Dictionary = raw_value if raw_value is Dictionary else {}
	return {
		"code": _valid_code(str(raw.get("code", "sunny"))),
		"temperature": int(clampf(float(raw.get("temperature", 22.0)), -10.0, 45.0)),
		"day_key": str(raw.get("day_key", "")).left(10),
		"updated_at": _unix(raw.get("updated_at", 0), now),
	}


static func current_weather(runtime: Dictionary) -> Dictionary:
	return normalize_runtime(runtime, int(Time.get_unix_time_from_system()))


static func roll_for_day(now: int, rng: RandomNumberGenerator) -> Dictionary:
	var local := Time.get_datetime_dict_from_system(now)
	var month := int(local.get("month", 6))
	var day_key := "%04d-%02d-%02d" % [
		int(local.get("year", 2000)), month, int(local.get("day", 1))
	]
	var weights: Array = SEASON_WEIGHTS.get(month, SEASON_WEIGHTS[6])
	var code := _weighted_pick(weights, rng)
	var base_temp := float(SEASON_TEMPS.get(month, 22.0))
	var temperature := int(base_temp + rng.randf_range(-3.0, 3.0))
	if code == "snow":
		temperature = mini(temperature, 1)
	return {
		"code": code,
		"temperature": temperature,
		"day_key": day_key,
		"updated_at": now,
	}


static func should_roll(runtime: Dictionary, now: int) -> bool:
	var current := normalize_runtime(runtime, now)
	var local := Time.get_datetime_dict_from_system(now)
	var today := "%04d-%02d-%02d" % [
		int(local.get("year", 2000)), int(local.get("month", 1)), int(local.get("day", 1))
	]
	return current.day_key != today


static func is_bad(code: String) -> bool:
	return code in BAD_WEATHER


static func is_outdoor_action(action: String) -> bool:
	return action in OUTDOOR_ACTIONS


static func weather_effect(code: String) -> Dictionary:
	"""天气对属性的影响（叠加到 daily tick）。"""
	match code:
		"rain":
			return {"mood": -1.2, "stress": 0.6}
		"snow":
			return {"mood": 2.0, "stress": -1.0}
		"windy":
			return {"mood": -0.6, "stress": 0.3}
		"cloudy":
			return {"mood": 0.0, "stress": 0.0}
		_:
			return {"mood": 1.2, "stress": -0.6}


static func label(code: String) -> String:
	return str(WEATHER_LABELS.get(code, code))


static func icon(code: String) -> String:
	return str(WEATHER_ICONS.get(code, "🌤️"))


static func describe(code: String) -> String:
	match code:
		"rain":
			return "外面正下着雨，雨声轻轻敲着窗"
		"snow":
			return "外面飘着雪，世界安静又洁白"
		"windy":
			return "外面风很大，吹得窗框轻轻响"
		"cloudy":
			return "天色有些阴，云层压得很低"
		_:
			return "阳光正好，是个晴朗的好天气"


static func _valid_code(code: String) -> String:
	return code if code in WEATHER_CODES else "sunny"


static func _weighted_pick(weights: Array, rng: RandomNumberGenerator) -> String:
	var total := 0.0
	for w in weights:
		total += float(w)
	var roll := rng.randf() * total
	var acc := 0.0
	for index in weights.size():
		acc += float(weights[index])
		if roll <= acc:
			return WEATHER_CODES[index]
	return WEATHER_CODES[0]


static func _unix(value: Variant, fallback: int) -> int:
	var parsed := int(value)
	return parsed if parsed > 0 else fallback
