extends Node

## UI 全家福截图：为主人的美术设计评审拍一套带命名的实机图。
## 真窗口运行(非 headless)——headless 下 viewport 无纹理,截图会全空。
## 图落在主人桌面 SpringHaven-UI-截图-2026-11-19/ 目录(桌面重定向由系统 API 决定)。
## 用法: Godot_v4.7 --path godot --script res://scripts/diagnostics/UiScreenshotTour.gd

const GAME_WORLD_SCENE := preload("res://scenes/GameWorld/GameWorld.tscn")
const SHOT_DIR := "SpringHaven-UI-截图-2026-11-19"
const SEED_SAVE_ID := "diagnostic-ui-tour"

var _shot_root := ""
var _failures: Array[String] = []
var _index := 0

func _is_headless() -> bool:
	return DisplayServer.get_name() == "headless"

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	if _is_headless():
		printerr("UI_SCREENSHOT_TOUR headless 无渲染窗口,请用真窗口模式运行")
		get_tree().quit(2)
		return
	_shot_root = _resolve_desktop().path_join(SHOT_DIR)
	DirAccess.make_dir_recursive_absolute(_shot_root)
	print("UI_SCREENSHOT_TOUR output_dir=", _shot_root)

	# ---- 1. 主菜单 ----
	var main_menu: Node = load("res://scenes/MainMenu/MainMenu.tscn").instantiate()
	get_tree().root.add_child(main_menu)
	await _settle()
	await _shot("01-main-menu-主菜单")
	main_menu.queue_free()
	await _settle()

	# ---- GameWorld 准备(亮色主题) ----
	Global.save_id = SEED_SAVE_ID
	await _seed_memories_via_core()
	Global.current_character = "ling"
	Global.stats_by_role = Global.call("_normalize_stats_by_role", {})
	Global.conversation_history = [{
		"id": "seed-ling",
		"sender": "ai",
		"role": "ling",
		"text": "喵～窗边的阳光正好，主人的位置我都留好了。",
		"status": "sent",
		"event_type": "chat",
		"created_at": int(Time.get_unix_time_from_system()) - 300,
	}, {
		"id": "seed-nai",
		"sender": "ai",
		"role": "nai",
		"target_role": "ling",
		"text": "主人主人！今天排练的新舞，跳给你看好不好呀？",
		"status": "sent",
		"event_type": "chat",
		"created_at": int(Time.get_unix_time_from_system()) - 240,
	}, {
		"id": "seed-xixi",
		"sender": "ai",
		"role": "xixi",
		"text": "呐呐……今晚的家里好热闹，汐汐的尾巴都跟着摇起来了。",
		"status": "sent",
		"event_type": "chat",
		"created_at": int(Time.get_unix_time_from_system()) - 180,
	}]
	Global.applied_local_effect_ids = []
	Global.full_stat_milestones = {}
	Global.life_runtime = Global.call("_normalize_life_runtime", {})
	Global.state_loaded = true
	var world := GAME_WORLD_SCENE.instantiate()
	world.set("_suppress_exit_persistence", true)
	get_tree().root.add_child(world)
	await _settle(30)
	# 历史已有内容,引导轮播不会触发。
	ThemeMgr.apply_theme("haru")
	await _settle()

	# ---- 2. 客厅·浅色 ----
	await _shot("02-gameworld-haru-客厅-浅色主题")

	# ---- 3. 切到汐汐(第三角色按钮) ----
	world.call("_switch_role", "xixi", false, false)
	await _settle()
	await _shot("03-gameworld-xixi-汐汐选中")

	# ---- 4. 心织记忆网络·浅色 ----
	var memory_panel := world.get("_memory_network_panel") as Control
	if is_instance_valid(memory_panel):
		memory_panel.call("show_panel")
		await _settle(30)
		await _shot("04-memory-network-haru-心织网络-浅色")
		memory_panel.call("close_panel")
		await _settle()

	# ---- 5. 聊天归档 ----
	var archive_panel := world.get("_archive_panel") as Control
	if is_instance_valid(archive_panel):
		archive_panel.call("show_panel")
		await _settle()
		await _shot("05-archive-聊天归档")
		archive_panel.call("close_panel")
		await _settle()

	# ---- 6. 生活回顾 ----
	var life_review_panel := world.get("_life_review_panel") as Control
	if is_instance_valid(life_review_panel):
		life_review_panel.call("show_panel")
		await _settle()
		await _shot("06-life-review-生活回顾")
		life_review_panel.call("close_panel")
		await _settle()

	# ---- 7. 设置 ----
	var settings_panel := world.get("_settings") as Control
	if is_instance_valid(settings_panel):
		settings_panel.call("show_panel")
		await _settle()
		await _shot("07-settings-设置")
		settings_panel.call("close_panel")
		await _settle()

	# ---- 8. 暗色主题 ----
	ThemeMgr.apply_theme("haru_night")
	await _settle()
	await _shot("08-gameworld-harunight-客厅-深色主题")

	# ---- 9. 心织网络·深色 ----
	if is_instance_valid(memory_panel):
		memory_panel.call("show_panel")
		await _settle(30)
		await _shot("09-memory-network-harunight-心织网络-深色")
		memory_panel.call("close_panel")
		await _settle()

	# ---- 10. 3D 探索 ----
	# 不走 GameWorld._open_exploration(它是 change_scene,会把本 tour 节点当
	# current_scene 一起换掉);直接实例化探索场景到 root,拍完手动清理。
	world.set("_typewriter_skip_requested", true)
	for tween in get_tree().get_processed_tweens():
		tween.kill()
	await get_tree().process_frame
	world.free()
	await _settle(12)
	var exploration: Node = load("res://scenes/Exploration/ExplorationWorld.tscn").instantiate()
	get_tree().root.add_child(exploration)
	await _settle(90)
	await _shot("10-exploration-3d-客餐厅探索")
	exploration.queue_free()
	await _settle()

	_wrap_up()

## 心织画布不能是空图:往本诊断存档塞一批合成记忆(纯虚构、绝无真实数据),
## 让记忆网络截图呈现真实的节点-连线形态。直接 HTTP 打本地 Core,不依赖
## 客户端私有方法。
func _seed_memories_via_core() -> void:
	var key_path := ProjectSettings.globalize_path("user://companion_core_key.txt")
	if not FileAccess.file_exists(key_path):
		print("UI_SCREENSHOT_TOUR seed skipped: core key missing")
		return
	var key := FileAccess.get_file_as_string(key_path).strip_edges()
	if key.is_empty() or not CompanionCore.is_active():
		print("UI_SCREENSHOT_TOUR seed skipped: core offline")
		return
	var seeds: Array[Dictionary] = [
		{"scope_role_id": "*", "kind": "episodic", "title": "餐桌边的栀子花", "content": "主人把一盆栀子花搬到了餐桌边，说家里需要一点香气。", "importance": 0.7},
		{"scope_role_id": "*", "kind": "semantic", "title": "周日的市集", "content": "每周日上午附近的公园有手作市集，可以买到栀子花和团子。", "importance": 0.5},
		{"scope_role_id": "ling", "kind": "episodic", "title": "窗台上的阳光", "content": "小玲在窗台上晒了一下午太阳，梦到了小鱼干。", "importance": 0.6},
		{"scope_role_id": "ling", "kind": "preference", "title": "小鱼干的品牌", "content": "小玲最喜欢海苔味的小鱼干，其次是原味。", "importance": 0.6},
		{"scope_role_id": "nai", "kind": "episodic", "title": "排练的新舞", "content": "小奈在团子生活实验室排练了一支新舞，想跳给主人看。", "importance": 0.75},
		{"scope_role_id": "nai", "kind": "relationship", "title": "和小玲姐姐的约定", "content": "小奈和小玲约好，周末一起去市集买团子。", "importance": 0.65},
		{"scope_role_id": "xixi", "kind": "episodic", "title": "搬进来的第一晚", "content": "汐汐拖着小行李箱搬进了这个家，小玲泡了迎客茶。", "importance": 0.8},
		{"scope_role_id": "xixi", "kind": "preference", "title": "贝壳风铃", "content": "汐汐喜欢收集贝壳做风铃，挂在窗边听海的声音。", "importance": 0.55},
	]
	for seed in seeds:
		var entry := {
			"save_id": SEED_SAVE_ID,
			"scope_role_id": str(seed.get("scope_role_id", "*")),
			"kind": str(seed.get("kind", "episodic")),
			"title": str(seed.get("title", "")),
			"content": str(seed.get("content", "")),
			"importance": float(seed.get("importance", 0.5)),
			"confidence": 0.9,
		}
		var http := HTTPRequest.new()
		add_child(http)
		var body := JSON.stringify(entry)
		http.request(
			CompanionCore.get_base_url() + "/memory/entries",
			["Content-Type: application/json", "X-API-Key: " + key],
			HTTPClient.METHOD_POST,
			body,
		)
		var results: Array = await http.request_completed
		http.queue_free()
		if int(results[0]) != 0 or int(results[1]) != 200:
			print("UI_SCREENSHOT_TOUR seed failed: ", str(seed.get("title", "")), " code=", results[1])


	var output: Array = []
	var exit_code := OS.execute(
		"powershell",
		["-NoProfile", "-Command", "[Environment]::GetFolderPath('Desktop')"],
		output,
	)
	if exit_code == 0 and str(output[0]).strip_edges() != "":
		return str(output[0]).strip_edges()
	return ProjectSettings.globalize_path("user://").path_join("../Desktop")

func _resolve_desktop() -> String:
	var output: Array = []
	var exit_code := OS.execute(
		"powershell",
		["-NoProfile", "-Command", "[Environment]::GetFolderPath('Desktop')"],
		output,
	)
	if exit_code == 0 and str(output[0]).strip_edges() != "":
		return str(output[0]).strip_edges()
	return ProjectSettings.globalize_path("user://").path_join("../Desktop")

func _settle(frames := 18) -> void:
	for _frame in frames:
		await get_tree().process_frame

func _shot(caption: String) -> void:
	_index += 1
	var image := get_viewport().get_texture().get_image()
	var path := _shot_root.path_join("%s.png" % caption)
	if image == null or image.is_empty():
		_failures.append("截图为空:%s" % caption)
		return
	if image.save_png(path) != OK:
		_failures.append("保存失败:%s" % caption)
		return
	print("UI_SCREENSHOT_TOUR shot=%d ok=%s" % [_index, path])

func _wrap_up() -> void:
	for _frame in 8:
		await get_tree().process_frame
	if _failures.is_empty():
		print("UI_SCREENSHOT_TOUR passed shots=%d dir=%s" % [_index, _shot_root])
		get_tree().quit(0)
		return
	for failure in _failures:
		printerr("UI_SCREENSHOT_TOUR failure=", failure)
	get_tree().quit(1)
