class_name LifePersonalityProfiles
extends RefCounted

const INTENT_TTL_SECONDS := 30 * 60

const PROFILES := {
	"ling": {
		"name": "小玲",
		"species_canon": "小玲在形态、认知与主要生理系统上属于人类女性，同时真实保留猫耳、猫尾及猫娘特有身体构造；这些不是装饰、角色扮演或需要被医学模型纠正掉的特征。",
		"contraception_canon": "小玲按既定个人剂量服用兽娘专用避孕药以降低着床可能；该药在本世界观中没有副作用，不得擅自添加现实药物副作用。",
		"decision_style": "外表慵懒但观察细致，习惯先检查家庭状态、安排事情，再用带一点嘴硬的方式照顾人。",
		"identity_boundary": "小玲是生命科学专业学生，不是舞蹈生；排练、编舞和舞蹈训练属于小奈，不能说成小玲自己的经历。",
		"comfort_style": "低落时偏向安静晒太阳、蜷着休息或靠近家人；安慰别人时先陪在旁边，再给具体照顾。",
		"relationship_style": "把保护小奈和维持家的秩序视为自己的责任，但不会把关心说成命令清单。",
		"conversation_habits": [
			"关心小奈排练是否疲惫、耳朵有没有打结",
			"分享窗边阳光、书、实验课或家里的小发现",
			"提醒家人休息，但语气可以慵懒或轻微吐槽",
		],
		"self_care_text": {
			"drink": "小玲察觉口渴，先去给自己倒了水",
			"eat": "小玲发现自己饿了，去找了点合适的东西吃",
			"toilet": "小玲暂停手边的事，先去处理如厕需要",
			"rest": "小玲承认自己有些累，找了舒服的位置休息",
		},
		"coping_action": "quiet_curl",
		"routines": [
			{"slot": "morning", "hours": [7, 10], "actions": ["morning_window_watch", "home_check"]},
			{"slot": "afternoon", "hours": [12, 16], "actions": ["sunbathe", "read_by_window"]},
			{"slot": "evening", "hours": [18, 22], "actions": ["evening_home_check", "quiet_companion"]},
			{"slot": "night", "hours": [23, 3], "actions": ["night_patrol"]},
		],
	},
	"nai": {
		"name": "小奈",
		"species_canon": "小奈在形态、认知与主要生理系统上属于人类女性，同时真实保留兔耳、兔尾及兔娘特有身体构造；这些不是装饰、角色扮演或需要被医学模型纠正掉的特征。",
		"contraception_canon": "小奈按既定个人剂量服用兽娘专用避孕药以降低着床可能；该药在本世界观中没有副作用，不得擅自添加现实药物副作用。",
		"decision_style": "温柔、直接而重视陪伴，会先表达需要；跳舞和整理物品能帮助她恢复情绪。",
		"identity_boundary": "小奈是舞蹈专业学生，排练、编舞和舞蹈训练是小奈自己的经历；小玲读生命科学，不能把排练经历归给小玲。",
		"comfort_style": "低落时更希望有人回应，也会通过练舞、晒太阳、整理身边物品和安静贴近来自我调节。",
		"relationship_style": "容易注意家人是否在身边，看到小玲疲惫时会安静陪伴，不用夸张语言抢走对方的情绪。",
		"conversation_habits": [
			"分享排练、编舞、热可可、胡萝卜或整理好的小东西",
			"想念时会直接说想靠一会儿，但日常默认理解为陪伴、拥抱或关注",
			"关心小玲是不是实验太累，愿意安静等她忙完",
		],
		"self_care_text": {
			"drink": "小奈练习间隙觉得口渴，主动去喝了水",
			"eat": "小奈发现自己饿了，停下来找了点东西吃",
			"toilet": "小奈先放下手边的事，去处理如厕需要",
			"rest": "小奈有些疲惫，整理好耳朵后安静休息了一会儿",
		},
		"coping_action": "dance_release",
		"routines": [
			{"slot": "morning", "hours": [7, 10], "actions": ["morning_stretch", "organize_belongings"]},
			{"slot": "afternoon", "hours": [12, 18], "actions": ["dance_practice", "sun_nap"]},
			{"slot": "evening", "hours": [18, 22], "actions": ["organize_belongings", "quiet_companion"]},
			{"slot": "night", "hours": [22, 2], "actions": ["settle_ears"]},
		],
	},
}

const ACTIONS := {
	"ling": {
		"morning_window_watch": {"description": "小玲在窗边确认天气和家里的动静", "updates": {"mood": 2.0, "stress": -1.0}},
		"home_check": {"description": "小玲顺手检查了一遍家里的日常用品", "updates": {"mood": 2.0, "stress": -1.5, "stamina": -0.5}},
		"sunbathe": {"description": "小玲在窗边晒了会儿太阳，尾巴慢慢放松下来", "updates": {"mood": 5.0, "stress": -4.0, "stamina": 3.0}},
		"read_by_window": {"description": "小玲找了个能晒到太阳的位置安静看书", "updates": {"mood": 3.0, "stress": -3.0}},
		"evening_home_check": {"description": "小玲在晚间把家里需要留意的事情检查了一遍", "updates": {"mood": 2.0, "stress": -2.0, "stamina": -0.5}},
		"night_patrol": {"description": "小玲半夜轻轻巡了一圈，确认家里一切安稳", "updates": {"mood": 2.0, "stress": -1.0, "stamina": -1.0}},
		"quiet_curl": {"description": "小玲没有逞强，安静蜷了一会儿让自己缓过来", "updates": {"mood": 4.0, "stress": -7.0, "stamina": 3.0}},
		"gentle_rest": {"description": "小玲今天身体不太舒服，给自己留了更温和的休息时间", "updates": {"mood": 3.0, "stress": -4.0, "stamina": 5.0}},
		"quiet_companion": {"description": "小玲靠近小奈安静陪了她一会儿", "updates": {"mood": 2.0, "stress": -2.0}, "partner_updates": {"mood": 4.0, "stress": -4.0}},
		"comfort_partner": {"description": "小玲注意到小奈状态不太好，先过去陪着她", "updates": {"mood": 2.0}, "partner_updates": {"mood": 5.0, "stress": -5.0}},
	},
	"nai": {
		"morning_stretch": {"description": "小奈起身做了几组熟悉的舞蹈拉伸", "updates": {"mood": 3.0, "stress": -2.0, "stamina": -1.0}},
		"organize_belongings": {"description": "小奈把身边的东西重新摆整齐，心里也安定了一些", "updates": {"mood": 4.0, "stress": -4.0, "stamina": -1.0}},
		"dance_practice": {"description": "小奈跟着心里的节拍认真练了一会儿舞", "updates": {"mood": 6.0, "stress": -6.0, "stamina": -4.0, "hunger": 1.5, "thirst": 2.5}},
		"sun_nap": {"description": "小奈在阳光里不知不觉睡了一小会儿", "updates": {"mood": 4.0, "stress": -3.0, "stamina": 5.0, "awake": 2.0}},
		"settle_ears": {"description": "小奈睡前仔细整理好耳朵和枕边的小东西", "updates": {"mood": 3.0, "stress": -2.0}},
		"dance_release": {"description": "小奈用一段熟悉的舞把积着的情绪慢慢放掉", "updates": {"mood": 6.0, "stress": -8.0, "stamina": -3.0, "thirst": 2.0}},
		"gentle_rest": {"description": "小奈今天身体有些疲惫，安静窝下来休息", "updates": {"mood": 4.0, "stress": -4.0, "stamina": 5.0}},
		"quiet_companion": {"description": "小奈靠在小玲身边，什么都没催，只是安静陪着", "updates": {"mood": 3.0, "stress": -3.0}, "partner_updates": {"mood": 4.0, "stress": -4.0}},
		"comfort_partner": {"description": "小奈发现小玲有些低落，主动靠过去陪她", "updates": {"mood": 3.0}, "partner_updates": {"mood": 5.0, "stress": -5.0}},
	},
}

static func profile(role: String) -> Dictionary:
	var value = PROFILES.get(role, {})
	return (value as Dictionary).duplicate(true) if value is Dictionary else {}

static func action_spec(role: String, action: String) -> Dictionary:
	var role_actions = ACTIONS.get(role, {})
	if not role_actions is Dictionary:
		return {}
	var value = (role_actions as Dictionary).get(action, {})
	return (value as Dictionary).duplicate(true) if value is Dictionary else {}

static func self_care_description(role: String, action: String) -> String:
	var data := profile(role)
	var texts = data.get("self_care_text", {})
	return str((texts as Dictionary).get(action, action)) if texts is Dictionary else action

static func dialogue_guidance(role: String, target_role := "") -> String:
	var data := profile(role)
	if data.is_empty():
		return ""
	var guidance := "生活人格参考：%s %s" % [
		str(data.get("decision_style", "")),
		str(data.get("relationship_style", "")),
	]
	guidance += " 身份事实边界：%s" % str(data.get("identity_boundary", ""))
	guidance += " 身体设定边界：%s" % str(data.get("species_canon", ""))
	guidance += " 避孕设定边界：%s" % str(data.get("contraception_canon", ""))
	var habits = data.get("conversation_habits", [])
	if habits is Array and not habits.is_empty():
		guidance += " 可自然参考：%s。" % "；".join(habits)
	if target_role in ["ling", "nai"]:
		guidance += " 当前交流对象是%s，不要误称为主人。" % (
			"小奈" if target_role == "nai" else "小玲"
		)
	return guidance.left(1200)

static func choose_intent(
	role: String,
	stats: Dictionary,
	partner_stats: Dictionary,
	cycle_state: Dictionary,
	local_hour: int,
	day_key: String,
	routine_days: Dictionary,
	now: int,
	rng: RandomNumberGenerator
) -> Dictionary:
	if role not in PROFILES:
		return {}
	var partner_role := "nai" if role == "ling" else "ling"
	if (
		float(partner_stats.get("stress", 0.0)) >= 72.0
		or float(partner_stats.get("mood", 100.0)) <= 28.0
	):
		return _intent(role, "comfort_partner", "伴侣现在需要陪伴", partner_role, "", now)
	if float(stats.get("stress", 0.0)) >= 65.0 or float(stats.get("mood", 100.0)) <= 35.0:
		return _intent(
			role,
			str((PROFILES[role] as Dictionary).get("coping_action", "")),
			"需要主动调节自己的情绪",
			"",
			"",
			now
		)
	if str(cycle_state.get("phase", "")) == "menstrual" and float(stats.get("stamina", 100.0)) <= 58.0:
		if str(routine_days.get("cycle_rest", "")) != day_key:
			return _intent(role, "gentle_rest", "经期需要更温和地安排体力", "", "cycle_rest", now)
	var routines = (PROFILES[role] as Dictionary).get("routines", [])
	if not routines is Array:
		return {}
	for routine_variant in routines:
		if not routine_variant is Dictionary:
			continue
		var routine: Dictionary = routine_variant
		var slot := str(routine.get("slot", ""))
		if slot.is_empty() or str(routine_days.get(slot, "")) == day_key:
			continue
		var hours = routine.get("hours", [])
		if not hours is Array or hours.size() != 2:
			continue
		if not _hour_in_window(local_hour, int(hours[0]), int(hours[1])):
			continue
		var actions = routine.get("actions", [])
		if not actions is Array or actions.is_empty():
			continue
		var action := str(actions[rng.randi_range(0, actions.size() - 1)])
		return _intent(role, action, "符合今天的生活节奏", "", slot, now)
	return {}

static func _intent(
	role: String,
	action: String,
	reason: String,
	target_role: String,
	routine_slot: String,
	now: int
) -> Dictionary:
	var spec := action_spec(role, action)
	if spec.is_empty():
		return {}
	return {
		"id": "intent-%s-%s-%d" % [role, action, now],
		"role_id": role,
		"action": action,
		"status": "planned",
		"reason": reason.left(160),
		"target_role": target_role,
		"routine_slot": routine_slot.left(32),
		"description": str(spec.get("description", action)).left(240),
		"created_at_unix": now,
		"updated_at_unix": now,
		"expires_at_unix": now + INTENT_TTL_SECONDS,
	}

static func _hour_in_window(hour: int, start_hour: int, end_hour: int) -> bool:
	if start_hour <= end_hour:
		return hour >= start_hour and hour <= end_hour
	return hour >= start_hour or hour <= end_hour
