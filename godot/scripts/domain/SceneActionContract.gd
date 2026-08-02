class_name SceneActionContract
extends RefCounted

## 无视觉场景动作的纯领域契约。
##
## LLM 只能选择语义动作和预先登记的目标 ID。世界坐标、速度、节点路径、
## 导航和物理移动全部留在 Godot 内部处理。

const PROTOCOL := "spring_heaven.scene_actions.v1"
const SCHEMA_VERSION := 1
const SCENE_ID := "living_dining_room"
const ACTOR_ROLE_ID := "ling"

const MAX_STRING_LENGTH := 64
const MAX_REVISION := 2_147_483_647
const MAX_DISTANCE_M := 1000.0
const UNKNOWN_DISTANCE_M := -1.0
const MAX_ENTITY_INPUTS := 16

const ENTITY_WHITELIST := ["dining_table", "sofa", "player"]
const MOVE_TARGET_IDS := ["dining_table", "sofa"]
const SEMANTIC_POSITIONS := [
	"room",
	"near_dining_table",
	"near_sofa",
	"near_player",
	"unknown",
]
const ACTOR_MODES := ["idle", "move_to", "follow_player"]
const ACTOR_STATUSES := [
	"idle",
	"navigating",
	"following",
	"stopped",
	"arrived",
	"path_pending",
	"waiting_for_follow_target",
	"replanning",
	"blocked",
	"edge_blocked",
	"recovering",
	"failed",
	"unknown",
]
const PLAYER_STATUSES := ["idle", "moving", "interacting", "unknown"]


## 构建可安全发送给无视觉模型的场景上下文。
## entities 只读取 id、distance_m、reachable；标签和动作权限来自本契约。
static func build_scene_context(
	scene_id: String,
	revision: Variant,
	actor_state: Variant = {},
	player_state: Variant = {},
	entities: Variant = []
) -> Dictionary:
	if scene_id != SCENE_ID:
		return {}
	var normalized_revision := _read_non_negative_int(revision)
	if normalized_revision < 0:
		return {}
	var raw_actor: Dictionary = actor_state if actor_state is Dictionary else {}
	var raw_role_id = raw_actor.get("actor_role_id", ACTOR_ROLE_ID)
	if not _is_bounded_string(raw_role_id) or str(raw_role_id) != ACTOR_ROLE_ID:
		return {}
	return _make_context(
		normalized_revision,
		raw_actor,
		player_state,
		entities
	)


## 将外部或持久化的上下文收紧到当前协议。核心标记不匹配时返回空字典；
## 实体、动作权限以及所有语义字段都会重新按白名单构建。
static func normalize_scene_context(raw_value: Variant) -> Dictionary:
	if not raw_value is Dictionary:
		return {}
	var raw: Dictionary = raw_value
	if not _is_exact_string(raw.get("protocol", null), PROTOCOL):
		return {}
	if _read_exact_schema_version(raw.get("schema_version", null)) != SCHEMA_VERSION:
		return {}
	if not _is_exact_string(raw.get("scene_id", null), SCENE_ID):
		return {}
	var revision := _read_non_negative_int(raw.get("revision", null))
	if revision < 0:
		return {}
	var vision_value = raw.get("vision_available", null)
	if not vision_value is bool or bool(vision_value):
		return {}
	if not _is_exact_string(raw.get("actor_role_id", null), ACTOR_ROLE_ID):
		return {}
	return _make_context(
		revision,
		raw.get("actor_state", {}),
		raw.get("player_state", {}),
		raw.get("entities", [])
	)


## 严格校验一个高层动作。成功时返回规范动作的新字典。
static func validate_action(
	raw_action: Variant,
	scene_context: Variant
) -> Dictionary:
	if normalize_scene_context(scene_context).is_empty():
		return _action_result(false, "场景上下文无效")
	if not raw_action is Dictionary:
		return _action_result(false, "场景动作必须是字典")
	var raw: Dictionary = raw_action
	if _read_exact_schema_version(raw.get("schema_version", null)) != SCHEMA_VERSION:
		return _action_result(false, "动作 schema_version 必须为 1")
	var action_value = raw.get("action", null)
	if not _is_bounded_string(action_value):
		return _action_result(false, "动作名称必须是长度不超过 64 的字符串")
	var action := str(action_value)
	match action:
		"move_to":
			if not _has_exact_keys(raw, ["schema_version", "action", "target_id"]):
				return _action_result(false, "move_to 包含缺失或未知字段")
			var target_value = raw.get("target_id", null)
			if not _is_bounded_string(target_value):
				return _action_result(false, "target_id 必须是长度不超过 64 的字符串")
			var target_id := str(target_value)
			if target_id not in MOVE_TARGET_IDS:
				return _action_result(false, "move_to 目标不在实体白名单中")
			return _action_result(
				true,
				"",
				{
					"schema_version": SCHEMA_VERSION,
					"action": "move_to",
					"target_id": target_id,
				}
			)
		"follow_player", "stop":
			if not _has_exact_keys(raw, ["schema_version", "action"]):
				return _action_result(false, "%s 包含缺失或未知字段" % action)
			return _action_result(
				true,
				"",
				{"schema_version": SCHEMA_VERSION, "action": action}
			)
		_:
			return _action_result(false, "动作不在白名单中")


## 严格校验模型返回的动作数组。首版每轮最多接受一个动作。
static func validate_actions(
	raw_actions: Variant,
	scene_context: Variant
) -> Dictionary:
	if normalize_scene_context(scene_context).is_empty():
		return _actions_result(false, "场景上下文无效")
	if not raw_actions is Array:
		return _actions_result(false, "scene_actions 必须是数组")
	var raw_array: Array = raw_actions
	if raw_array.size() > 1:
		return _actions_result(false, "每轮最多允许一个场景动作")
	if raw_array.is_empty():
		return _actions_result(true, "", [])
	var validation := validate_action(raw_array[0], scene_context)
	if not bool(validation.get("ok", false)):
		return _actions_result(false, str(validation.get("message", "场景动作无效")))
	var normalized_action = validation.get("action", {})
	if not normalized_action is Dictionary:
		return _actions_result(false, "规范动作无效")
	return _actions_result(true, "", [(normalized_action as Dictionary).duplicate(true)])


static func _make_context(
	revision: int,
	actor_state: Variant,
	player_state: Variant,
	entities: Variant
) -> Dictionary:
	return {
		"protocol": PROTOCOL,
		"schema_version": SCHEMA_VERSION,
		"scene_id": SCENE_ID,
		"revision": revision,
		"vision_available": false,
		"actor_role_id": ACTOR_ROLE_ID,
		"actor_state": _normalize_actor_state(actor_state),
		"player_state": _normalize_player_state(player_state),
		"entity_whitelist": ENTITY_WHITELIST.duplicate(),
		"entities": _normalize_entities(entities),
		"available_actions": _available_actions(),
	}


static func _normalize_actor_state(raw_value: Variant) -> Dictionary:
	var raw: Dictionary = raw_value if raw_value is Dictionary else {}
	var raw_mode = raw.get("mode", "idle")
	var mode := (
		"follow_player"
		if _is_exact_string(raw_mode, "follow")
		else _enum_string(raw_mode, ACTOR_MODES, "idle")
	)
	var status := _normalize_actor_status(raw.get("status", "idle"))
	var target_id := _enum_string(
		raw.get("target_id", ""),
		["", "dining_table", "sofa", "player"],
		""
	)
	var semantic_position := _enum_string(
		raw.get("semantic_position", "unknown"),
		SEMANTIC_POSITIONS,
		"unknown"
	)
	var can_move := true
	if raw.has("can_move"):
		can_move = bool(raw["can_move"]) if raw["can_move"] is bool else false
	return {
		"mode": mode,
		"status": status,
		"target_id": target_id,
		"semantic_position": semantic_position,
		"can_move": can_move,
	}


static func _normalize_player_state(raw_value: Variant) -> Dictionary:
	var raw: Dictionary = raw_value if raw_value is Dictionary else {}
	var is_present := true
	if raw.has("is_present"):
		is_present = bool(raw["is_present"]) if raw["is_present"] is bool else false
	return {
		"status": _enum_string(
			raw.get("status", "unknown"),
			PLAYER_STATUSES,
			"unknown"
		),
		"semantic_position": _enum_string(
			raw.get("semantic_position", "unknown"),
			SEMANTIC_POSITIONS,
			"unknown"
		),
		"is_present": is_present,
	}


static func _normalize_actor_status(raw_value: Variant) -> String:
	if not _is_bounded_string(raw_value):
		return "unknown"
	var status := str(raw_value)
	if status.begins_with("recovering_"):
		return "recovering"
	if status.begins_with("failed_"):
		return "failed"
	return status if status in ACTOR_STATUSES else "unknown"


static func _normalize_entities(raw_value: Variant) -> Array[Dictionary]:
	var entries_by_id := {}
	if raw_value is Array:
		var raw_array: Array = raw_value
		var input_count := mini(raw_array.size(), MAX_ENTITY_INPUTS)
		for index in input_count:
			var entry_value = raw_array[index]
			if not entry_value is Dictionary:
				continue
			var entry: Dictionary = entry_value
			var id_value = entry.get("id", null)
			if not _is_bounded_string(id_value):
				continue
			var entity_id := str(id_value)
			if entity_id not in ENTITY_WHITELIST or entries_by_id.has(entity_id):
				continue
			entries_by_id[entity_id] = entry

	var normalized: Array[Dictionary] = []
	for entity_id in ENTITY_WHITELIST:
		var raw_entry_value = entries_by_id.get(entity_id, {})
		var raw_entry: Dictionary = (
			raw_entry_value if raw_entry_value is Dictionary else {}
		)
		var reachable := true
		if raw_entry.has("reachable"):
			reachable = (
				bool(raw_entry["reachable"])
				if raw_entry["reachable"] is bool
				else false
			)
		normalized.append({
			"id": entity_id,
			"label": _entity_label(entity_id),
			"kind": "player" if entity_id == "player" else "interaction_target",
			"distance_m": _normalize_distance(raw_entry.get("distance_m", null)),
			"reachable": reachable,
			"allowed_actions": (
				["follow_player"] if entity_id == "player" else ["move_to"]
			),
		})
	return normalized


static func _available_actions() -> Array[Dictionary]:
	return [
		{
			"action": "move_to",
			"allowed_target_ids": MOVE_TARGET_IDS.duplicate(),
		},
		{
			"action": "follow_player",
			"allowed_target_ids": ["player"],
		},
		{
			"action": "stop",
			"allowed_target_ids": [],
		},
	]


static func _entity_label(entity_id: String) -> String:
	match entity_id:
		"dining_table":
			return "餐桌"
		"sofa":
			return "沙发"
		_:
			return "玩家"


static func _normalize_distance(raw_value: Variant) -> float:
	if raw_value is bool or not (raw_value is int or raw_value is float):
		return UNKNOWN_DISTANCE_M
	var numeric := float(raw_value)
	if not is_finite(numeric) or numeric < 0.0 or numeric > MAX_DISTANCE_M:
		return UNKNOWN_DISTANCE_M
	return snappedf(numeric, 0.01)


static func _read_exact_schema_version(raw_value: Variant) -> int:
	# Godot JSON 会把线上的整数 1 解码为 float 1.0；只接受有限且数值精确等于 1 的表示。
	# Bridge 在解析模型原始 JSON 时仍要求 Python int，因此这里不会放宽上游协议。
	if raw_value is bool or not (raw_value is int or raw_value is float):
		return -1
	var numeric := float(raw_value)
	if not is_finite(numeric) or numeric != float(SCHEMA_VERSION):
		return -1
	return SCHEMA_VERSION


static func _read_non_negative_int(raw_value: Variant) -> int:
	if raw_value is bool or not (raw_value is int or raw_value is float):
		return -1
	var numeric := float(raw_value)
	if not is_finite(numeric) or numeric < 0.0 or numeric > float(MAX_REVISION):
		return -1
	var parsed := int(numeric)
	if numeric != float(parsed):
		return -1
	return parsed


static func _enum_string(
	raw_value: Variant,
	allowed_values: Array,
	fallback: String
) -> String:
	if not _is_bounded_string(raw_value):
		return fallback
	var value := str(raw_value)
	return value if value in allowed_values else fallback


static func _is_bounded_string(raw_value: Variant) -> bool:
	return (
		raw_value is String
		and not (raw_value as String).is_empty()
		and (raw_value as String).length() <= MAX_STRING_LENGTH
	)


static func _is_exact_string(raw_value: Variant, expected: String) -> bool:
	return _is_bounded_string(raw_value) and str(raw_value) == expected


static func _has_exact_keys(raw: Dictionary, allowed_keys: Array[String]) -> bool:
	if raw.size() != allowed_keys.size():
		return false
	for key_value in raw:
		if not key_value is String or str(key_value) not in allowed_keys:
			return false
	return true


static func _action_result(
	ok: bool,
	message: String,
	action: Dictionary = {}
) -> Dictionary:
	return {
		"ok": ok,
		"message": message,
		"action": action.duplicate(true) if ok else {},
	}


static func _actions_result(
	ok: bool,
	message: String,
	actions: Array = []
) -> Dictionary:
	return {
		"ok": ok,
		"message": message,
		"actions": actions.duplicate(true) if ok else [],
	}
