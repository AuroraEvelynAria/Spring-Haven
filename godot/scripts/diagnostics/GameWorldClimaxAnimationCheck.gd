extends Node

const GAME_WORLD_SCENE := preload("res://scenes/GameWorld/GameWorld.tscn")

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	Global.save_id = "diagnostic-climax-animation"
	Global.current_character = "ling"
	Global.stats_by_role = Global.call("_normalize_stats_by_role", {})
	var ling: Dictionary = Global.stats_by_role.ling
	ling["arousal"] = 100.0
	ling["climax"] = 95.0
	Global.stats_by_role["ling"] = ling
	Global.conversation_history = [{
		"id": "seed", "sender": "ai", "role": "ling", "text": "动画测试",
		"status": "sent", "event_type": "chat",
	}]
	Global.applied_local_effect_ids = []
	Global.full_stat_milestones = {}
	Global.life_runtime = Global.call("_normalize_life_runtime", {})
	Global.state_loaded = true
	var world := GAME_WORLD_SCENE.instantiate()
	get_tree().root.add_child(world)
	await get_tree().process_frame
	await get_tree().process_frame
	var widgets: Dictionary = world.get("_stat_widgets")
	if not widgets.has("climax"):
		printerr("GAMEWORLD_CLIMAX_ANIMATION_CHECK failure=高潮行未在兴奋满值后出现")
		await _finish(world, 1)
		return
	world.call("_animate_climax_cycle", "ling", 95.0, 12.0)
	await get_tree().create_timer(0.46).timeout
	var bar := (widgets.climax as Dictionary).get("bar") as ProgressBar
	if not is_instance_valid(bar) or bar.value < 99.0:
		printerr("GAMEWORLD_CLIMAX_ANIMATION_CHECK failure=第一段未达到满值")
		await _finish(world, 2)
		return
	await get_tree().create_timer(0.75).timeout
	if absf(float(bar.value) - 12.0) > 0.6:
		printerr("GAMEWORLD_CLIMAX_ANIMATION_CHECK failure=第二段未回落到重置值 actual=", bar.value)
		await _finish(world, 3)
		return
	print("GAMEWORLD_CLIMAX_ANIMATION_CHECK passed peak=100 reset=12")
	await _finish(world, 0)

func _finish(world: Node, exit_code: int) -> void:
	if is_instance_valid(world):
		world.set("_typewriter_skip_requested", true)
		for tween in get_tree().get_processed_tweens():
			tween.kill()
		await get_tree().process_frame
		world.free()
		for _frame in 6:
			await get_tree().process_frame
	get_tree().quit(exit_code)
