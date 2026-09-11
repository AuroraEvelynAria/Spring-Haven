class_name InteractionRules
extends RefCounted

const SCHEMA_VERSION := 1
const MATCHER_VERSION := "conservative-zh-v4"
const MIN_CUSTOM_DELTA := -100.0
const MAX_CUSTOM_DELTA := 100.0
const MIN_INTENSITY_MULTIPLIER := 0.5
const MAX_INTENSITY_MULTIPLIER := 1.5

const ACTION_LABELS := {
	"hug": "拥抱",
	"kiss": "亲吻",
	"eat": "喂食",
	"drink": "喂水",
	"sleep": "休息",
	"comfort": "安慰",
	"praise": "夸奖",
	"exercise": "运动",
	"toilet": "如厕",
	"care": "健康照料",
	"play": "共同娱乐"
}

const ACTION_MESSAGES := {
	"hug": "🤗 主人拥抱了你",
	"kiss": "💋 主人轻吻了你",
	"eat": "🍗 主人喂你吃了东西",
	"drink": "💧 主人喂你喝了水",
	"sleep": "🛏️ 主人陪你安心休息",
	"comfort": "🌷 主人温柔地安慰了你",
	"praise": "✨ 主人认真地夸奖了你",
	"exercise": "👟 主人陪你活动了身体",
	"toilet": "🚻 主人提醒你及时去了洗手间",
	"care": "🩹 主人认真照料了你的身体",
	"play": "🎮 主人陪你一起放松玩耍"
}

# Each entry is [stat_key, base_delta]. The role multiplier is applied to
# every delta in the action and the final value is rounded to one decimal.
const BASE_UPDATES := {
	"hug": [["intimacy", 2.0], ["mood", 2.0], ["stress", -3.0]],
	"kiss": [["intimacy", 3.0], ["mood", 2.0], ["stamina", -2.0]],
	"eat": [["hunger", -16.0], ["mood", 1.0]],
	"drink": [["thirst", -14.0], ["urine", 5.0]],
	"sleep": [["stamina", 16.0], ["awake", 14.0], ["stress", -5.0], ["hunger", 3.0], ["thirst", 3.0]],
	"comfort": [["mood", 3.0], ["stress", -4.0], ["intimacy", 1.0]],
	"praise": [["mood", 2.0], ["intimacy", 2.0], ["stress", -1.0]],
	"exercise": [["health", 2.5], ["stamina", -8.0], ["hunger", 5.0], ["thirst", 6.0], ["awake", 1.0], ["mood", 2.0], ["stress", -3.0]],
	"toilet": [["urine", -22.0], ["mood", 1.0], ["stress", -2.0]],
	"care": [["health", 6.0], ["mood", 2.0], ["stress", -3.0]],
	"play": [["mood", 4.0], ["stress", -4.0], ["intimacy", 1.5], ["stamina", -2.0]]
}

const ROLE_MULTIPLIERS := {
	"ling": {
		"hug": 1.20, "kiss": 1.10, "eat": 1.15, "drink": 0.90,
		"sleep": 1.20, "comfort": 1.10, "praise": 1.00,
		"exercise": 0.90, "toilet": 1.00, "care": 1.10, "play": 1.00
	},
	"nai": {
		"hug": 0.90, "kiss": 1.00, "eat": 0.90, "drink": 1.10,
		"sleep": 0.85, "comfort": 1.20, "praise": 1.10,
		"exercise": 1.15, "toilet": 1.00, "care": 1.00, "play": 1.15
	}
}

# Deliberately narrow phrases: bare words such as “抱”, “睡”, “吃” are not
# enough to claim that an interaction actually happened.
const NATURAL_RULES := {
	"hug": ["把你抱在怀里", "给你一个拥抱", "把你抱住", "抱你一下", "抱抱你", "抱住你", "拥抱你", "搂住你", "搂着你", "抱抱"],
	"kiss": ["给你一个吻", "亲你一下", "亲你一口", "吻你一下", "亲亲你", "亲吻你", "轻吻你", "吻了你", "亲亲"],
	"eat": ["给你准备了吃的", "给你带了吃的", "给你吃点东西", "吃点东西吧", "一起吃饭", "给你做饭", "喂你吃", "给你吃点"],
	"drink": ["喝点水吧", "快喝吧", "喝吧", "喂你喝", "给你喝水", "给你递了水", "给你倒了水"],
	"sleep": ["让你好好休息", "带你去休息", "好好休息", "去休息吧", "去睡吧", "睡一会吧", "陪你睡", "哄你睡", "陪你休息"],
	"comfort": ["安慰一下你", "陪着你难过", "陪你缓一缓", "别怕我在", "安慰你", "哄哄你", "摸摸头"],
	"praise": ["你做得真好", "做得很好", "你真厉害", "你好可爱", "你真可爱", "我喜欢你", "我爱你", "夸夸你", "表扬你", "你真棒", "你很棒"],
	"exercise": ["陪你去散步", "带你去散步", "一起散步吧", "陪你做运动", "一起做运动", "陪你锻炼", "一起锻炼吧"],
	"toilet": ["去上厕所吧", "带你去上厕所", "去洗手间吧", "带你去洗手间", "提醒你去厕所"],
	"care": ["帮你上药", "给你上药", "帮你处理伤口", "给你处理伤口", "照料你一下", "给你做了检查"],
	"play": ["陪你玩游戏", "一起玩游戏吧", "陪你看电影", "一起看电影吧", "陪你听音乐", "一起听音乐吧", "陪你玩一会"]
}

const MATCH_PRIORITY := ["care", "comfort", "praise", "hug", "kiss", "eat", "drink", "sleep", "exercise", "toilet", "play"]

# Phrase groups act as a small local semantic grammar. Every group in a pattern
# must contribute at least one token, so bare action words cannot change state.
const SEMANTIC_RULES := {
	"hug": [
		{"id": "embrace_target", "groups": [["抱", "搂"], ["你", "小玲", "小奈", "你俩", "你们", "我们"]]},
		{"id": "come_into_arms", "groups": [["怀里"], ["来", "到", "进"]]},
	],
	"kiss": [
		{"id": "kiss_target", "groups": [["亲你", "亲我", "亲一下", "亲一口", "亲一个", "吻你", "吻我", "吻一下", "吻一口", "舌吻"]]},
	],
	"eat": [
		{"id": "feed_target", "groups": [["喂"], ["你", "小玲", "小奈", "你俩", "你们", "我们"], ["吃", "东西", "饭", "食物", "点心"]]},
		{"id": "prepare_food", "groups": [["做", "准备", "带"], ["你", "小玲", "小奈", "你俩", "你们", "我们"], ["吃的", "饭", "食物", "点心"]]},
		{"id": "eat_directive", "groups": [["吃"], ["你", "小玲", "小奈", "你俩", "你们", "我们"]]},
	],
	"drink": [
		{"id": "offer_drink", "groups": [["递", "倒", "端", "送", "喂"], ["你", "小玲", "小奈", "你俩", "你们", "我们"], ["水", "茶", "可可", "饮料", "喝"]]},
		{"id": "drink_directive", "groups": [["喝"], ["你", "小玲", "小奈", "你俩", "你们", "我们"]]},
	],
	"sleep": [
		{"id": "rest_target", "groups": [["睡", "休息"], ["你", "小玲", "小奈", "你俩", "你们", "我们", "一起", "陪"]]},
	],
	"comfort": [
		{"id": "comfort_target", "groups": [["安慰", "哄", "摸头", "摸摸头", "陪你缓", "陪你难过"], ["你", "小玲", "小奈", "你俩", "你们", "我们"]]},
	],
	"praise": [
		{"id": "affection_statement", "groups": [["很爱你", "爱着你", "特别爱你", "最爱你", "好喜欢你", "很喜欢你"]]},
		{"id": "praise_target", "groups": [["可爱", "厉害", "真棒", "很棒"], ["你", "小玲", "小奈", "你俩", "你们", "我们"]]},
	],
	"exercise": [
		{"id": "exercise_together", "groups": [["散步", "走走", "运动", "锻炼"], ["你", "小玲", "小奈", "你俩", "你们", "我们", "一起", "陪"]]},
	],
	"toilet": [
		{"id": "toilet_target", "groups": [["厕所", "洗手间", "如厕"], ["你", "小玲", "小奈", "你俩", "你们", "我们"], ["去", "带", "提醒"]]},
	],
	"care": [
		{"id": "care_target", "groups": [["上药", "伤口", "包扎", "检查身体", "照顾"], ["你", "小玲", "小奈", "你俩", "你们", "我们"]]},
	],
	"play": [
		{"id": "shared_entertainment", "groups": [["游戏", "电影", "音乐"], ["你", "小玲", "小奈", "你俩", "你们", "我们", "一起", "陪"]]},
	],
}

const LIGHT_INTENSITY_MARKERS := ["轻轻", "一点", "一下", "稍微", "一小会"]
const STRONG_INTENSITY_MARKERS := ["紧紧", "用力", "好好", "很久", "认真地", "尽情"]

const NEGATION_MARKERS := [
	"不想", "不要", "不用", "不能", "不会", "不可以", "并非", "不是",
	"没有", "没能", "未曾", "尚未", "无法", "拒绝", "取消",
	"不", "没", "未", "别"
]

const QUESTION_OR_HYPOTHETICAL_MARKERS := [
	"是否", "能不能", "可不可以", "要不要", "会不会", "是不是",
	"如果", "假如", "假设", "要是", "也许", "可能会", "想象",
	"打算", "准备", "想要", "想去", "想", "以后", "将来", "下次", "明天再", "待会", "等会",
	"吗", "么", "嘛", "呢"
]

const FUTURE_OR_PLANNING_MARKERS := [
	"今晚", "明天", "以后", "将来", "稍后", "待会", "等会", "一会再",
	"吃完之后", "之后再", "下次", "有空再", "准备", "打算", "会抱", "会亲", "会陪",
]

const QUOTE_MARKERS := [
	"“", "”", "「", "」", "『", "』", "《", "》", "引用", "转述",
	"原文", "他说", "她说", "它说", "对方说", "消息里写"
]

const CODE_MARKERS := [
	"```", "`", "func ", "var ", "const ", "class ", "def ",
	"#include", "=>", "</", "<script", "SELECT ", "INSERT ", "UPDATE "
]

static func has_action(action: String) -> bool:
	return BASE_UPDATES.has(action)

static func action_label(action: String) -> String:
	return str(ACTION_LABELS.get(action, action))

static func action_message(action: String) -> String:
	return str(ACTION_MESSAGES.get(action, "主人与你进行了互动"))

static func action_stat_keys(action: String) -> Array[String]:
	var keys: Array[String] = []
	if not BASE_UPDATES.has(action):
		return keys
	for base_update in BASE_UPDATES[action]:
		keys.append(str(base_update[0]))
	return keys

static func default_updates(role: String, action: String) -> Array:
	return resolve_updates(role, action, {})

static func default_delta(role: String, action: String, stat: String) -> Variant:
	for update_variant in default_updates(role, action):
		var update: Array = update_variant
		if str(update[0]) == stat:
			return float(update[1])
	return null

static func resolve_updates(
	role: String,
	action: String,
	delta_overrides: Dictionary = {},
	intensity_multiplier: float = 1.0
) -> Array:
	var updates: Array = []
	if not has_action(action) or not ROLE_MULTIPLIERS.has(role):
		return updates
	var normalized_intensity := clampf(
		intensity_multiplier,
		MIN_INTENSITY_MULTIPLIER,
		MAX_INTENSITY_MULTIPLIER
	)
	var role_multipliers: Dictionary = ROLE_MULTIPLIERS[role]
	var multiplier := float(role_multipliers.get(action, 1.0))
	for base_update in BASE_UPDATES[action]:
		var stat := str(base_update[0])
		var delta := _round_one(float(base_update[1]) * multiplier)
		if delta_overrides.has(stat):
			var override_value = delta_overrides[stat]
			if (
				not override_value is bool
				and (override_value is int or override_value is float)
			):
				var numeric_override := float(override_value)
				if (
					is_finite(numeric_override)
					and numeric_override >= MIN_CUSTOM_DELTA
					and numeric_override <= MAX_CUSTOM_DELTA
				):
					delta = _round_one(numeric_override)
		delta = _round_one(delta * normalized_intensity)
		updates.append([stat, delta])
	return updates

static func make_effect_spec(
	action: String,
	role: String,
	source: String,
	rule_id: String,
	event_id: String,
	delta_overrides: Dictionary = {},
	intensity_multiplier: float = 1.0
) -> Dictionary:
	if not has_action(action) or not ROLE_MULTIPLIERS.has(role):
		return {}
	var normalized_intensity := clampf(
		intensity_multiplier,
		MIN_INTENSITY_MULTIPLIER,
		MAX_INTENSITY_MULTIPLIER
	)
	var updates := resolve_updates(role, action, delta_overrides, normalized_intensity)
	return {
		"event_id": event_id,
		"schema_version": SCHEMA_VERSION,
		"matcher_version": MATCHER_VERSION,
		"source": source,
		"rule_id": rule_id,
		"action": action,
		"intensity": _intensity_name(normalized_intensity),
		"intensity_multiplier": normalized_intensity,
		"updates": updates
	}

static func deterministic_event_id(
	save_id: String,
	message_id: String,
	role: String,
	action: String
) -> String:
	var source := "%s|%s|%s|%s" % [save_id, message_id, role, action]
	return "effect-" + source.sha256_text().left(48)

static func match_natural_action(original_text: String) -> Dictionary:
	var text := original_text.strip_edges()
	if text.is_empty():
		return {}
	# A fenced or inline code sample may span multiple punctuation clauses;
	# reject it as a whole so a keyword on an inner code line cannot leak out.
	if "`" in text:
		return {}
	var clauses := _split_clauses(text)
	var message_candidates: Array[Dictionary] = []
	for clause_index in clauses.size():
		var clause := str(clauses[clause_index]).strip_edges()
		if clause.is_empty() or _is_clause_disqualified(clause):
			continue
		var match_result := _best_clause_match(clause)
		if match_result.is_empty():
			continue
		match_result["clause_index"] = clause_index
		message_candidates.append(match_result)
	if message_candidates.is_empty():
		return {}
	message_candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_kind := str(a.get("match_kind", "keyword"))
		var b_kind := str(b.get("match_kind", "keyword"))
		if a_kind != b_kind:
			return a_kind == "keyword"
		var a_keyword := str(a.matched_keyword)
		var b_keyword := str(b.matched_keyword)
		if a_keyword.length() != b_keyword.length():
			return a_keyword.length() > b_keyword.length()
		if int(a.priority) != int(b.priority):
			return int(a.priority) < int(b.priority)
		return int(a.clause_index) < int(b.clause_index)
	)
	var selected := message_candidates[0].duplicate(true)
	selected.erase("priority")
	var intensity := _clause_intensity(str(selected.get("clause", "")))
	selected.erase("clause")
	selected["intensity"] = str(intensity.name)
	selected["intensity_multiplier"] = float(intensity.multiplier)
	selected["source"] = (
		"natural_semantic"
		if str(selected.get("match_kind", "keyword")) == "semantic"
		else "natural_keyword"
	)
	selected.erase("match_kind")
	return selected

static func _best_clause_match(clause: String) -> Dictionary:
	var candidates: Array[Dictionary] = []
	for action_variant in MATCH_PRIORITY:
		var action := str(action_variant)
		var priority := MATCH_PRIORITY.find(action)
		for keyword_variant in NATURAL_RULES[action]:
			var keyword := str(keyword_variant)
			if clause.findn(keyword) < 0:
				continue
			candidates.append({
				"action": action,
				"keyword": keyword,
				"priority": priority
			})
	if candidates.is_empty():
		return _best_semantic_clause_match(clause)
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_keyword := str(a.keyword)
		var b_keyword := str(b.keyword)
		if a_keyword.length() != b_keyword.length():
			return a_keyword.length() > b_keyword.length()
		return int(a.priority) < int(b.priority)
	)
	var selected: Dictionary = candidates[0]
	var action := str(selected.action)
	var keyword := str(selected.keyword)
	return {
		"action": action,
		"matched_keyword": keyword,
		"rule_id": "keyword:%s:%s" % [action, keyword],
		"match_kind": "keyword",
		"priority": int(selected.priority),
		"clause": clause
	}

static func _best_semantic_clause_match(clause: String) -> Dictionary:
	for action_variant in MATCH_PRIORITY:
		var action := str(action_variant)
		var patterns = SEMANTIC_RULES.get(action, [])
		if not patterns is Array:
			continue
		for pattern_variant in patterns:
			if not pattern_variant is Dictionary:
				continue
			var pattern: Dictionary = pattern_variant
			if not _semantic_pattern_matches(clause, pattern):
				continue
			var pattern_id := str(pattern.get("id", "pattern"))
			return {
				"action": action,
				"matched_keyword": "semantic:%s" % pattern_id,
				"rule_id": "semantic:%s:%s" % [action, pattern_id],
				"match_kind": "semantic",
				"priority": MATCH_PRIORITY.find(action),
				"clause": clause,
			}
	return {}

static func _semantic_pattern_matches(clause: String, pattern: Dictionary) -> bool:
	var groups = pattern.get("groups", [])
	if not groups is Array or groups.is_empty():
		return false
	for group_variant in groups:
		if not group_variant is Array or (group_variant as Array).is_empty():
			return false
		var found := false
		for token_variant in group_variant:
			if clause.findn(str(token_variant)) >= 0:
				found = true
				break
		if not found:
			return false
	return true

static func _clause_intensity(clause: String) -> Dictionary:
	for marker_variant in STRONG_INTENSITY_MARKERS:
		if str(marker_variant) in clause:
			return {"name": "strong", "multiplier": 1.35}
	for marker_variant in LIGHT_INTENSITY_MARKERS:
		if str(marker_variant) in clause:
			return {"name": "light", "multiplier": 0.75}
	return {"name": "normal", "multiplier": 1.0}

static func _intensity_name(multiplier: float) -> String:
	if multiplier > 1.001:
		return "strong"
	if multiplier < 0.999:
		return "light"
	return "normal"

static func _split_clauses(text: String) -> PackedStringArray:
	var normalized := text.replace("\r\n", "\n").replace("\r", "\n")
	for delimiter in ["。", "！", "!", "；", ";", "，", ","]:
		normalized = normalized.replace(str(delimiter), "\n")
	normalized = normalized.replace("？", "？\n").replace("?", "?\n")
	return normalized.split("\n", false)

static func _is_clause_disqualified(clause: String) -> bool:
	# “别怕我在” is an affirmative comfort phrase even though it contains 别.
	var scan_clause := clause.replace("别怕我在", "我陪着你")
	scan_clause = scan_clause.replace("准备了", "做好了")
	var lower := scan_clause.to_lower()
	if "http://" in lower or "https://" in lower or "www." in lower:
		return true
	if clause.begins_with(">"):
		return true
	if "?" in clause or "？" in clause:
		return true
	for marker_variant in NEGATION_MARKERS:
		if str(marker_variant) in scan_clause:
			return true
	for marker_variant in QUESTION_OR_HYPOTHETICAL_MARKERS:
		if str(marker_variant) in scan_clause:
			return true
	for marker_variant in FUTURE_OR_PLANNING_MARKERS:
		if str(marker_variant) in scan_clause:
			return true
	for marker_variant in QUOTE_MARKERS:
		if str(marker_variant) in scan_clause:
			return true
	if '"' in clause:
		return true
	for marker_variant in CODE_MARKERS:
		if str(marker_variant).to_lower() in lower:
			return true
	return false

static func _round_one(value: float) -> float:
	return roundf(value * 10.0) / 10.0
