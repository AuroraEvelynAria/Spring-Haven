class_name ExplorationAIController
extends Node

## 将无视觉能力的角色 LLM 与 3D 场景的安全语义动作连接起来。
##
## 模型只能看到房间区域、距离和白名单实体，不能看到截图、世界坐标或 NodePath；
## 模型返回的动作还必须经过 SceneActionContract，最终坐标只从本地锚点取得。

signal status_changed(status: String, message: String)
signal reply_ready(text: String)
signal action_applied(action: Dictionary)

const SceneActionContract = preload("res://scripts/domain/SceneActionContract.gd")
const TEXT_SANITIZER := preload("res://scripts/domain/TextSanitizer.gd")

const ROLE_ID := "ling"
const SCENE_ID := "living_dining_room"
const HISTORY_ENTRY_LIMIT := 12
const HISTORY_CHARACTER_LIMIT := 6000
const HISTORY_TEXT_LIMIT := 1200
const MESSAGE_CHARACTER_LIMIT := 3000
const NEAR_ANCHOR_DISTANCE_METERS := 1.6
const NAVIGATION_TARGET_TOLERANCE_METERS := 0.8
const NAVIGATION_PATH_END_TOLERANCE_METERS := 0.25

@export var player_path: NodePath
@export var ling_path: NodePath
@export var dining_anchor_path: NodePath
@export var sofa_anchor_path: NodePath

var _pending_request_id := ""
var _pending_scene_context: Dictionary = {}
var _foreground_scope_token := ""
var _scene_revision := 0
var _core_client_override: Node
var _global_state_override: Node
var _global_state_override_configured := false


func _ready() -> void:
	_connect_core_signals()
	_set_status("idle", "小玲的场景对话控制器已就绪")


func _exit_tree() -> void:
	_disconnect_core_signals()
	var core_client := _get_core_client()
	if (
		not _pending_request_id.is_empty()
		and is_instance_valid(core_client)
		and core_client.has_method("discard_request")
	):
		core_client.call("discard_request", _pending_request_id)
	_clear_pending_request()


## 生成供文本模型理解的场景快照。返回值有意不包含截图、坐标、朝向或节点路径。
func build_scene_state() -> Dictionary:
	_scene_revision += 1
	var player := _get_player()
	var ling := _get_ling()
	var dining_anchor := _get_dining_anchor()
	var sofa_anchor := _get_sofa_anchor()

	var ling_to_player := _semantic_distance(ling, player)
	var ling_motion := _ling_movement_state(ling)
	var actor_state := {
		"actor_role_id": ROLE_ID,
		"mode": str(ling_motion.get("mode", "idle")),
		"status": str(ling_motion.get("status", "unknown")),
		"target_id": str(ling_motion.get("target_id", "")),
		"semantic_position": _semantic_position(ling, dining_anchor, sofa_anchor, player),
		"can_move": is_instance_valid(ling) and ling.has_method("command_move_to"),
	}
	var player_state := {
		"status": _player_movement_status(player),
		"semantic_position": _semantic_position(player, dining_anchor, sofa_anchor),
		"is_present": is_instance_valid(player),
	}
	var entities: Array[Dictionary] = []
	if is_instance_valid(dining_anchor):
		entities.append({
			"id": "dining_table",
			"distance_m": _semantic_distance(ling, dining_anchor),
			"reachable": _is_reachable(ling, dining_anchor),
		})
	if is_instance_valid(sofa_anchor):
		entities.append({
			"id": "sofa",
			"distance_m": _semantic_distance(ling, sofa_anchor),
			"reachable": _is_reachable(ling, sofa_anchor),
		})
	if is_instance_valid(player):
		entities.append({
			"id": "player",
			"distance_m": ling_to_player,
			"reachable": _is_reachable(ling, player),
		})

	var context: Dictionary = SceneActionContract.build_scene_context(
		SCENE_ID,
		_scene_revision,
		actor_state,
		player_state,
		entities
	)
	# DeepSeek-V4-Flash 没有视觉能力。这个声明属于协议，不允许调用方覆盖。
	context["vision_available"] = false
	return context.duplicate(true)


## 读取角色眼部的窄视野语义射线。结果只包含物体语义和相对距离，绝不包含坐标。
func build_perception_state() -> Dictionary:
	var ling := _get_ling()
	if not is_instance_valid(ling):
		return {}
	var perception_ray := ling.get_node_or_null("VisualPivot/PerceptionRay3D")
	if not is_instance_valid(perception_ray) or not perception_ray.has_method("scan"):
		return {}
	var snapshot_variant = perception_ray.call("scan")
	if not snapshot_variant is Dictionary:
		return {}
	var snapshot: Dictionary = snapshot_variant
	if (
		str(snapshot.get("protocol", "")) != "spring_heaven.perception.v1"
		or str(snapshot.get("role_id", "")) != ROLE_ID
	):
		return {}
	return snapshot.duplicate(true)


## 发送玩家在探索场景中的文本。任一时刻只允许一个未完成请求。
func send_player_message(text: String) -> String:
	var normalized_text := _clean_text(text, MESSAGE_CHARACTER_LIMIT)
	if normalized_text.is_empty():
		_set_status("rejected", "消息不能为空")
		return ""
	if not _pending_request_id.is_empty():
		_set_status("busy", "正在等待小玲回复，请稍候")
		return ""
	var core_client := _get_core_client()
	if not is_instance_valid(core_client) or not core_client.has_method("send_chat"):
		_set_status("unavailable", "Companion Core 客户端不可用")
		return ""

	var scene_context := build_scene_state()
	var perception_state := build_perception_state()
	var body_state: Dictionary = {}
	var life_sim := get_node_or_null("/root/LifeSim")
	if is_instance_valid(life_sim) and life_sim.has_method("build_role_state"):
		var body_state_variant = life_sim.call("build_role_state", ROLE_ID)
		if body_state_variant is Dictionary:
			body_state = body_state_variant
	var history := _build_recent_history()
	var conversation_id := ""
	var global_state := _get_global_state()
	if is_instance_valid(global_state) and bool(global_state.get("state_loaded")):
		conversation_id = str(global_state.get("save_id")).strip_edges()
	var request_state := {"scene_context": scene_context.duplicate(true)}
	if not body_state.is_empty():
		request_state["body_state"] = body_state
	if not perception_state.is_empty():
		request_state["perception_state"] = perception_state
	var scheduler := _get_message_scheduler()
	if is_instance_valid(scheduler) and scheduler.has_method("begin_foreground"):
		_foreground_scope_token = str(scheduler.call(
			"begin_foreground",
			"exploration",
			"scene-%d" % _scene_revision
		))
	var request_id: String = str(core_client.call(
		"send_chat",
		ROLE_ID,
		normalized_text,
		history,
		conversation_id,
		"chat",
		request_state
	))
	if request_id.is_empty():
		_release_foreground_scope()
		_set_status("failed", "Companion Core 未创建请求")
		return ""

	_pending_request_id = request_id
	_pending_scene_context = scene_context.duplicate(true)
	_set_status("waiting_reply", "正在等待小玲回复")
	return request_id


func has_pending_request() -> bool:
	return not _pending_request_id.is_empty()


func set_core_client(client: Node) -> void:
	var was_ready := is_node_ready()
	if was_ready:
		_disconnect_core_signals()
	_core_client_override = client
	if was_ready:
		_connect_core_signals()


func set_global_state_node(global_state: Node) -> void:
	_global_state_override_configured = true
	_global_state_override = global_state


func get_pending_request_id() -> String:
	return _pending_request_id


func _connect_core_signals() -> void:
	var core_client := _get_core_client()
	if not is_instance_valid(core_client):
		return
	var reply_callable := Callable(self, "_on_core_reply_received")
	if core_client.has_signal("reply_received") and not core_client.is_connected("reply_received", reply_callable):
		core_client.connect("reply_received", reply_callable)
	var failure_callable := Callable(self, "_on_core_request_failed")
	if core_client.has_signal("request_failed") and not core_client.is_connected("request_failed", failure_callable):
		core_client.connect("request_failed", failure_callable)
	# 场景动作信号是可选能力；缺失时仍可完成文本回复。
	var actions_callable := Callable(self, "_on_scene_actions_received")
	if core_client.has_signal("scene_actions_received") and not core_client.is_connected(
		"scene_actions_received", actions_callable
	):
		core_client.connect("scene_actions_received", actions_callable)


func _disconnect_core_signals() -> void:
	var core_client := _get_core_client()
	if not is_instance_valid(core_client):
		return
	var connections := {
		"reply_received": Callable(self, "_on_core_reply_received"),
		"request_failed": Callable(self, "_on_core_request_failed"),
		"scene_actions_received": Callable(self, "_on_scene_actions_received"),
	}
	for signal_name_variant in connections:
		var signal_name := str(signal_name_variant)
		var callback: Callable = connections[signal_name_variant]
		if core_client.has_signal(signal_name) and core_client.is_connected(signal_name, callback):
			core_client.disconnect(signal_name, callback)


func _on_core_reply_received(request_id: String, text: String, _attachments: Array) -> void:
	if request_id != _pending_request_id:
		return
	var reply_text := _clean_text(text, MESSAGE_CHARACTER_LIMIT)
	_clear_pending_request()
	if reply_text.is_empty():
		_set_status("failed", "小玲返回了空回复")
		return
	_set_status("reply_ready", "已收到小玲回复")
	reply_ready.emit(reply_text)


func _on_core_request_failed(request_id: String, message: String, _retryable: bool) -> void:
	if request_id != _pending_request_id:
		return
	_clear_pending_request()
	var failure_message := _clean_text(message, 500)
	if failure_message.is_empty():
		failure_message = "Companion Core 请求失败"
	_set_status("failed", failure_message)


func _on_scene_actions_received(request_id: String, raw_actions: Array) -> void:
	if request_id != _pending_request_id:
		return
	var validation: Dictionary = SceneActionContract.validate_actions(
		raw_actions,
		_pending_scene_context
	)
	if not bool(validation.get("ok", false)):
		_set_status("action_rejected", str(validation.get("message", "场景动作无效")))
		return
	var actions_variant = validation.get("actions", [])
	if not actions_variant is Array:
		_set_status("action_rejected", "场景动作校验结果无效")
		return
	for action_variant in actions_variant:
		if action_variant is Dictionary:
			_apply_validated_action(action_variant)


func _apply_validated_action(action: Dictionary) -> void:
	var ling := _get_ling()
	if not is_instance_valid(ling):
		_set_status("action_failed", "找不到小玲的场景角色")
		return

	var action_name := str(action.get("action", ""))
	match action_name:
		"move_to":
			var target_id := str(action.get("target_id", ""))
			var anchor: Node3D
			var label := ""
			match target_id:
				"dining_table":
					anchor = _get_dining_anchor()
					label = "餐桌"
				"sofa":
					anchor = _get_sofa_anchor()
					label = "沙发"
				_:
					_set_status("action_rejected", "动作目标不在本地白名单中")
					return
			if not is_instance_valid(anchor) or not ling.has_method("command_move_to"):
				_set_status("action_failed", "%s当前不可用" % label)
				return
			if not _is_reachable(ling, anchor):
				_set_status("action_failed", "%s当前不可达" % label)
				return
			# 唯一允许进入移动器的坐标来自本地导出的锚点，绝不读取模型返回的坐标。
			ling.call("command_move_to", anchor.global_position, label)
		"follow_player":
			var player := _get_player()
			if not is_instance_valid(player) or not ling.has_method("command_follow"):
				_set_status("action_failed", "当前无法跟随玩家")
				return
			if not _is_reachable(ling, player):
				_set_status("action_failed", "玩家当前不可达")
				return
			ling.call("command_follow", player)
		"stop":
			if not ling.has_method("command_stop"):
				_set_status("action_failed", "小玲的停止接口不可用")
				return
			ling.call("command_stop")
		_:
			_set_status("action_rejected", "动作不在执行白名单中")
			return

	var safe_action := {
		"schema_version": int(action.get("schema_version", 1)),
		"action": action_name,
	}
	if action_name == "move_to":
		safe_action["target_id"] = str(action.get("target_id", ""))
	_set_status("action_applied", "小玲已接受场景动作：%s" % action_name)
	action_applied.emit(safe_action)


func _build_recent_history() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var used_characters := 0
	var global_state := _get_global_state()
	if not is_instance_valid(global_state):
		return result
	var history_value = global_state.get("conversation_history")
	if not history_value is Array:
		return result
	var history: Array = history_value
	for index in range(history.size() - 1, -1, -1):
		var raw_entry = history[index]
		if not raw_entry is Dictionary:
			continue
		var entry: Dictionary = raw_entry
		if str(entry.get("status", "sent")) != "sent":
			continue
		var sender := str(entry.get("sender", ""))
		if sender not in ["user", "ai"]:
			continue
		var history_text := _clean_text(str(entry.get("text", "")), HISTORY_TEXT_LIMIT)
		if history_text.is_empty():
			continue
		var role_id := str(entry.get("role", ""))
		var speaker := "主人"
		if sender == "ai":
			if role_id not in ["ling", "nai"]:
				continue
			speaker = "小玲" if role_id == "ling" else "小奈"
		var history_entry := {
			"sender": sender,
			"speaker": speaker,
			"text": history_text,
			"event_type": "action" if str(entry.get("event_type", "chat")) == "action" else "chat",
		}
		if sender == "ai":
			history_entry["role_id"] = role_id
		else:
			history_entry["role"] = "user"
		var serialized_size := JSON.stringify(history_entry).length()
		if result.size() >= HISTORY_ENTRY_LIMIT or used_characters + serialized_size > HISTORY_CHARACTER_LIMIT:
			break
		result.push_front(history_entry)
		used_characters += serialized_size
	return result


func _semantic_position(
	node: Node3D,
	dining_anchor: Node3D,
	sofa_anchor: Node3D,
	other_character: Node3D = null
) -> String:
	if not is_instance_valid(node):
		return "unknown"
	if is_instance_valid(other_character):
		if _planar_distance(node.global_position, other_character.global_position) <= NEAR_ANCHOR_DISTANCE_METERS:
			return "near_player"
	if is_instance_valid(dining_anchor):
		if _planar_distance(node.global_position, dining_anchor.global_position) <= NEAR_ANCHOR_DISTANCE_METERS:
			return "near_dining_table"
	if is_instance_valid(sofa_anchor):
		if _planar_distance(node.global_position, sofa_anchor.global_position) <= NEAR_ANCHOR_DISTANCE_METERS:
			return "near_sofa"
	return "room"


func _ling_movement_state(ling: Node3D) -> Dictionary:
	if not is_instance_valid(ling) or not ling.has_method("get_action_state"):
		return {"mode": "idle", "status": "unknown", "target_id": ""}
	var raw_state = ling.call("get_action_state")
	if not raw_state is Dictionary:
		return {"mode": "idle", "status": "unknown", "target_id": ""}
	var mode := str(raw_state.get("mode", "idle"))
	if mode not in ["idle", "move_to", "follow", "follow_player"]:
		mode = "idle"
	var label := str(raw_state.get("label", "")).strip_edges()
	var target_id := ""
	if label in ["餐桌", "dining_table"]:
		target_id = "dining_table"
	elif label in ["沙发", "sofa"]:
		target_id = "sofa"
	elif mode in ["follow", "follow_player"]:
		target_id = "player"
	return {
		"mode": mode,
		"status": str(raw_state.get("status", "unknown")).left(64),
		"target_id": target_id,
	}


func _player_movement_status(player: Node3D) -> String:
	if not is_instance_valid(player):
		return "unknown"
	if player is CharacterBody3D:
		var horizontal_velocity := (player as CharacterBody3D).velocity
		horizontal_velocity.y = 0.0
		if horizontal_velocity.length_squared() > 0.01:
			return "moving"
	return "idle"


func _semantic_distance(from: Node3D, to: Node3D) -> float:
	if not is_instance_valid(from) or not is_instance_valid(to):
		return -1.0
	return snappedf(_planar_distance(from.global_position, to.global_position), 0.1)


func _is_reachable(ling: Node3D, target: Node3D) -> bool:
	if not is_instance_valid(ling) or not is_instance_valid(target):
		return false
	var navigation_agent := ling.get_node_or_null("NavigationAgent3D") as NavigationAgent3D
	if navigation_agent == null:
		return false
	var navigation_map := navigation_agent.get_navigation_map()
	if not navigation_map.is_valid():
		return false
	var closest_target := NavigationServer3D.map_get_closest_point(
		navigation_map,
		target.global_position
	)
	if _planar_distance(closest_target, target.global_position) > NAVIGATION_TARGET_TOLERANCE_METERS:
		return false
	var path := NavigationServer3D.map_get_path(
		navigation_map,
		ling.global_position,
		closest_target,
		true
	)
	if path.is_empty():
		return false
	return _planar_distance(path[path.size() - 1], closest_target) <= NAVIGATION_PATH_END_TOLERANCE_METERS


func _planar_distance(from: Vector3, to: Vector3) -> float:
	var offset := to - from
	offset.y = 0.0
	return offset.length()


func _get_player() -> Node3D:
	return _get_exported_node(player_path)


func _get_ling() -> Node3D:
	return _get_exported_node(ling_path)


func _get_dining_anchor() -> Node3D:
	return _get_exported_node(dining_anchor_path)


func _get_sofa_anchor() -> Node3D:
	return _get_exported_node(sofa_anchor_path)


func _get_exported_node(path: NodePath) -> Node3D:
	if path.is_empty():
		return null
	return get_node_or_null(path) as Node3D


func _get_core_client() -> Node:
	if is_instance_valid(_core_client_override):
		return _core_client_override
	var tree := get_tree()
	return tree.root.get_node_or_null("CompanionCore") if tree else null


func _get_global_state() -> Node:
	if _global_state_override_configured:
		return _global_state_override
	var tree := get_tree()
	return tree.root.get_node_or_null("Global") if tree else null


func _clear_pending_request() -> void:
	_pending_request_id = ""
	_pending_scene_context.clear()
	_release_foreground_scope()


func _release_foreground_scope() -> void:
	if _foreground_scope_token.is_empty():
		return
	var scheduler := _get_message_scheduler()
	if is_instance_valid(scheduler) and scheduler.has_method("end_foreground"):
		scheduler.call("end_foreground", _foreground_scope_token)
	_foreground_scope_token = ""


func _get_message_scheduler() -> Node:
	var tree := get_tree()
	return tree.root.get_node_or_null("MessageScheduler") if tree else null


func _set_status(status: String, message: String) -> void:
	status_changed.emit(status, message)


func _clean_text(value: String, limit: int) -> String:
	var normalized := TEXT_SANITIZER.strip_nul(value).strip_edges()
	if normalized.length() > limit:
		normalized = normalized.left(limit)
	return normalized
