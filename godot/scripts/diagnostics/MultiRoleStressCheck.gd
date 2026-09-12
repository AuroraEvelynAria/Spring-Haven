extends SceneTree

## 多角色压力验证（#20）：角色属性隔离、对话管线吞吐、存档往返完整性。
## 全程使用独立 Global 实例与临时数据目录，不触碰真实旅程，也不访问 Companion Core。

const GLOBAL_SCRIPT := preload("res://scripts/autoload/Global.gd")
const CHAT_PIPELINE := preload("res://scripts/domain/ChatPipeline.gd")
const INTERACTION_RULES := preload("res://scripts/domain/InteractionRules.gd")

var _failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var stamp := str(Time.get_ticks_usec())
	var test_root := "user://SpringHaven/diagnostics/multi-role-stress-%s" % stamp
	var model := GLOBAL_SCRIPT.new()
	model.set("game_data_path", test_root)
	model.set("_save_root_override", test_root.path_join("saves"))
	root.add_child(model)
	await process_frame

	var role_data: Dictionary = model.ROLES
	var stats_template: Dictionary = model.call("get_role_stats", "ling").duplicate(true)

	# ---- 阶段 A：高频角色切换下的属性隔离 ----
	var baseline: Dictionary = {}
	for role_variant in role_data:
		baseline[str(role_variant)] = model.call("get_role_stats", str(role_variant)).duplicate(true)
	for cycle in 400:
		var role := "ling" if cycle % 2 == 0 else "nai"
		var stats: Dictionary = model.call("get_role_stats", role).duplicate(true)
		var key := "mood" if cycle % 3 == 0 else "intimacy"
		stats[key] = fmod(float(stats.get(key, 0.0)) + 0.5, 100.0)
		if not model.call("persist_role_stats", role, stats):
			_failures.append("阶段A：cycle %d 保存 %s 属性失败" % [cycle, role])
			break
		var other := "nai" if role == "ling" else "ling"
		var other_before: Dictionary = model.call("get_role_stats", other).duplicate(true)
		var other_after: Dictionary = model.call("get_role_stats", other)
		for stat_key in other_before:
			if not is_equal_approx(float(other_before[stat_key]), float(other_after.get(stat_key, 0.0))):
				_failures.append("阶段A：cycle %d 属性串扰，%s.%s 被 %s 的写入污染" % [cycle, other, stat_key, role])
				break
	if _failures.is_empty():
		var ling_final: Dictionary = model.call("get_role_stats", "ling")
		var nai_final: Dictionary = model.call("get_role_stats", "nai")
		if float(ling_final.get("mood", 0.0)) == float((baseline["ling"] as Dictionary).get("mood", 0.0)):
			_failures.append("阶段A：小玲的心情没有随写入变化")
		if is_equal_approx(float(nai_final.get("mood", 0.0)), float(ling_final.get("mood", 0.0))) and float(ling_final.get("mood", 0.0)) != 0.0:
			_failures.append("阶段A：小奈的属性与小玲趋同，疑似共享引用")
	print("MULTI_ROLE_STRESS stage=stats_isolation failures=%d" % _failures.size())

	# ---- 阶段 B：交错双角色对话吞吐（150 条，混合目标与状态） ----
	var entry_ids: Array[String] = []
	var expected_reply_roles := {}
	for index in 150:
		var target_shape := index % 3
		var entry := {
			"id": model.call("new_local_id", "stress"),
			"sender": "user" if index % 2 == 0 else "ai",
			"role": "ling" if index % 4 != 1 else "nai",
			"text": "压力消息 %d：小玲与小奈的交错对话内容。" % index,
			"status": "failed" if index % 17 == 0 else "sent",
			"created_at": 1700000000 + index,
			"event_type": "chat",
		}
		match target_shape:
			0:
				entry["target_roles"] = ["ling"]
				expected_reply_roles[str(entry["id"])] = ["ling"]
			1:
				entry["target_roles"] = ["nai"]
				expected_reply_roles[str(entry["id"])] = ["nai"]
			_:
				entry["target_roles"] = ["ling", "nai"]
				expected_reply_roles[str(entry["id"])] = ["ling", "nai"]
		if index % 23 == 0:
			entry["local_effects_by_role"] = {
				"ling": {"intimacy": 1.5},
				"nai": {"mood": -0.5},
			}
		if not model.call("append_conversation_entry", entry, false):
			_failures.append("阶段B：第 %d 条消息写入失败" % index)
		entry_ids.append(str(entry["id"]))
	var history: Array = model.get("conversation_history")
	var retained := mini(150, int(model.MAX_CONVERSATION_HISTORY))
	if history.size() != retained:
		_failures.append("阶段B：历史条数 %d 不等于保留窗口 %d" % [history.size(), retained])
	var retained_ids := {}
	for item in history:
		retained_ids[str(item.get("id", ""))] = true

	# ---- 阶段 C：ChatPipeline 纯逻辑在压力数据上的裁决 ----
	var first_id := ""
	for id_variant in entry_ids:
		if retained_ids.has(str(id_variant)):
			first_id = str(id_variant)
			break
	if first_id.is_empty():
		_failures.append("阶段C：保留窗口里没有可用的消息 ID")
	var found := CHAT_PIPELINE.find_entry(history, first_id)
	if found.is_empty():
		_failures.append("阶段C：find_entry 没有命中第一条消息")
	if not CHAT_PIPELINE.find_entry(history, "missing-id").is_empty():
		_failures.append("阶段C：find_entry 命中了不存在的 ID")
	var dual_roles: Array[String] = CHAT_PIPELINE.entry_reply_roles(found, role_data, "ling")
	if dual_roles.size() != 2:
		_failures.append("阶段C：双目标消息没有解析出两个回复角色")
	var resolved_role := CHAT_PIPELINE.resolve_request_role(found, role_data, "ling")
	if not role_data.has(resolved_role):
		_failures.append("阶段C：resolve_request_role 返回了未知角色")
	var transcript: Array[Dictionary] = CHAT_PIPELINE.build_shared_history(
		history, role_data, "", 24
	)
	if transcript.is_empty():
		_failures.append("阶段C：共享转写为空")
	if transcript.size() > 24:
		_failures.append("阶段C：共享转写超出 24 条上限")
	for item in transcript:
		if str(item.get("status", "sent")) != "sent":
			_failures.append("阶段C：共享转写混入了未送达消息")
			break
	var transcript_excluded: Array[Dictionary] = CHAT_PIPELINE.build_shared_history(
		history, role_data, first_id, 24
	)
	for item in transcript_excluded:
		if str(item.get("id", "")) == first_id:
			_failures.append("阶段C：排除 ID 后共享转写仍包含该消息")
			break
	var latest_role := CHAT_PIPELINE.latest_ai_speaker_role(history, role_data)
	if latest_role not in ["ling", "nai"]:
		_failures.append("阶段C：最近 AI 说话角色解析失败")
	var dual_id := ""
	for item in history:
		var targets = item.get("target_roles", [])
		if targets is Array and (targets as Array).size() == 2:
			dual_id = str(item.get("id", ""))
			break
	if dual_id.is_empty():
		_failures.append("阶段C：保留窗口里没有双目标消息")
	var dual_entry := CHAT_PIPELINE.find_entry(history, dual_id)
	var state := CHAT_PIPELINE.entry_request_state(
		dual_entry, role_data, "ling", "spring_heaven.conversation_visibility.v1"
	)
	var visibility: Dictionary = state.get("conversation_visibility", {})
	if str(visibility.get("mode", "")) != "shared_room":
		_failures.append("阶段C：请求状态缺少 shared_room 可见性")
	if (visibility.get("audience_roles", []) as Array).size() != 2:
		_failures.append("阶段C：双目标消息的可见性没有覆盖两个受众")
	print("MULTI_ROLE_STRESS stage=pipeline failures=%d" % _failures.size())

	# ---- 阶段 D：压力数据后的存档往返 ----
	if not model.call("save_default_state"):
		_failures.append("阶段D：压力数据保存失败")
	var round_trip: Dictionary = model.call("load_save_slot", str(model.get("save_id")))
	if not bool(round_trip.get("ok", false)):
		_failures.append("阶段D：压力存档无法重新载入")
	var restored_history: Array = model.get("conversation_history")
	if restored_history.size() != mini(history.size(), int(model.MAX_CONVERSATION_HISTORY)):
		_failures.append("阶段D：往返后对话条数不一致（%d -> %d）" % [history.size(), restored_history.size()])
	var restored_ling: Dictionary = model.call("get_role_stats", "ling")
	if not is_equal_approx(
		float(restored_ling.get("mood", 0.0)),
		float(model.call("get_role_stats", "ling").get("mood", 0.0))
	):
		_failures.append("阶段D：往返后小玲属性不一致")
	print("MULTI_ROLE_STRESS stage=roundtrip failures=%d" % _failures.size())

	model.free()
	if _failures.is_empty():
		_cleanup(test_root)
		print("MULTI_ROLE_STRESS_CHECK=PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("MULTI_ROLE_STRESS_CHECK failure=", failure)
	quit(1)


func _cleanup(path: String) -> void:
	var absolute := ProjectSettings.globalize_path(path).simplify_path()
	var diagnostic_root := ProjectSettings.globalize_path("user://SpringHaven/diagnostics").simplify_path()
	if not absolute.begins_with(diagnostic_root.path_join("multi-role-stress-")):
		push_error("拒绝清理非压力测试目录：%s" % absolute)
		return
	DirAccess.remove_absolute(absolute)
