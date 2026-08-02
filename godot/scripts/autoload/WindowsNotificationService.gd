extends Node

const TOAST_SCRIPT := "res://tools/windows_toast.ps1"
const TEXT_SANITIZER := preload("res://scripts/domain/TextSanitizer.gd")

func show_notification(title: String, body: String) -> bool:
	var safe_title := TEXT_SANITIZER.strip_nul(title).strip_edges().left(80)
	var safe_body := TEXT_SANITIZER.strip_nul(body).strip_edges().left(320)
	if safe_title.is_empty() or safe_body.is_empty():
		return false
	DisplayServer.window_request_attention()
	if OS.get_name() != "Windows" or not FileAccess.file_exists(TOAST_SCRIPT):
		return false
	var script_path := ProjectSettings.globalize_path(TOAST_SCRIPT)
	var arguments := PackedStringArray([
		"-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden",
		"-ExecutionPolicy", "Bypass", "-File", script_path,
		"-Title", safe_title, "-Body", safe_body,
	])
	return OS.create_process("powershell.exe", arguments, false) > 0
