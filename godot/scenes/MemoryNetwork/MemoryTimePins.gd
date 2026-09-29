class_name MemoryTimePins
extends Control

## ADR-010 补充:时间滑杆下方的「章节钉」条。
## 夜织/周织/季织与里程碑节点按诞生世界日排布成细线菱形书签:
## 悬停显示当日叙事摘要,点击把时间游标拨到那一天(纯客户端,零请求)。

signal pin_selected(day: float)

const PIN_WEAVE := Color("#D9CFAE")
const PIN_MILESTONE := Color("#F2D58A")
const EDGE_MARGIN := 10.0
const MAX_PINS := 60

var _pins: Array[Dictionary] = []
var _earliest := 0.0
var _latest := 1.0
var _cursor := -1.0
var _hover_index := -1
var _muted := Color("#A79B90")

func set_pins(pins: Array[Dictionary]) -> void:
	_pins.clear()
	# 保留最近的 MAX_PINS 根:旧实现删掉 60 条截断之后,长旅程会把整条轨道糊满。
	var start := maxi(0, pins.size() - MAX_PINS)
	for index in range(start, pins.size()):
		_pins.append(pins[index])
	_hover_index = -1
	queue_redraw()

func set_range(earliest: float, latest: float) -> void:
	_earliest = earliest
	_latest = maxf(latest, earliest + 1.0)
	queue_redraw()

func set_cursor(world_day: float) -> void:
	_cursor = world_day
	_hover_index = -1
	tooltip_text = ""
	queue_redraw()


# 回溯态下这根钉"当时已经发生几个事件"。总数会把未来成员算进去,
# 于是过去视角的 tooltip 数字反而偏大。
func _visible_count(pin: Dictionary) -> int:
	var member_days = pin.get("member_days", [])
	if _cursor < 0.0 or not (member_days is Array) or (member_days as Array).is_empty():
		return int(pin.get("count", 1))
	var count := 0
	for day_variant in member_days:
		if float(day_variant) <= _cursor:
			count += 1
	return count

func set_palette(theme_data: Dictionary) -> void:
	_muted = Color(str(theme_data.get("secondary", "#A79B90")))
	queue_redraw()

func _draw() -> void:
	if _pins.is_empty():
		return
	var mid_y := size.y * 0.5
	draw_rect(
		Rect2(Vector2(EDGE_MARGIN, mid_y - 0.5), Vector2(size.x - EDGE_MARGIN * 2.0, 1.0)),
		Color(_muted, 0.26)
	)
	for index in _pins.size():
		var pin: Dictionary = _pins[index]
		var count := _visible_count(pin)
		# 回溯态下"当时还没发生"的章节不画出来,而不是留一根幽灵钉在那里。
		if _cursor >= 0.0 and count <= 0:
			continue
		var center := Vector2(_day_to_x(float(pin.day)), mid_y)
		var base := PIN_MILESTONE if str(pin.kind) == "milestone" else PIN_WEAVE
		# 游标之前诞生的钉才「已发生」;游标之后的钉随图谱一起变幽灵
		var future := _cursor >= 0.0 and float(pin.day) > _cursor
		var alpha := 0.22 if future else 0.9
		var mark_size := (4.6 if index == _hover_index else 3.2) + minf(2.4, float(count - 1) * 0.55)
		if index == _hover_index:
			draw_circle(center, mark_size + 3.0, Color(base, 0.16))
		var points := PackedVector2Array([
			center + Vector2(0.0, -mark_size),
			center + Vector2(mark_size, 0.0),
			center + Vector2(0.0, mark_size),
			center + Vector2(-mark_size, 0.0),
			center + Vector2(0.0, -mark_size),
		])
		draw_polyline(points, Color(base, alpha), 1.3, true)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_LEFT and mouse_event.pressed:
			var index := _nearest_pin(mouse_event.position)
			if index >= 0:
				var pin: Dictionary = _pins[index]
				# 拨到「那一天结束」——当天 0 点会把这一整天的节点连同这根
				# 钉自己一起变成幽灵,和 tooltip 的承诺正好相反。
				pin_selected.emit(float(pin.get("cursor", float(pin.day) + 1.0)))
				accept_event()
	elif event is InputEventMouseMotion:
		var index := _nearest_pin((event as InputEventMouseMotion).position)
		if index != _hover_index:
			_hover_index = index
			queue_redraw()

func _get_tooltip(at_position: Vector2) -> String:
	var index := _nearest_pin(at_position)
	if index < 0:
		return ""
	var pin: Dictionary = _pins[index]
	var kind_label := "里程碑"
	if str(pin.kind) == "weekly":
		kind_label = "周织"
	elif str(pin.kind) == "weave":
		kind_label = "心织"
	var count := _visible_count(pin)
	var count_label := " · %d 个事件" % count if count > 1 else ""
	return "%s%s · 世界第 %d 天\n%s" % [
		kind_label,
		count_label,
		int(float(pin.day)) + 1,
		str(pin.title),
	]

func _nearest_pin(position: Vector2) -> int:
	var best := -1
	var best_distance := 12.0
	for index in _pins.size():
		# 回溯态下已经隐藏的钉不能还占据命中区域,否则会点到看不见的东西。
		if _cursor >= 0.0 and _visible_count(_pins[index]) <= 0:
			continue
		var distance := absf(_day_to_x(float(_pins[index].day)) - position.x)
		if distance < best_distance:
			best_distance = distance
			best = index
	return best

func _day_to_x(day: float) -> float:
	var span := maxf(1.0, _latest - _earliest)
	return EDGE_MARGIN + clampf((day - _earliest) / span, 0.0, 1.0) * (size.x - EDGE_MARGIN * 2.0)
