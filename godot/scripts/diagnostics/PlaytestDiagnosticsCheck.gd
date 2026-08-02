extends SceneTree

const DIAGNOSTICS := preload("res://scripts/domain/PlaytestDiagnostics.gd")
const OUTPUT_DIR := "user://SpringHaven/diagnostics-check"
const LOG_DIR := OUTPUT_DIR + "/source-logs"

var _failed := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_cleanup()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(LOG_DIR))
	var log_file := FileAccess.open(LOG_DIR + "/private.log", FileAccess.WRITE)
	if log_file:
		log_file.store_string(
			"Authorization: Bearer sk-test-this-is-not-real\n"
			+ "reply=这是一条不应进入默认诊断包的聊天正文\n"
		)
		log_file.close()
	var sanitized = DIAGNOSTICS.sanitize_for_export({
		"api_key": "sk-test-this-is-not-real",
		"conversation_history": [{"content": "私人聊天"}],
		"runtime_path": "C:/Users/Test/private",
	})
	_expect(sanitized is Dictionary, "脱敏结果不是字典")
	if sanitized is Dictionary:
		_expect(str(sanitized.get("api_key", "")) == "[redacted]", "API Key 未脱敏")
		_expect(
			str(sanitized.get("conversation_history", "")) == "[redacted-private-content]",
			"聊天历史未整体脱敏"
		)
		_expect(str(sanitized.get("runtime_path", "")) == "<local path>", "本地路径未脱敏")
	var result: Dictionary = await DIAGNOSTICS.create_bundle(
		null,
		{"api_key": "sk-test-this-is-not-real", "theme": "amber"},
		{"conversation_history": [{"content": "私人聊天"}], "message_count": 1},
		{
			"output_directory": OUTPUT_DIR,
			"file_stamp": "automated-check",
			"log_directories": [LOG_DIR],
			"include_sanitized_logs": false,
		}
	)
	_expect(bool(result.get("ok", false)), "诊断包创建失败：%s" % str(result.get("message", "")))
	var path := str(result.get("path", ""))
	var reader := ZIPReader.new()
	var open_error := reader.open(path)
	_expect(open_error == OK, "诊断 ZIP 无法打开")
	if open_error == OK:
		var files := reader.get_files()
		_expect("logs/inventory.json" in files, "诊断包缺少日志清单")
		for filename in files:
			_expect(not str(filename).begins_with("logs/source-"), "默认诊断包包含日志正文")
		var all_text := ""
		for filename in files:
			all_text += reader.read_file(filename).get_string_from_utf8()
		_expect("sk-test-this-is-not-real" not in all_text, "诊断包泄露测试密钥")
		_expect("私人聊天" not in all_text, "诊断包泄露聊天正文")
		var manifest = JSON.parse_string(reader.read_file("manifest.json").get_string_from_utf8())
		_expect(manifest is Dictionary, "诊断 manifest 无效")
		if manifest is Dictionary:
			var privacy = manifest.get("privacy", {})
			_expect(
				privacy is Dictionary and not bool((privacy as Dictionary).get("contains_log_text", true)),
				"诊断 manifest 的日志隐私声明错误"
			)
		reader.close()
	_cleanup()
	if _failed:
		quit(1)
		return
	print("PLAYTEST_DIAGNOSTICS_CHECK=PASS")
	quit(0)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	push_error(message)


func _cleanup() -> void:
	var absolute := ProjectSettings.globalize_path(OUTPUT_DIR).simplify_path()
	if not DirAccess.dir_exists_absolute(absolute):
		return
	var logs := ProjectSettings.globalize_path(LOG_DIR).simplify_path()
	if DirAccess.dir_exists_absolute(logs):
		for filename in DirAccess.get_files_at(logs):
			DirAccess.remove_absolute(logs.path_join(filename))
		DirAccess.remove_absolute(logs)
	for filename in DirAccess.get_files_at(absolute):
		DirAccess.remove_absolute(absolute.path_join(filename))
	DirAccess.remove_absolute(absolute)
