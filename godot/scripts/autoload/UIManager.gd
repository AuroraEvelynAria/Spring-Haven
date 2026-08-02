extends Node

var _switching := false

func switch_scene(scene_path: String) -> bool:
	if _switching:
		return false
	_switching = true
	var error := get_tree().change_scene_to_file(scene_path)
	if error != OK:
		_switching = false
		push_error("无法切换场景 %s：%s" % [scene_path, error_string(error)])
		return false
	_finish_switch.call_deferred()
	return true

func _finish_switch() -> void:
	await get_tree().process_frame
	_switching = false
	Global.scene_transition_finished.emit()
