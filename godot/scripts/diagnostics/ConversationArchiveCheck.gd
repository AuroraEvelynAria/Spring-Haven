extends Node

const ARCHIVE := preload("res://scripts/domain/ConversationArchive.gd")

var _checks := 0
var _failures: Array[String] = []

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var first_time := int(Time.get_unix_time_from_datetime_dict({
		"year": 2026, "month": 7, "day": 21,
		"hour": 12, "minute": 30, "second": 0,
	}))
	var second_time := int(Time.get_unix_time_from_datetime_dict({
		"year": 2026, "month": 7, "day": 22,
		"hour": 13, "minute": 45, "second": 0,
	}))
	var first_date := ARCHIVE.date_key_from_unix(first_time)
	var second_date := ARCHIVE.date_key_from_unix(second_time)
	var entries: Array[Dictionary] = [{
		"id": "archive-user-1",
		"sender": "user",
		"role": "ling",
		"text": "今晚想和小玲一起吃晚饭。",
		"status": "sent",
		"created_at": first_time,
	}, {
		"id": "archive-ai-1",
		"sender": "ai",
		"role": "nai",
		"text": "我会把窗边的花照顾好。",
		"status": "sent",
		"created_at": second_time,
	}]
	_expect(ARCHIVE.upsert_entries(entries, "archive-check-save"), "跨日期归档写入失败")
	var dates := ARCHIVE.list_dates("archive-check-save")
	_expect(_has_date(dates, first_date), "第一天没有出现在归档日期列表")
	_expect(_has_date(dates, second_date), "第二天没有出现在归档日期列表")
	var keyword_results := ARCHIVE.search_entries("晚饭", "", "", "", "archive-check-save")
	_expect(keyword_results.size() == 1, "关键词检索结果数量错误")
	if keyword_results.size() == 1:
		_expect(str(keyword_results[0].get("id", "")) == "archive-user-1", "关键词检索命中了错误消息")
	var role_results := ARCHIVE.search_entries("", "", "nai", "ai", "archive-check-save")
	_expect(role_results.size() == 1, "角色与发送者组合筛选错误")
	_expect(ARCHIVE.list_dates("missing-save").is_empty(), "日期列表泄漏了其他旅程")
	_expect(
		ARCHIVE.search_entries("", "", "", "", "missing-save").is_empty(),
		"消息检索泄漏了其他旅程"
	)

	var updated: Dictionary = entries[0].duplicate(true)
	updated["status"] = "failed"
	updated["error"] = "测试失败状态"
	updated["retryable"] = true
	_expect(ARCHIVE.upsert_entries([updated], "archive-check-save"), "归档消息状态更新失败")
	var first_day_entries := ARCHIVE.load_date(first_date)
	_expect(first_day_entries.size() == 1, "同一消息更新后产生了重复记录")
	if first_day_entries.size() == 1:
		_expect(str(first_day_entries[0].get("status", "")) == "failed", "归档没有更新消息状态")

	var date_count_before := ARCHIVE.list_dates().size()
	_expect(ARCHIVE.upsert_entries(entries, "diagnostic-archive-check"), "诊断归档跳过接口失败")
	_expect(ARCHIVE.list_dates().size() == date_count_before, "诊断消息被写入正式聊天归档")

	if _failures.is_empty():
		print("CONVERSATION_ARCHIVE_CHECK passed=", _checks)
		get_tree().quit(0)
		return
	for failure in _failures:
		printerr("CONVERSATION_ARCHIVE_CHECK failure=", failure)
	get_tree().quit(1)

func _has_date(summaries: Array[Dictionary], date_key: String) -> bool:
	for summary in summaries:
		if str(summary.get("date", "")) == date_key:
			return true
	return false

func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
