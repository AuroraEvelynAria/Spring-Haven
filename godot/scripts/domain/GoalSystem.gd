class_name GoalSystem
extends RefCounted

"""人生目标系统：每个角色有长期梦想，相关生活活动推进进度。

状态持久化在 life_runtime.goals：{ "ling": {"id": "...", "progress": 0-100}, "nai": {...} }
达成 100% 时返回 celebration 事件。
"""

const GOALS := {
	"ling": {
		"id": "biology_studies",
		"title": "生命科学学业",
		"progress_actions": ["read_by_window", "morning_window_watch", "home_check"],
		"step": 2.0,
	},
	"nai": {
		"id": "dance_debut",
		"title": "站上舞蹈舞台",
		"progress_actions": ["dance_practice", "dance_release", "morning_stretch"],
		"step": 2.5,
	},
}

const CELEBRATION_EVENT := "goal_celebration"


static func normalize_runtime(raw_value: Variant) -> Dictionary:
	var raw: Dictionary = raw_value if raw_value is Dictionary else {}
	var result: Dictionary = {}
	for role in ["ling", "nai"]:
		var entry: Dictionary = (
			raw.get(role, {}) if raw.get(role, {}) is Dictionary else {}
		)
		result[role] = {
			"id": str(entry.get("id", "")),
			"progress": float(clampf(float(entry.get("progress", 0.0)), 0.0, 100.0)),
			"celebrated": bool(entry.get("celebrated", false)),
		}
	return result


static func goal_title(role: String) -> String:
	var goal = GOALS.get(role, {})
	return str(goal.get("title", "")) if goal is Dictionary else ""


static func is_progress_action(role: String, action: String) -> bool:
	var goal = GOALS.get(role, {})
	if not goal is Dictionary:
		return false
	var actions = goal.get("progress_actions", [])
	return action in actions if actions is Array else false


static func advance(goals: Dictionary, role: String, action: String) -> Dictionary:
	"""推进目标进度；返回 {goals, reached: bool}"""
	var normalized := normalize_runtime(goals)
	if not is_progress_action(role, action):
		return {"goals": normalized, "reached": false}
	var entry: Dictionary = normalized[role]
	if bool(entry.get("celebrated", false)):
		return {"goals": normalized, "reached": false}
	var goal = GOALS.get(role, {})
	var step := float(goal.get("step", 1.0)) if goal is Dictionary else 1.0
	var progress := float(entry.get("progress", 0.0)) + step
	var reached := progress >= 100.0
	entry["progress"] = clampf(progress, 0.0, 100.0)
	entry["celebrated"] = reached
	normalized[role] = entry
	return {"goals": normalized, "reached": reached}


static func progress_label(goals: Dictionary, role: String) -> String:
	var normalized := normalize_runtime(goals)
	var entry: Dictionary = normalized.get(role, {})
	var progress := float(entry.get("progress", 0.0))
	var title := goal_title(role)
	if title.is_empty():
		return ""
	if progress >= 100.0:
		return "%s已经实现了！" % title
	if progress >= 60.0:
		return "%s最近很有进展（%d%%）" % [title, int(progress)]
	return ""
