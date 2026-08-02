extends Node

const LIFE_LAB_SCENE := preload("res://scenes/LifeLab/LifeLabWorld.tscn")
const BASE_SAVE_ID := "diagnostic-life-lab-social"
const CONVERSATION_SAVE_ID := "diagnostic-life-lab-social_life_lab"


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	CompanionCore.set_save_id(BASE_SAVE_ID)
	CompanionCore.connect_to_core()
	var connection_deadline := Time.get_ticks_msec() + 15000
	while not CompanionCore.is_active() and Time.get_ticks_msec() < connection_deadline:
		await get_tree().create_timer(0.05).timeout
	if not CompanionCore.is_active():
		_finish(2, "Companion Core 连接超时")
		return
	await CompanionCore.reset_session(CONVERSATION_SAVE_ID)
	var world := LIFE_LAB_SCENE.instantiate()
	for agent_path in ["LingChibi", "NaiChibi"]:
		var agent := world.get_node_or_null(agent_path)
		if is_instance_valid(agent):
			agent.set("load_local_placeholder_model", false)
	add_child(world)
	world.get_task_controller().set_autonomous_enabled(false)
	await get_tree().process_frame
	await world.call("_run_social_dialogue", {
		"protocol": "spring_haven.life_lab.social_event.v1",
		"event_id": "diagnostic-social-dialogue",
		"action": "brew_tea",
		"action_label": "一起泡茶",
		"station_id": "water",
		"actor_role_id": "ling",
		"participant_role_ids": ["ling", "nai"],
		"initiated_by": "diagnostic",
		"needs_by_role": {
			"ling": {"hunger": 40.0, "thirst": 30.0, "stamina": 70.0, "mood": 75.0},
			"nai": {"hunger": 35.0, "thirst": 45.0, "stamina": 80.0, "mood": 82.0},
		},
		"visual_summary": "",
	})
	var history: Array = world.get("_social_history")
	if history.size() < 3:
		await _cleanup(world, 3, "生活事件没有产生两条角色回复")
		return
	var roles: Array[String] = []
	for entry_variant in history:
		if entry_variant is Dictionary and str((entry_variant as Dictionary).get("sender", "")) == "ai":
			roles.append(str((entry_variant as Dictionary).get("role_id", "")))
	if roles != ["ling", "nai"]:
		await _cleanup(world, 4, "生活对话回复顺序错误：%s" % JSON.stringify(roles))
		return
	var feed := world.get("_social_feed") as RichTextLabel
	if not is_instance_valid(feed) or "小玲" not in feed.get_parsed_text() or "小奈" not in feed.get_parsed_text():
		await _cleanup(world, 5, "生活对话没有写入 UI 事件流")
		return
	print("LIFE_LAB_SOCIAL_DIALOGUE_CHECK=PASS order=ling,nai isolated_save=true")
	await _cleanup(world, 0, "")


func _cleanup(world: Node, exit_code: int, message: String) -> void:
	if not message.is_empty():
		printerr("LIFE_LAB_SOCIAL_DIALOGUE_CHECK failure=", message)
	if is_instance_valid(world):
		world.queue_free()
		await get_tree().process_frame
	await CompanionCore.reset_session(CONVERSATION_SAVE_ID)
	CompanionCore.disconnect_from_core()
	_finish(exit_code, "")


func _finish(exit_code: int, message: String) -> void:
	if not message.is_empty():
		printerr("LIFE_LAB_SOCIAL_DIALOGUE_CHECK failure=", message)
	get_tree().quit(exit_code)
