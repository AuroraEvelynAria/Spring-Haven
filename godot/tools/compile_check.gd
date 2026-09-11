extends SceneTree

# CI 用：在完整项目上下文中编译加载全部 .gd 脚本，任一编译失败即退出 1。

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var paths: Array[String] = []
	_collect("res://scripts", paths)
	_collect("res://tools", paths)
	_collect("res://scenes", paths)
	var failures: Array[String] = []
	for path in paths:
		if load(path) == null:
			failures.append(path)
			printerr("COMPILE FAIL ", path)
	print("COMPILE_CHECK files=%d failures=%d" % [paths.size(), failures.size()])
	quit(1 if failures.size() > 0 else 0)

func _collect(dir_path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var child := dir_path + "/" + entry
		if dir.current_is_dir():
			if not entry.begins_with("."):
				_collect(child, out)
		elif entry.ends_with(".gd"):
			out.append(child)
		entry = dir.get_next()
	dir.list_dir_end()
