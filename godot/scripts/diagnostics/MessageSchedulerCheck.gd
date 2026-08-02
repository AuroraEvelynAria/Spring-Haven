extends Node

var _received: Array[String] = []
var _failures: Array[String] = []


func _ready() -> void:
	MessageScheduler.background_delivery_ready.connect(_on_delivery)
	var runtime := Global.life_runtime.duplicate(true)
	runtime["message_scheduler"] = {"queued_deliveries": [], "delivered_ids": []}
	if not Global.update_life_runtime(runtime, true):
		_fail("无法初始化调度器测试存档")
		_finish()
		return
	var first := MessageScheduler.begin_foreground("diagnostic", "first")
	var second := MessageScheduler.begin_foreground("diagnostic", "second")
	if not MessageScheduler.queue_background_delivery("diagnostic-delivery", {"kind": "diagnostic"}):
		_fail("后台交付未能入队")
	await get_tree().process_frame
	await get_tree().process_frame
	if not _received.is_empty():
		_fail("前台 scope 活跃时后台消息被提前交付")
	MessageScheduler.end_foreground(first)
	await get_tree().process_frame
	if not _received.is_empty():
		_fail("嵌套前台 scope 尚未清空时后台消息被交付")
	MessageScheduler.end_foreground(second)
	for _index in 8:
		await get_tree().process_frame
	if _received != ["diagnostic-delivery"]:
		_fail("后台消息没有恰好交付一次：%s" % JSON.stringify(_received))
	var scheduler: Dictionary = Global.life_runtime.get("message_scheduler", {})
	if not (scheduler.get("queued_deliveries", []) as Array).is_empty():
		_fail("确认后的消息仍留在持久化队列")
	_finish()


func _on_delivery(delivery_id: String, payload: Dictionary) -> void:
	if str(payload.get("kind", "")) != "diagnostic":
		return
	_received.append(delivery_id)
	MessageScheduler.acknowledge_delivery(delivery_id)


func _fail(message: String) -> void:
	_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("MESSAGE_SCHEDULER_CHECK: PASS")
		get_tree().quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		print("MESSAGE_SCHEDULER_CHECK: FAIL (%d)" % _failures.size())
		get_tree().quit(1)
