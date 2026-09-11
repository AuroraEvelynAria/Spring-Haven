class_name PortraitRig2D
extends Control

signal expression_changed(expression: String)

const EXPRESSIONS := ["neutral", "happy", "worried", "angry", "shy", "tired", "thinking"]
const DEFAULT_SIZE := Vector2(310.0, 224.0)

@export_enum("ling", "nai") var role_id := "ling"
@export_file("*.json") var manifest_path := ""
@export var eye_follow_strength := 1.0
@export var motion_strength := 1.0

var _manifest: Dictionary = {}
# _palette/_draw_backdrop 处于每帧绘制路径：缓存调色板与样式框，
# 仅在 manifest 或角色变化时重建，避免每帧解析十余个 Color。
var _palette_cache: Dictionary = {}
var _palette_cache_role := ""
var _backdrop_style: StyleBoxFlat
var _external_layers: Dictionary = {}
var _layer_defaults: Dictionary = {}
var _layer_root: Control
var _has_external_art := false
var _expression := "neutral"
var _thinking := false
var _elapsed := 0.0
var _blink_elapsed := 0.0
var _blink_duration := 0.0
var _next_blink := 2.4
var _speech_remaining := 0.0
var _tts_mouth_level := -1.0
var _mouth_open := 0.0
var _gaze := Vector2.ZERO
var _body_state: Dictionary = {}
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	custom_minimum_size = DEFAULT_SIZE
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_PASS
	_rng.randomize()
	_layer_root = Control.new()
	_layer_root.name = "ExternalLayers"
	_layer_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_layer_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_layer_root)
	if manifest_path.is_empty():
		manifest_path = _default_manifest_path(role_id)
	_load_manifest()
	set_process(true)
	queue_redraw()


func _process(delta: float) -> void:
	_elapsed += delta
	_update_blink(delta)
	_update_gaze(delta)
	_update_mouth(delta)
	_update_external_motion()
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func set_role(next_role_id: String, next_manifest_path := "") -> void:
	var normalized := next_role_id.strip_edges().to_lower()
	if normalized not in ["ling", "nai"]:
		return
	role_id = normalized
	manifest_path = next_manifest_path.strip_edges()
	if manifest_path.is_empty():
		manifest_path = _default_manifest_path(role_id)
	_expression = "neutral"
	_thinking = false
	_load_manifest()
	queue_redraw()


func set_expression(next_expression: String) -> void:
	var normalized := next_expression.strip_edges().to_lower()
	if normalized not in EXPRESSIONS:
		normalized = "neutral"
	if normalized == _expression:
		return
	_expression = normalized
	_apply_external_layer_state()
	expression_changed.emit(_expression)
	queue_redraw()


func get_expression() -> String:
	return "thinking" if _thinking else _expression


func set_thinking(active: bool) -> void:
	if active == _thinking:
		return
	_thinking = active
	_apply_external_layer_state()
	queue_redraw()


func set_body_state(state: Dictionary) -> void:
	_body_state = state.duplicate(true)
	if not _thinking and _speech_remaining <= 0.0:
		set_expression(_expression_from_body_state())


func speak(text: String, seconds := -1.0) -> void:
	var clean_text := text.strip_edges()
	if clean_text.is_empty():
		return
	_speech_remaining = (
		clampf(float(clean_text.length()) / 16.0, 1.1, 7.0)
		if seconds <= 0.0
		else clampf(seconds, 0.2, 15.0)
	)
	react_to_text(clean_text)


func react_to_text(text: String) -> void:
	var normalized := text.to_lower()
	if _contains_any(normalized, ["害羞", "脸红", "不好意思", "喜欢你", "爱你"]):
		set_expression("shy")
	elif _contains_any(normalized, ["生气", "不高兴", "讨厌", "哼！", "哼!"]):
		set_expression("angry")
	elif _contains_any(normalized, ["担心", "难过", "疼", "不舒服", "害怕", "压力"]):
		set_expression("worried")
	elif _contains_any(normalized, ["困", "累了", "休息", "睡觉", "没精神"]):
		set_expression("tired")
	elif _contains_any(normalized, ["开心", "高兴", "哈哈", "谢谢", "太好了", "喜欢"]):
		set_expression("happy")


func set_tts_mouth_level(level: float) -> void:
	_tts_mouth_level = clampf(level, 0.0, 1.0)


func release_tts_mouth() -> void:
	_tts_mouth_level = -1.0


func get_manifest_summary() -> Dictionary:
	return {
		"role_id": role_id,
		"manifest_path": manifest_path,
		"external_art": _has_external_art,
		"layer_count": _external_layers.size(),
		"expression": get_expression(),
	}


func _load_manifest() -> void:
	_manifest.clear()
	_external_layers.clear()
	_layer_defaults.clear()
	_has_external_art = false
	if is_instance_valid(_layer_root):
		for child in _layer_root.get_children():
			child.queue_free()
	if manifest_path.is_empty() or not FileAccess.file_exists(manifest_path):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	if not parsed is Dictionary:
		push_warning("Portrait manifest is not a JSON object: %s" % manifest_path)
		return
	_manifest = (parsed as Dictionary).duplicate(true)
	_palette_cache = {}
	var layers_variant = _manifest.get("layers", [])
	if not layers_variant is Array:
		return
	for layer_variant in layers_variant:
		if not layer_variant is Dictionary:
			continue
		var layer: Dictionary = layer_variant
		var layer_id := str(layer.get("id", "")).strip_edges()
		var path := str(layer.get("path", "")).strip_edges()
		if layer_id.is_empty() or path.is_empty() or not ResourceLoader.exists(path):
			continue
		var texture = load(path)
		if not texture is Texture2D:
			continue
		var texture_rect := TextureRect.new()
		texture_rect.name = layer_id
		texture_rect.texture = texture
		texture_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		texture_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		texture_rect.z_index = int(layer.get("z", 0))
		texture_rect.visible = bool(layer.get("visible", true))
		_layer_root.add_child(texture_rect)
		_external_layers[layer_id] = texture_rect
		_layer_defaults[layer_id] = texture_rect.visible
	_has_external_art = not _external_layers.is_empty()
	_apply_external_layer_state()


func _apply_external_layer_state() -> void:
	if not _has_external_art:
		return
	for layer_id_variant in _external_layers:
		var layer_id := str(layer_id_variant)
		var node := _external_layers[layer_id] as TextureRect
		if is_instance_valid(node):
			node.visible = bool(_layer_defaults.get(layer_id, true))
	var visual_expression := "thinking" if _thinking else _expression
	var expressions_variant = _manifest.get("expressions", {})
	if expressions_variant is Dictionary:
		var state_variant = (expressions_variant as Dictionary).get(visual_expression, {})
		if state_variant is Dictionary:
			_set_layer_visibility((state_variant as Dictionary).get("show", []), true)
			_set_layer_visibility((state_variant as Dictionary).get("hide", []), false)
	var blink_layer := str(_manifest.get("blink_layer", ""))
	if not blink_layer.is_empty() and _external_layers.has(blink_layer):
		(_external_layers[blink_layer] as TextureRect).visible = _blink_amount() > 0.55
	var mouth_shapes_variant = _manifest.get("mouth_shapes", [])
	if mouth_shapes_variant is Array:
		var mouth_shapes: Array = mouth_shapes_variant
		var selected_index := clampi(int(round(_mouth_open * 4.0)), 0, 4)
		for index in mouth_shapes.size():
			var mouth_id := str(mouth_shapes[index])
			if _external_layers.has(mouth_id):
				(_external_layers[mouth_id] as TextureRect).visible = index == selected_index


func _set_layer_visibility(raw_ids: Variant, visible: bool) -> void:
	if not raw_ids is Array:
		return
	for id_variant in raw_ids:
		var layer_id := str(id_variant)
		if _external_layers.has(layer_id):
			(_external_layers[layer_id] as TextureRect).visible = visible


func _update_blink(delta: float) -> void:
	if _blink_duration > 0.0:
		_blink_elapsed += delta
		if _blink_elapsed >= _blink_duration:
			_blink_duration = 0.0
			_blink_elapsed = 0.0
			_next_blink = _rng.randf_range(2.2, 5.4)
	else:
		_next_blink -= delta
		if _next_blink <= 0.0:
			_blink_duration = _rng.randf_range(0.12, 0.19)
	_apply_external_layer_state()


func _blink_amount() -> float:
	if _blink_duration <= 0.0:
		return 0.0
	return sin(clampf(_blink_elapsed / _blink_duration, 0.0, 1.0) * PI)


func _update_gaze(delta: float) -> void:
	var local_mouse := get_local_mouse_position()
	var target := Vector2.ZERO
	if Rect2(Vector2.ZERO, size).grow(120.0).has_point(local_mouse):
		target = Vector2(
			clampf((local_mouse.x / maxf(size.x, 1.0) - 0.5) * 2.0, -1.0, 1.0),
			clampf((local_mouse.y / maxf(size.y, 1.0) - 0.46) * 2.0, -1.0, 1.0)
		) * eye_follow_strength
	_gaze = _gaze.lerp(target, clampf(delta * 5.5, 0.0, 1.0))


func _update_mouth(delta: float) -> void:
	if _tts_mouth_level >= 0.0:
		_mouth_open = lerpf(_mouth_open, _tts_mouth_level, clampf(delta * 18.0, 0.0, 1.0))
	elif _speech_remaining > 0.0:
		_speech_remaining = maxf(0.0, _speech_remaining - delta)
		var syllable := 0.25 + 0.75 * absf(sin(_elapsed * 10.8) * sin(_elapsed * 4.9 + 0.7))
		_mouth_open = lerpf(_mouth_open, syllable, clampf(delta * 15.0, 0.0, 1.0))
	else:
		_mouth_open = lerpf(_mouth_open, 0.0, clampf(delta * 12.0, 0.0, 1.0))
	_apply_external_layer_state()


func _update_external_motion() -> void:
	if not is_instance_valid(_layer_root):
		return
	var strength := clampf(motion_strength, 0.0, 2.0)
	var breathe := sin(_elapsed * 1.75) * 1.7 * strength
	var sway := sin(_elapsed * 0.72 + (0.4 if role_id == "nai" else 0.0)) * 1.4 * strength
	_layer_root.position = Vector2(sway, breathe)
	_layer_root.pivot_offset = size * 0.5
	var breath_scale := 1.0 + sin(_elapsed * 1.75) * 0.004 * strength
	_layer_root.scale = Vector2(breath_scale, breath_scale)


func _draw() -> void:
	_draw_backdrop()
	if not _has_external_art:
		_draw_placeholder_portrait()
	_draw_foreground_effects()


func _draw_backdrop() -> void:
	var palette := _palette()
	if _backdrop_style == null:
		_backdrop_style = StyleBoxFlat.new()
		_backdrop_style.set_border_width_all(1)
		_backdrop_style.set_corner_radius_all(8)
	_backdrop_style.bg_color = Color(palette.background, 0.94)
	_backdrop_style.border_color = Color(palette.accent, 0.34)
	draw_style_box(_backdrop_style, Rect2(Vector2.ZERO, size))
	var horizon_y := size.y * 0.76
	draw_rect(Rect2(0.0, horizon_y, size.x, size.y - horizon_y), Color(palette.secondary, 0.10))
	for index in 5:
		var x := size.x * (0.10 + float(index) * 0.19)
		var y := size.y * (0.18 + float(index % 2) * 0.09)
		draw_circle(Vector2(x, y), 2.0 + float(index % 3), Color(palette.accent, 0.12), true, -1.0, true)


func _draw_placeholder_portrait() -> void:
	var palette := _palette()
	var strength := clampf(motion_strength, 0.0, 2.0)
	var breathe := sin(_elapsed * 1.75) * 1.7 * strength
	var sway := sin(_elapsed * 0.72 + (0.4 if role_id == "nai" else 0.0)) * 1.4 * strength
	var scale_value := minf(size.x / DEFAULT_SIZE.x, size.y / DEFAULT_SIZE.y)
	var center := Vector2(size.x * 0.53 + sway, size.y * 0.49 + breathe)
	var face_radius := 58.0 * scale_value
	var visual_expression := "thinking" if _thinking else _expression

	# Back hair and soft shadow.
	draw_circle(Vector2(center.x + 3.0, size.y * 0.88), 55.0 * scale_value, Color(0.03, 0.04, 0.05, 0.18), true, -1.0, true)
	draw_circle(center + Vector2(0.0, 13.0 * scale_value), face_radius * 1.12, Color(palette.hair_shadow), true, -1.0, true)
	_draw_ears(center, face_radius, scale_value, palette)

	# Shoulders, clothes and collar.
	var shoulders := PackedVector2Array([
		center + Vector2(-79.0, 92.0) * scale_value,
		center + Vector2(-52.0, 58.0) * scale_value,
		center + Vector2(52.0, 58.0) * scale_value,
		center + Vector2(79.0, 92.0) * scale_value,
	])
	draw_colored_polygon(shoulders, Color(palette.outfit))
	draw_circle(center + Vector2(0.0, 55.0) * scale_value, 20.0 * scale_value, Color(palette.skin_shadow), true, -1.0, true)

	# Face, fringe and side locks.
	draw_circle(center, face_radius, Color(palette.skin), true, -1.0, true)
	draw_circle(center + Vector2(-48.0, 12.0) * scale_value, 20.0 * scale_value, Color(palette.hair), true, -1.0, true)
	draw_circle(center + Vector2(48.0, 12.0) * scale_value, 20.0 * scale_value, Color(palette.hair), true, -1.0, true)
	var fringe := PackedVector2Array([
		center + Vector2(-55.0, -31.0) * scale_value,
		center + Vector2(-35.0, -57.0) * scale_value,
		center + Vector2(-12.0, -50.0) * scale_value,
		center + Vector2(4.0, -60.0) * scale_value,
		center + Vector2(20.0, -47.0) * scale_value,
		center + Vector2(43.0, -52.0) * scale_value,
		center + Vector2(57.0, -24.0) * scale_value,
		center + Vector2(51.0, -8.0) * scale_value,
		center + Vector2(-51.0, -8.0) * scale_value,
	])
	draw_colored_polygon(fringe, Color(palette.hair))

	_draw_face(center, face_radius, scale_value, palette, visual_expression)
	_draw_accessory(center, scale_value, palette)


func _draw_ears(center: Vector2, radius: float, scale_value: float, palette: Dictionary) -> void:
	if role_id == "nai":
		for side in [-1.0, 1.0]:
			var ear_center := center + Vector2(side * 29.0, -91.0) * scale_value
			var ear_points := PackedVector2Array([
				ear_center + Vector2(-14.0, 44.0) * scale_value,
				ear_center + Vector2(-10.0, -38.0) * scale_value,
				ear_center + Vector2(0.0, -55.0) * scale_value,
				ear_center + Vector2(11.0, -38.0) * scale_value,
				ear_center + Vector2(15.0, 44.0) * scale_value,
			])
			draw_colored_polygon(ear_points, Color(palette.hair))
			draw_line(
				ear_center + Vector2(0.0, -37.0) * scale_value,
				ear_center + Vector2(0.0, 31.0) * scale_value,
				Color(palette.accent, 0.46),
				5.0 * scale_value,
				true
			)
	else:
		for side in [-1.0, 1.0]:
			var base := center + Vector2(side * radius * 0.55, -radius * 0.66)
			var points := PackedVector2Array([
				base + Vector2(-20.0 * side, 12.0) * scale_value,
				base + Vector2(-12.0 * side, -42.0) * scale_value,
				base + Vector2(24.0 * side, -8.0) * scale_value,
			])
			draw_colored_polygon(points, Color(palette.hair))
			var inner := PackedVector2Array([
				base + Vector2(-10.0 * side, 3.0) * scale_value,
				base + Vector2(-8.0 * side, -27.0) * scale_value,
				base + Vector2(13.0 * side, -7.0) * scale_value,
			])
			draw_colored_polygon(inner, Color(palette.accent, 0.48))


func _draw_face(
	center: Vector2,
	_face_radius: float,
	scale_value: float,
	palette: Dictionary,
	visual_expression: String
) -> void:
	var blink := _blink_amount()
	var gaze_offset := _gaze * Vector2(4.2, 3.0) * scale_value
	var eye_y := center.y + (-2.0 if visual_expression == "happy" else 1.0) * scale_value
	var eye_spacing := 22.0 * scale_value
	var eye_height := maxf(0.8, (8.0 * (1.0 - blink))) * scale_value
	if visual_expression == "tired":
		eye_height *= 0.42
	elif visual_expression == "happy":
		eye_height *= 0.66

	for side in [-1.0, 1.0]:
		var eye_center := Vector2(center.x + side * eye_spacing, eye_y) + gaze_offset
		if blink > 0.76:
			draw_line(
				eye_center + Vector2(-6.0, 0.0) * scale_value,
				eye_center + Vector2(6.0, 0.0) * scale_value,
				Color(palette.line),
				2.4 * scale_value,
				true
			)
		else:
			draw_circle(eye_center, eye_height, Color(palette.eye), true, -1.0, true)
			draw_circle(eye_center + Vector2(0.0, 1.0) * scale_value, eye_height * 0.47, Color(palette.line), true, -1.0, true)
			draw_circle(eye_center + Vector2(-2.2, -2.2) * scale_value, maxf(1.0, eye_height * 0.18), Color.WHITE, true, -1.0, true)

	var brow_y := center.y - 17.0 * scale_value
	var brow_tilt := 0.0
	if visual_expression == "worried":
		brow_tilt = -4.0
	elif visual_expression == "angry":
		brow_tilt = 5.0
	for side in [-1.0, 1.0]:
		var start := Vector2(center.x + side * 14.0 * scale_value, brow_y + side * brow_tilt * scale_value)
		var finish := Vector2(center.x + side * 30.0 * scale_value, brow_y - side * brow_tilt * scale_value)
		draw_line(start, finish, Color(palette.line, 0.72), 1.8 * scale_value, true)

	if visual_expression in ["shy", "happy"]:
		for side in [-1.0, 1.0]:
			draw_circle(
				center + Vector2(side * 39.0, 27.0) * scale_value,
				9.0 * scale_value,
				Color(palette.blush, 0.30 if visual_expression == "happy" else 0.48),
				true,
				-1.0,
				true
			)

	var mouth_center := center + Vector2(0.0, 32.0) * scale_value
	_draw_mouth(mouth_center, scale_value, palette, visual_expression)


func _draw_mouth(center: Vector2, scale_value: float, palette: Dictionary, visual_expression: String) -> void:
	var shape := clampi(int(round(_mouth_open * 4.0)), 0, 4)
	if shape <= 0:
		if visual_expression == "worried":
			draw_arc(center + Vector2(0.0, 4.0) * scale_value, 8.0 * scale_value, PI + 0.25, TAU - 0.25, 18, Color(palette.line), 2.0 * scale_value, true)
		elif visual_expression == "angry":
			draw_line(center + Vector2(-7.0, 1.5) * scale_value, center + Vector2(7.0, -1.5) * scale_value, Color(palette.line), 2.2 * scale_value, true)
		else:
			draw_arc(center, 8.0 * scale_value, 0.18, PI - 0.18, 18, Color(palette.line), 2.0 * scale_value, true)
		return
	var radius_x := (4.0 + shape * 1.7) * scale_value
	var radius_y := (2.0 + shape * 1.6) * scale_value
	draw_circle(center, radius_x, Color(palette.mouth), true, -1.0, true)
	if radius_y < radius_x:
		draw_rect(Rect2(center.x - radius_x, center.y - radius_x, radius_x * 2.0, radius_x - radius_y), Color(palette.skin))
	if shape >= 3:
		draw_circle(center + Vector2(0.0, 3.0) * scale_value, radius_x * 0.45, Color(palette.blush, 0.72), true, -1.0, true)


func _draw_accessory(center: Vector2, scale_value: float, palette: Dictionary) -> void:
	if role_id == "nai":
		var ribbon_center := center + Vector2(55.0, -34.0) * scale_value
		var left := PackedVector2Array([
			ribbon_center,
			ribbon_center + Vector2(-25.0, -13.0) * scale_value,
			ribbon_center + Vector2(-21.0, 13.0) * scale_value,
		])
		var right := PackedVector2Array([
			ribbon_center,
			ribbon_center + Vector2(24.0, -12.0) * scale_value,
			ribbon_center + Vector2(20.0, 14.0) * scale_value,
		])
		draw_colored_polygon(left, Color(palette.accent))
		draw_colored_polygon(right, Color(palette.accent))
		draw_circle(ribbon_center, 7.0 * scale_value, Color(palette.secondary), true, -1.0, true)
	else:
		var bell_center := center + Vector2(0.0, 65.0) * scale_value
		draw_line(bell_center + Vector2(-24.0, -3.0) * scale_value, bell_center + Vector2(24.0, -3.0) * scale_value, Color(palette.secondary), 5.0 * scale_value, true)
		draw_circle(bell_center, 7.0 * scale_value, Color("#E8B84F"), true, -1.0, true)


func _draw_foreground_effects() -> void:
	var palette := _palette()
	if _thinking:
		var orbit_center := Vector2(size.x - 34.0, 30.0)
		for index in 3:
			var angle := _elapsed * 2.1 + float(index) * TAU / 3.0
			var radius := 10.0 + float(index) * 2.0
			draw_circle(
				orbit_center + Vector2(cos(angle), sin(angle)) * radius,
				2.5 + float(index) * 0.7,
				Color(palette.accent, 0.48 + float(index) * 0.14),
				true,
				-1.0,
				true
			)
	elif _expression in ["happy", "shy"]:
		for index in 4:
			var phase := fmod(_elapsed * 0.24 + float(index) * 0.23, 1.0)
			var x := size.x * (0.14 + float(index) * 0.22)
			var y := size.y * (0.82 - phase * 0.64)
			draw_circle(Vector2(x, y), 2.5 + phase * 2.0, Color(palette.accent, (1.0 - phase) * 0.44), true, -1.0, true)


func _expression_from_body_state() -> String:
	var stats_variant = _body_state.get("stats", _body_state)
	var stats: Dictionary = stats_variant if stats_variant is Dictionary else {}
	if float(stats.get("awake", 100.0)) <= 24.0 or float(stats.get("stamina", 100.0)) <= 18.0:
		return "tired"
	if (
		float(stats.get("stress", 0.0)) >= 72.0
		or float(stats.get("hunger", 0.0)) >= 86.0
		or float(stats.get("thirst", 0.0)) >= 86.0
	):
		return "worried"
	if float(stats.get("mood", 50.0)) >= 72.0 or float(stats.get("intimacy", 50.0)) >= 82.0:
		return "happy"
	return "neutral"


func _palette() -> Dictionary:
	if _palette_cache.is_empty() or _palette_cache_role != role_id:
		_palette_cache = _build_palette()
		_palette_cache_role = role_id
	return _palette_cache

func _build_palette() -> Dictionary:
	var fallback := (
		{
			"background": Color("#182126"),
			"accent": Color("#F29A7D"),
			"secondary": Color("#6FB7A7"),
			"hair": Color("#70483F"),
			"hair_shadow": Color("#4B3132"),
			"skin": Color("#F8D4C2"),
			"skin_shadow": Color("#DFAE9E"),
			"eye": Color("#67B5A5"),
			"line": Color("#46343A"),
			"outfit": Color("#4E8D82"),
			"blush": Color("#E97E92"),
			"mouth": Color("#7A394B"),
		}
		if role_id == "ling"
		else {
			"background": Color("#1C1D2A"),
			"accent": Color("#B8A6D9"),
			"secondary": Color("#E2A6B4"),
			"hair": Color("#D9D1E9"),
			"hair_shadow": Color("#8C7FA6"),
			"skin": Color("#F7D5C8"),
			"skin_shadow": Color("#DCAFA8"),
			"eye": Color("#B06B8D"),
			"line": Color("#493947"),
			"outfit": Color("#596E9D"),
			"blush": Color("#E585A2"),
			"mouth": Color("#763C58"),
		}
	)
	var raw_palette = _manifest.get("palette", {})
	if not raw_palette is Dictionary:
		return fallback
	for key_variant in raw_palette:
		var key := str(key_variant)
		if fallback.has(key):
			fallback[key] = Color(str((raw_palette as Dictionary)[key]))
	return fallback


func _contains_any(text: String, terms: Array[String]) -> bool:
	for term in terms:
		if text.contains(term):
			return true
	return false


func _default_manifest_path(target_role_id: String) -> String:
	return "res://assets/characters/%s/portrait_manifest.json" % target_role_id
