extends SceneTree

## GameWorld 舞台化布局冒烟检查(#11 视觉重构):验证新舞台列、HUD 板、
## 去气泡化消息结构与角色切换不破坏逻辑层引用。

var _failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var scene := load("res://scenes/GameWorld/GameWorld.tscn") as PackedScene
	_expect(scene != null, "GameWorld 场景无法加载")
	var world := scene.instantiate()
	root.add_child(world)
	await process_frame
	await process_frame

	# 舞台列结构
	var stage_column: BoxContainer = world.get("_stage_column")
	_expect(stage_column != null, "舞台列不存在")
	var stage_panel: PanelContainer = world.get("_stage_panel")
	_expect(stage_panel != null and stage_panel.get_child_count() > 0, "立绘舞台面板为空")
	var rig: Control = world.get("_portrait_rig")
	_expect(rig != null and rig.is_inside_tree(), "立绘未入树")
	var shadow: ColorRect = world.get("_stage_shadow")
	_expect(shadow != null, "舞台地影缺失")
	var backlight: ColorRect = world.get("_stage_backlight")
	_expect(backlight != null, "舞台背光缺失")
	var name_label: Label = world.get("_stage_name_label")
	_expect(name_label != null and not name_label.text.is_empty(), "舞台名字牌未初始化")

	# HUD 结构
	var sidebar: ScrollContainer = world.get("_sidebar")
	_expect(sidebar != null, "HUD 滚动容器不存在")
	var content: VBoxContainer = world.get("_sidebar_content")
	_expect(content != null and content.get_child_count() == 4, "HUD 应为四块板(生活/周期/身心/絮语)")
	var widgets: Dictionary = world.get("_stat_widgets")
	_expect(widgets.size() >= 11, "需求仪表数量不足: %d" % widgets.size())
	var first_widget: Dictionary = widgets.get("hunger", {})
	_expect(first_widget.get("bar") is ProgressBar, "饥饿仪表缺失")
	var bar: ProgressBar = first_widget.get("bar")
	_expect(bar != null and int(bar.custom_minimum_size.y) >= 7, "仪表未升级为 7px 圆头")

	# 对话去气泡化
	var add_message: Callable = world.get("_add_message")
	var ai_view: Dictionary = add_message.call("测试回复正文，用于验证无框块。", "ai", "nai", false, "stage-check-ai")
	var ai_bubble: PanelContainer = ai_view.get("bubble")
	_expect(ai_bubble != null, "AI 消息缺少内容块")
	var ai_style: StyleBoxFlat = ai_bubble.get_theme_stylebox("panel")
	_expect(ai_style != null and ai_style.border_width_left == 0, "AI 消息块不应有描边")
	var ai_label: Label = ai_view.get("label")
	_expect(ai_label != null and int(ai_label.get_theme_font_size("font_size")) >= 17, "AI 正文字号未升级")
	var user_view: Dictionary = add_message.call("主人喂你喝了水", "user", "nai", false, "stage-check-user")
	var user_label: Label = user_view.get("label")
	_expect(user_label != null and int(user_label.get_theme_font_size("font_size")) >= 14, "玩家引言字号错误")
	_expect(int(user_view.get("bubble").custom_minimum_size.x) >= 0, "玩家胶囊宽度异常")

	# 角色切换后舞台与 HUD 跟随
	world.call("_switch_role", "ling", false, false)
	await process_frame
	var switched_name: Label = world.get("_stage_name_label")
	_expect(str(switched_name.text).contains("小玲"), "角色切换后舞台名字牌未更新")
	expect_stat_rebuilt(world, "stage-check-role-switch")

	# 等待提示轻量化
	world.call("_add_waiting_message", "stage-check-wait", "nai")
	await process_frame
	world.call("_remove_waiting_message", "stage-check-wait")

	world.queue_free()
	if _failures.is_empty():
		print("GAMEWORLD_STAGE_CHECK=PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("GAMEWORLD_STAGE_CHECK failure=", failure)
	quit(1)


func expect_stat_rebuilt(world: Node, _tag: String) -> void:
	var widgets: Dictionary = world.get("_stat_widgets")
	_expect(widgets.size() >= 11, "角色切换后仪表未重建")


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures.append(message)
