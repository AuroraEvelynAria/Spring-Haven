extends Node

## Serializes foreground conversations against autonomous/background delivery.
## Requests may finish in any order, but background messages are only exposed
## after every foreground scope has closed.

signal foreground_state_changed(active: bool)
signal background_delivery_ready(delivery_id: String, payload: Dictionary)

const MAX_QUEUED_DELIVERIES := 64
const MAX_DELIVERED_IDS := 256

var _foreground_scopes: Dictionary = {}
var _delivery_in_flight: Dictionary = {}
var _scope_sequence := 0


func _ready() -> void:
	request_drain.call_deferred()


func begin_foreground(owner: String, correlation_id := "") -> String:
	_scope_sequence += 1
	var token := "fg-%d-%d" % [Time.get_ticks_msec(), _scope_sequence]
	_foreground_scopes[token] = {
		"owner": owner.strip_edges().left(64),
		"correlation_id": correlation_id.strip_edges().left(128),
		"started_unix": int(Time.get_unix_time_from_system()),
	}
	if _foreground_scopes.size() == 1:
		foreground_state_changed.emit(true)
	return token


func end_foreground(token: String) -> bool:
	if not _foreground_scopes.erase(token):
		return false
	if _foreground_scopes.is_empty():
		foreground_state_changed.emit(false)
		request_drain.call_deferred()
	return true


func is_foreground_active() -> bool:
	return not _foreground_scopes.is_empty()


func can_start_background() -> bool:
	return not is_foreground_active()


func get_foreground_scope_count() -> int:
	return _foreground_scopes.size()


func is_delivery_delivered(delivery_id: String) -> bool:
	var normalized_id := delivery_id.strip_edges()
	if normalized_id.is_empty():
		return false
	var scheduler := _scheduler_runtime(Global.life_runtime)
	var delivered_ids: Array = scheduler.get("delivered_ids", [])
	return normalized_id in delivered_ids


func has_queued_delivery(delivery_id: String) -> bool:
	var normalized_id := delivery_id.strip_edges()
	if normalized_id.is_empty():
		return false
	var scheduler := _scheduler_runtime(Global.life_runtime)
	var queue: Array = scheduler.get("queued_deliveries", [])
	for item_variant in queue:
		if item_variant is Dictionary and str(item_variant.get("id", "")) == normalized_id:
			return true
	return false


func queue_background_delivery(delivery_id: String, payload: Dictionary) -> bool:
	var normalized_id := delivery_id.strip_edges().left(128)
	if normalized_id.is_empty() or payload.is_empty():
		return false
	var runtime: Dictionary = Global.life_runtime.duplicate(true)
	var scheduler := _scheduler_runtime(runtime)
	var delivered_ids: Array = scheduler.get("delivered_ids", [])
	if normalized_id in delivered_ids:
		return true
	var queue: Array = scheduler.get("queued_deliveries", [])
	for item_variant in queue:
		if item_variant is Dictionary and str(item_variant.get("id", "")) == normalized_id:
			request_drain.call_deferred()
			return true
	if queue.size() >= MAX_QUEUED_DELIVERIES:
		push_error("后台消息交付队列已满，拒绝覆盖尚未交付的旧消息")
		return false
	queue.append({
		"id": normalized_id,
		"payload": payload.duplicate(true),
		"queued_at_unix": int(Time.get_unix_time_from_system()),
	})
	scheduler["queued_deliveries"] = queue
	runtime["message_scheduler"] = scheduler
	if not Global.update_life_runtime(runtime, true):
		return false
	request_drain.call_deferred()
	return true


func acknowledge_delivery(delivery_id: String) -> bool:
	var normalized_id := delivery_id.strip_edges()
	if normalized_id.is_empty():
		return false
	var runtime: Dictionary = Global.life_runtime.duplicate(true)
	var scheduler := _scheduler_runtime(runtime)
	var queue: Array = scheduler.get("queued_deliveries", [])
	var filtered: Array = []
	for item_variant in queue:
		if not item_variant is Dictionary or str(item_variant.get("id", "")) != normalized_id:
			filtered.append(item_variant)
	var delivered_ids: Array = scheduler.get("delivered_ids", [])
	if normalized_id not in delivered_ids:
		delivered_ids.append(normalized_id)
	while delivered_ids.size() > MAX_DELIVERED_IDS:
		delivered_ids.pop_front()
	scheduler["queued_deliveries"] = filtered
	scheduler["delivered_ids"] = delivered_ids
	runtime["message_scheduler"] = scheduler
	if not Global.update_life_runtime(runtime, true):
		return false
	_delivery_in_flight.erase(normalized_id)
	request_drain.call_deferred()
	return true


func retry_delivery(delivery_id: String, delay_seconds := 2.0) -> void:
	_delivery_in_flight.erase(delivery_id.strip_edges())
	var tree := get_tree()
	if tree == null:
		return
	await tree.create_timer(clampf(delay_seconds, 0.1, 30.0)).timeout
	request_drain()


func request_drain() -> void:
	if is_foreground_active() or not Global.is_state_loaded():
		return
	var scheduler := _scheduler_runtime(Global.life_runtime)
	var queue: Array = scheduler.get("queued_deliveries", [])
	for item_variant in queue:
		if not item_variant is Dictionary:
			continue
		var delivery_id := str(item_variant.get("id", ""))
		var payload_variant = item_variant.get("payload", {})
		if delivery_id.is_empty() or not payload_variant is Dictionary:
			continue
		if _delivery_in_flight.has(delivery_id):
			return
		_delivery_in_flight[delivery_id] = true
		background_delivery_ready.emit(
			delivery_id,
			(payload_variant as Dictionary).duplicate(true)
		)
		return


func _scheduler_runtime(runtime: Dictionary) -> Dictionary:
	var value = runtime.get("message_scheduler", {})
	if value is Dictionary:
		return (value as Dictionary).duplicate(true)
	return {"queued_deliveries": [], "delivered_ids": []}
