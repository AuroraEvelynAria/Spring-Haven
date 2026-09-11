extends Node

const TOAST_SCRIPT := "res://tools/windows_toast.ps1"
const TOAST_SCRIPT_COPY := "user://windows_toast.ps1"
const TEXT_SANITIZER := preload("res://scripts/domain/TextSanitizer.gd")

func show_notification(title: String, body: String) -> bool:
	var safe_title := TEXT_SANITIZER.strip_nul(title).strip_edges().left(80)
	var safe_body := TEXT_SANITIZER.strip_nul(body).strip_edges().left(320)
	if safe_title.is_empty() or safe_body.is_empty():
		return false
	DisplayServer.window_request_attention()
	if OS.get_name() != "Windows":
		return false
	var script_path := _materialize_toast_script()
	if script_path.is_empty():
		return false
	var arguments := PackedStringArray([
		"-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden",
		"-ExecutionPolicy", "Bypass", "-File", script_path,
		"-Title", safe_title, "-Body", safe_body,
	])
	return OS.create_process("powershell.exe", arguments, false) > 0

# 导出后 TOAST_SCRIPT 打进 pck 容器，powershell.exe 无法按真实路径执行，
# 必须先镜像到 user:// 这类真实文件系统位置再交给 -File。
func _materialize_toast_script() -> String:
	var source := FileAccess.open(TOAST_SCRIPT, FileAccess.READ)
	if source == null:
		return ""
	var content := source.get_as_text()
	source.close()
	if content.is_empty():
		return ""
	var writer := FileAccess.open(TOAST_SCRIPT_COPY, FileAccess.WRITE)
	if writer == null:
		return ""
	writer.store_string(content)
	writer.close()
	return ProjectSettings.globalize_path(TOAST_SCRIPT_COPY)
