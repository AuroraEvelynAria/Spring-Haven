class_name LifeLabTaskController
extends Node

signal task_changed(role: String, task: Dictionary)
signal needs_changed(role: String, needs: Dictionary)
signal command_result(result: Dictionary)
signal social_event_ready(event: Dictionary)

const ACTION_STATIONS := {
	"drink": "water",
	"eat": "food",
	"dine": "dining",
	"rest": "rest",
	"toilet": "toilet",
	"plant": "plant",
	"dance": "dance",
	"socialize": "social",
	"cook": "food",
	"brew_tea": "water",
	"read": "rest",
	"watch": "rest",
	"game": "social",
	"music": "dance",
	"clean": "dining",
	"photo": "plant",
	"cuddle": "social",
	"share_day": "social",
}

const SOCIAL_ACTIONS := {
	"dine": true,
	"plant": true,
	"dance": true,
	"socialize": true,
	"cook": true,
	"brew_tea": true,
	"read": true,
	"watch": true,
	"game": true,
	"music": true,
	"clean": true,
	"photo": true,
	"cuddle": true,
	"share_day": true,
}

const ACTION_LABELS := {
	"drink": "喝水",
	"eat": "找食物",
	"dine": "一起用餐",
	"rest": "休息",
	"toilet": "如厕",
	"plant": "照料绿植",
	"dance": "排练",
	"socialize": "聊天",
	"cook": "一起做饭",
	"brew_tea": "泡茶",
	"read": "读书",
	"watch": "看节目",
	"game": "玩游戏",
	"music": "听音乐",
	"clean": "收拾房间",
	"photo": "拍生活照片",
	"cuddle": "依偎",
	"share_day": "分享今天",
	"follow_player": "跟随主人",
	"follow_role": "跟随对方",
	"wander": "自由探索",
	"stop": "停下",
}

@export var ling_path: NodePath
@export var nai_path: NodePath
@export var player_path: NodePath
@export var room_path: NodePath
@export var autonomous_enabled := true
@export_range(3.0, 120.0, 1.0) var autonomous_interval_min := 8.0
@export_range(3.0, 180.0, 1.0) var autonomous_interval_max := 16.0

var _tasks: Dictionary = {"ling": {}, "nai": {}}
var _needs := {
	"ling": {"hunger": 46.0, "thirst": 38.0, "stamina": 66.0, "mood": 72.0},
	"nai": {"hunger": 38.0, "thirst": 44.0, "stamina": 78.0, "mood": 80.0},
}
var _next_autonomous := {"ling": 4.0, "nai": 7.0}
var _visual_context := {"ling": {}, "nai": {}}
var _social_groups: Dictionary = {}
var _elapsed := 0.0
var _sequence := 0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 20260722
	Settings.runtime_tuning_changed.connect(_apply_runtime_tuning)
	_apply_runtime_tuning(Settings.get_runtime_tuning())
	for role in ["ling", "nai"]:
		var agent := _agent(role)
		if not is_instance_valid(agent):
			continue
		if agent.has_signal("destination_reached"):
			agent.connect("destination_reached", _on_destination_reached.bind(role))
		if agent.has_signal("movement_failed"):
			agent.connect("movement_failed", _on_movement_failed.bind(role))

func _apply_runtime_tuning(config: Dictionary) -> void:
	autonomous_interval_min = float(config.get("life_lab_min_seconds", 8))
	autonomous_interval_max = maxf(
		autonomous_interval_min,
		float(config.get("life_lab_max_seconds", 16))
	)


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < 1.0:
		return
	var seconds := _elapsed
	_elapsed = 0.0
	for role in ["ling", "nai"]:
		_update_needs(role, seconds)
		_next_autonomous[role] = float(_next_autonomous.get(role, 0.0)) - seconds
		if autonomous_enabled and float(_next_autonomous[role]) <= 0.0 and _role_is_idle(role):
			_start_autonomous_action(role)


func set_autonomous_enabled(enabled: bool) -> void:
	autonomous_enabled = enabled
	if enabled:
		for role in ["ling", "nai"]:
			_next_autonomous[role] = minf(float(_next_autonomous.get(role, 2.0)), 2.0)


func execute_text(text: String, default_role := "ling") -> Dictionary:
	var normalized := text.strip_edges()
	if normalized.is_empty():
		return _emit_command_result({"ok": false, "message": "请输入生活行为指令"})
	var roles := _resolve_roles(normalized, default_role)
	var action := _resolve_action(normalized)
	if action.is_empty():
		return _emit_command_result({
			"ok": false,
			"message": "未识别行为，可尝试：过来我这、喝水、吃饭、休息、照料花、排练、互相跟随",
		})
	var target_role := ""
	if action == "follow_role":
		if "小玲" in normalized and "小奈" in normalized:
			if normalized.find("小玲") < normalized.find("小奈"):
				roles = ["ling"]
				target_role = "nai"
			else:
				roles = ["nai"]
				target_role = "ling"
		else:
			target_role = "nai" if roles[0] == "ling" else "ling"
	var task_ids: Array[String] = []
	var group_id := ""
	if roles.size() > 1 and SOCIAL_ACTIONS.has(action):
		_sequence += 1
		group_id = "group-%d-%d" % [Time.get_ticks_msec(), _sequence]
	for role in roles:
		var result := request_action(role, action, target_role, group_id, "user", roles)
		if bool(result.get("ok", false)):
			task_ids.append(str(result.get("task_id", "")))
	var response := {
		"ok": not task_ids.is_empty(),
		"roles": roles,
		"action": action,
		"target_role": target_role,
		"task_ids": task_ids,
		"message": "%s：%s" % [_role_names(roles), str(ACTION_LABELS.get(action, action))],
	}
	return _emit_command_result(response)


func request_action(
	role: String,
	action: String,
	target_role := "",
	group_id := "",
	initiated_by := "autonomous",
	participant_role_ids: Array[String] = []
) -> Dictionary:
	if role not in ["ling", "nai"] or not ACTION_LABELS.has(action):
		return {"ok": false, "message": "角色或动作无效"}
	var agent := _agent(role)
	if not is_instance_valid(agent):
		return {"ok": false, "message": "找不到角色代理"}
	if action == "stop":
		agent.call("command_stop")
		_set_task(role, {})
		return {"ok": true, "task_id": ""}
	_sequence += 1
	var task_id := "lab-%s-%d-%d" % [role, Time.get_ticks_msec(), _sequence]
	var task := {
		"id": task_id,
		"role_id": role,
		"action": action,
		"status": "planned",
		"target_role": target_role,
		"group_id": group_id,
		"initiated_by": initiated_by,
		"station_id": "",
		"created_at_msec": Time.get_ticks_msec(),
		"updated_at_msec": Time.get_ticks_msec(),
	}
	if not group_id.is_empty() and SOCIAL_ACTIONS.has(action):
		_register_social_group(group_id, action, participant_role_ids)
	_set_task(role, task)
	if action == "follow_player":
		var player := _player()
		if not is_instance_valid(player):
			return _fail_task(role, "主人位置不可用")
		task["status"] = "executing"
		_set_task(role, task)
		agent.call("command_follow", player)
		return {"ok": true, "task_id": task_id}
	if action == "follow_role":
		var other_role := target_role if target_role in ["ling", "nai"] else ("nai" if role == "ling" else "ling")
		var target := _agent(other_role)
		if not is_instance_valid(target) or other_role == role:
			return _fail_task(role, "跟随对象不可用")
		task["target_role"] = other_role
		task["status"] = "executing"
		_set_task(role, task)
		agent.call("command_follow", target)
		return {"ok": true, "task_id": task_id}
	var station_id := str(ACTION_STATIONS.get(action, ""))
	if action == "wander":
		station_id = _random_exploration_station()
	var station := _station(station_id)
	if not is_instance_valid(station):
		return _fail_task(role, "生活站点不可用：%s" % station_id)
	task["station_id"] = station_id
	task["status"] = "moving"
	_set_task(role, task)
	var target_position := _station_target(station_id, role)
	if not target_position.is_finite():
		return _fail_task(role, "生活站点双槽位不可用：%s" % station_id)
	agent.call("command_move_to", target_position, station_id)
	return {"ok": true, "task_id": task_id}


func get_task(role: String) -> Dictionary:
	var value = _tasks.get(role, {})
	return (value as Dictionary).duplicate(true) if value is Dictionary else {}


func get_needs(role: String) -> Dictionary:
	var value = _needs.get(role, {})
	return (value as Dictionary).duplicate(true) if value is Dictionary else {}


func get_snapshot() -> Dictionary:
	return {
		"protocol": "spring_heaven.life_lab.v1",
		"autonomous_enabled": autonomous_enabled,
		"roles": {
			"ling": {"task": get_task("ling"), "needs": get_needs("ling"), "vision": get_visual_context("ling")},
			"nai": {"task": get_task("nai"), "needs": get_needs("nai"), "vision": get_visual_context("nai")},
		},
	}


func set_visual_context(role: String, description: String, provider := "unknown") -> void:
	if role not in ["ling", "nai"]:
		return
	_visual_context[role] = {
		"description": description.strip_edges().left(1600),
		"provider": provider.strip_edges().left(64),
		"observed_at_unix": int(Time.get_unix_time_from_system()),
	}


func get_visual_context(role: String) -> Dictionary:
	var value = _visual_context.get(role, {})
	return (value as Dictionary).duplicate(true) if value is Dictionary else {}


func _on_destination_reached(label: String, _position: Vector3, role: String) -> void:
	var task := get_task(role)
	if task.is_empty() or str(task.get("status", "")) != "moving":
		return
	if str(task.get("station_id", "")) != label:
		return
	task["status"] = "interacting"
	task["updated_at_msec"] = Time.get_ticks_msec()
	_set_task(role, task)
	_complete_interaction.call_deferred(role, str(task.get("id", "")))


func _complete_interaction(role: String, task_id: String) -> void:
	await get_tree().create_timer(1.2).timeout
	if not is_inside_tree():
		return
	var task := get_task(role)
	if str(task.get("id", "")) != task_id or str(task.get("status", "")) != "interacting":
		return
	_apply_action_effect(role, str(task.get("action", "")))
	task["status"] = "completed"
	task["updated_at_msec"] = Time.get_ticks_msec()
	_set_task(role, task)
	_maybe_emit_social_event(task)
	_next_autonomous[role] = _rng.randf_range(autonomous_interval_min, autonomous_interval_max)
	_clear_completed_task.call_deferred(role, task_id)


func _clear_completed_task(role: String, task_id: String) -> void:
	await get_tree().create_timer(1.5).timeout
	if not is_inside_tree():
		return
	var task := get_task(role)
	if str(task.get("id", "")) == task_id and str(task.get("status", "")) == "completed":
		_set_task(role, {})


func _on_movement_failed(reason: String, role: String) -> void:
	var task := get_task(role)
	if task.is_empty():
		return
	task["status"] = "failed"
	task["failure_reason"] = reason.left(120)
	task["updated_at_msec"] = Time.get_ticks_msec()
	_set_task(role, task)
	_next_autonomous[role] = 3.0


func _start_autonomous_action(role: String) -> void:
	var needs := get_needs(role)
	var action := "wander"
	if float(needs.get("thirst", 0.0)) >= 70.0:
		action = "drink"
	elif float(needs.get("hunger", 0.0)) >= 72.0:
		action = "eat"
	elif float(needs.get("stamina", 100.0)) <= 28.0:
		action = "rest"
	else:
		var personality_actions := (
			["plant", "brew_tea", "read", "socialize", "clean", "wander", "rest"]
			if role == "ling"
			else ["dance", "music", "game", "photo", "socialize", "wander", "dine"]
		)
		action = str(personality_actions[_rng.randi_range(0, personality_actions.size() - 1)])
	request_action(role, action)
	_next_autonomous[role] = _rng.randf_range(autonomous_interval_min, autonomous_interval_max)


func _update_needs(role: String, seconds: float) -> void:
	var needs := get_needs(role)
	needs["hunger"] = clampf(float(needs.hunger) + seconds * (0.16 if role == "ling" else 0.19), 0.0, 100.0)
	needs["thirst"] = clampf(float(needs.thirst) + seconds * (0.22 if role == "ling" else 0.25), 0.0, 100.0)
	needs["stamina"] = clampf(float(needs.stamina) - seconds * (0.10 if role == "ling" else 0.08), 0.0, 100.0)
	_needs[role] = needs
	needs_changed.emit(role, needs.duplicate(true))


func _apply_action_effect(role: String, action: String) -> void:
	var needs := get_needs(role)
	match action:
		"drink":
			needs["thirst"] = maxf(0.0, float(needs.thirst) - 48.0)
		"eat", "dine", "cook":
			needs["hunger"] = maxf(0.0, float(needs.hunger) - 44.0)
		"brew_tea":
			needs["thirst"] = maxf(0.0, float(needs.thirst) - 32.0)
			needs["mood"] = minf(100.0, float(needs.mood) + 3.0)
		"rest":
			needs["stamina"] = minf(100.0, float(needs.stamina) + 38.0)
		"plant", "dance", "socialize", "read", "watch", "game", "music", "clean", "photo", "cuddle", "share_day":
			needs["mood"] = minf(100.0, float(needs.mood) + 4.0)
			needs["stamina"] = maxf(0.0, float(needs.stamina) - (5.0 if action in ["dance", "clean"] else 2.0))
	_needs[role] = needs
	needs_changed.emit(role, needs.duplicate(true))


func _resolve_roles(text: String, default_role: String) -> Array[String]:
	if "她们" in text or "两个人" in text or "一起" in text or "都去" in text:
		return ["ling", "nai"]
	var has_ling := "小玲" in text
	var has_nai := "小奈" in text
	if has_ling and has_nai:
		return ["ling", "nai"]
	if has_ling:
		return ["ling"]
	if has_nai:
		return ["nai"]
	return [default_role if default_role in ["ling", "nai"] else "ling"]


func _resolve_action(text: String) -> String:
	if "别跟" in text or "停下" in text or "停止" in text or "待命" in text:
		return "stop"
	if "跟着小" in text or "跟随小" in text or "去找小" in text:
		return "follow_role"
	if "过来" in text or "来我这" in text or "跟着我" in text or "跟随我" in text:
		return "follow_player"
	if "喝水" in text or "口渴" in text or "饮水" in text:
		return "drink"
	if "一起吃" in text or "用餐" in text or "餐桌" in text:
		return "dine"
	if "吃饭" in text or "吃东西" in text or "饿" in text:
		return "eat"
	if "休息" in text or "睡觉" in text or "沙发" in text:
		return "rest"
	if "厕所" in text or "卫生间" in text or "如厕" in text:
		return "toilet"
	if "拍照" in text or "照片" in text or "合影" in text:
		return "photo"
	if "花" in text or "绿植" in text or "浇水" in text:
		return "plant"
	if "排练" in text or "跳舞" in text or "舞蹈" in text:
		return "dance"
	if "今天过得" in text or "分享今天" in text or "聊今天" in text:
		return "share_day"
	if "聊天" in text or "聊聊" in text:
		return "socialize"
	if "做饭" in text or "做菜" in text or "下厨" in text:
		return "cook"
	if "泡茶" in text or "喝茶" in text or "沏茶" in text:
		return "brew_tea"
	if "读书" in text or "看书" in text or "阅读" in text:
		return "read"
	if "看电视" in text or "看电影" in text or "看节目" in text:
		return "watch"
	if "游戏" in text or "玩一局" in text:
		return "game"
	if "听歌" in text or "音乐" in text:
		return "music"
	if "打扫" in text or "收拾" in text or "清洁" in text:
		return "clean"
	if "抱抱" in text or "拥抱" in text or "依偎" in text:
		return "cuddle"
	if "探索" in text or "随便走" in text or "逛逛" in text:
		return "wander"
	return ""


func _role_is_idle(role: String) -> bool:
	var task := get_task(role)
	return task.is_empty() or str(task.get("status", "")) in ["completed", "failed"]


func _random_exploration_station() -> String:
	var values := ["water", "food", "dining", "rest", "plant", "dance", "social"]
	return str(values[_rng.randi_range(0, values.size() - 1)])


func _register_social_group(group_id: String, action: String, participants: Array[String]) -> void:
	if _social_groups.has(group_id):
		return
	var normalized: Array[String] = []
	for role in participants:
		if role in ["ling", "nai"] and role not in normalized:
			normalized.append(role)
	_social_groups[group_id] = {
		"action": action,
		"participant_role_ids": normalized,
		"completed_role_ids": [],
	}


func _maybe_emit_social_event(task: Dictionary) -> void:
	var action := str(task.get("action", ""))
	if not SOCIAL_ACTIONS.has(action):
		return
	var actor_role := str(task.get("role_id", ""))
	var participants: Array[String] = []
	var group_id := str(task.get("group_id", ""))
	if not group_id.is_empty() and _social_groups.has(group_id):
		var group: Dictionary = _social_groups[group_id]
		var completed: Array = group.get("completed_role_ids", [])
		if actor_role not in completed:
			completed.append(actor_role)
		group["completed_role_ids"] = completed
		_social_groups[group_id] = group
		for role in group.get("participant_role_ids", []):
			participants.append(str(role))
		if completed.size() < participants.size():
			return
		_social_groups.erase(group_id)
		if not participants.is_empty():
			actor_role = participants[0]
	else:
		participants.append(actor_role)
		var observer := "nai" if actor_role == "ling" else "ling"
		if observer not in participants:
			participants.append(observer)
	var needs_by_role := {}
	for role in participants:
		needs_by_role[role] = get_needs(role)
	var visual_summary := ""
	var visual = get_visual_context(actor_role)
	if not visual.is_empty() and int(Time.get_unix_time_from_system()) - int(visual.get("observed_at_unix", 0)) <= 600:
		visual_summary = str(visual.get("description", "")).left(1200)
	var event_id := group_id if not group_id.is_empty() else "event-%s-%d" % [actor_role, Time.get_ticks_msec()]
	social_event_ready.emit({
		"protocol": "spring_haven.life_lab.social_event.v1",
		"event_id": event_id,
		"action": action,
		"action_label": str(ACTION_LABELS.get(action, action)),
		"station_id": str(task.get("station_id", "")),
		"actor_role_id": actor_role,
		"participant_role_ids": participants,
		"initiated_by": str(task.get("initiated_by", "autonomous")),
		"needs_by_role": needs_by_role,
		"visual_summary": visual_summary,
		"occurred_at_unix": int(Time.get_unix_time_from_system()),
	})


func _set_task(role: String, task: Dictionary) -> void:
	_tasks[role] = task.duplicate(true)
	task_changed.emit(role, task.duplicate(true))


func _fail_task(role: String, message: String) -> Dictionary:
	var task := get_task(role)
	task["status"] = "failed"
	task["failure_reason"] = message.left(120)
	_set_task(role, task)
	return {"ok": false, "message": message, "task_id": str(task.get("id", ""))}


func _emit_command_result(result: Dictionary) -> Dictionary:
	command_result.emit(result.duplicate(true))
	return result


func _role_names(roles: Array[String]) -> String:
	var names: Array[String] = []
	for role in roles:
		names.append("小玲" if role == "ling" else "小奈")
	return "、".join(names)


func _agent(role: String) -> Node3D:
	var path := ling_path if role == "ling" else nai_path
	return get_node_or_null(path) as Node3D if not path.is_empty() else null


func _player() -> Node3D:
	return get_node_or_null(player_path) as Node3D if not player_path.is_empty() else null


func _station(station_id: String) -> Marker3D:
	var room := get_node_or_null(room_path)
	if is_instance_valid(room) and room.has_method("get_station"):
		return room.call("get_station", station_id) as Marker3D
	return null


func _station_target(station_id: String, role: String) -> Vector3:
	var room := get_node_or_null(room_path)
	if is_instance_valid(room) and room.has_method("get_station_target"):
		var target_variant = room.call("get_station_target", station_id, role)
		if target_variant is Vector3:
			return target_variant
	var station := _station(station_id)
	return station.global_position if is_instance_valid(station) else Vector3.INF
