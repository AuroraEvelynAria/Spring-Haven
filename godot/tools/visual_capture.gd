extends SceneTree
func _initialize() -> void:
	print("STEP init")
	_run.call_deferred()
func _run() -> void:
	print("STEP run-start")
	var main: Node = load("res://scenes/MainMenu/MainMenu.tscn").instantiate()
	print("STEP instantiated")
	root.add_child(main)
	print("STEP added")
	for i in 240:
		await process_frame
		if i % 60 == 0:
			print("STEP frame ", i)
	print("STEP settling done")
	quit(0)
