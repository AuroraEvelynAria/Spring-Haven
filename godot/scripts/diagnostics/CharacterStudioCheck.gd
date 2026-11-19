extends SceneTree

## 角色工坊冒烟检查:结构完整性、七表情全部可应用、角色切换重建立绘、
## 表演动作(说话/思考)不炸、信息面板有内容。
## headless 下 Live2D 扩展不可用,断言走 PortraitRig2D 回退路径
## (与 GameWorld 同一条工厂路径)。

var _failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var scene := load("res://scenes/CharacterStudio/CharacterStudio.tscn") as PackedScene
	_expect(scene != null, "CharacterStudio 场景无法加载")
	var studio := scene.instantiate()
	root.add_child(studio)
	await process_frame
	await process_frame

	# 结构:左列表情盘 + 预览台挂架里有立绘
	var swatch_map: Dictionary = studio.get("_swatch_buttons")
	_expect(swatch_map.size() == 7, "表情盘应有 7 个语义表情,实际 %d" % swatch_map.size())
	var role_map: Dictionary = studio.get("_role_buttons")
	_expect(role_map.size() == 2, "角色按钮应有 2 个")
	var rig_holder: Control = studio.get("_rig_holder")
	_expect(
		rig_holder != null and rig_holder.get_child_count() == 1,
		"预览台挂架应有且只有一个立绘"
	)
	var rig: Control = studio.get("_rig")
	_expect(rig != null and rig.is_inside_tree(), "立绘未入树")
	if rig != null and rig.has_method("get_manifest_summary"):
		var summary: Dictionary = rig.call("get_manifest_summary")
		_expect(not summary.is_empty(), "立绘清单摘要为空")

	# 七个语义表情逐一应用并回读
	for expression in ["neutral", "happy", "worried", "angry", "shy", "tired", "thinking"]:
		rig.call("set_expression", expression)
		var applied := str(rig.call("get_expression"))
		_expect(applied == expression, "表情 %s 未生效(实际 %s)" % [expression, applied])

	# 角色切换:立绘重建 + 状态更新
	studio.call("_set_role", "nai")
	await process_frame
	await process_frame
	var rig_after: Control = studio.get("_rig")
	_expect(
		rig_after != null and rig_after != rig and rig_after.is_inside_tree(),
		"角色切换后立绘未重建"
	)
	_expect(str(studio.get("_current_role")) == "nai", "角色状态未更新")

	# 表演动作不炸
	rig_after.call("speak", "测试一句话。", 2.0)
	rig_after.call("set_thinking", true)
	await process_frame
	rig_after.call("set_thinking", false)

	# 信息面板有内容
	var info: Label = studio.get("_info_label")
	_expect(info != null and not info.text.is_empty(), "后端信息面板为空")

	studio.queue_free()
	if _failures.is_empty():
		print("CHARACTER_STUDIO_CHECK=PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("CHARACTER_STUDIO_CHECK failure=", failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures.append(message)
