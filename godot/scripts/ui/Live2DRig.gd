class_name Live2DRig
extends Control

## Live2D 表现适配器（PresentationArchitecture.md「正式 Live2D 接入」路径的实现）。
## 与 PortraitRig2D 保持同一调用面：set_role / set_expression / set_thinking /
## set_body_state / speak / set_tts_mouth_level / release_tts_mouth / react_to_text /
## get_manifest_summary，外加 expression_changed 信号。
##
## 依赖策略：本脚本【不引用任何 GDCubism 类型】——全部经 ClassDB 动态实例化，
## 因此在未安装 gd_cubism 扩展的机器（CI / 无模型用户）上照常编译，运行时由
## GameWorld 经 create_for_role() 静态工厂决定是否启用，失败自动回退 PortraitRig2D。
##
## 模型与表情映射：res://local_assets/live2d/model_map.json 可覆盖默认值
## （模型名与表情 exp_01..08 → 七种语义表情），公开仓库永不包含模型资产。

signal expression_changed(expression: String)

const EXPRESSIONS := ["neutral", "happy", "worried", "angry", "shy", "tired", "thinking"]
const MODEL_ROOT := "res://local_assets/live2d"
const MOUTH_PARAM_ID := "ParamMouthOpenY"

# 语义表情 → mao_pro exp 编号的默认映射（exp 实际观感待人工调校后写进 model_map.json）
const DEFAULT_EXPRESSION_MAP := {
	"neutral": "",
	"happy": "exp_01",
	"worried": "exp_03",
	"angry": "exp_04",
	"shy": "exp_05",
	"tired": "exp_06",
	"thinking": "exp_07",
}


## gd_cubism 扩展是否已加载（决定 GameWorld 走 Live2D 还是程序化立绘）
## headless（无头诊断/CI）下 dummy 渲染器画不了 Cubism，一律视为不可用
static func is_available() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	return ClassDB.class_exists("GDCubismUserModel")


## 角色 → model3.json 路径；模型缺失或角色非法返回 ""
static func model_path_for_role(role_id: String) -> String:
	var normalized := role_id.strip_edges().to_lower()
	if normalized not in ["ling", "nai"]:
		return ""
	var model_name := str(_role_model_map().get(normalized, ""))
	if model_name.is_empty():
		return ""
	var candidate := "%s/%s/runtime/%s.model3.json" % [MODEL_ROOT, model_name, model_name]
	return candidate if FileAccess.file_exists(candidate) else ""


## 工厂入口：扩展加载且该角色有可用模型 → Live2DRig；否则 null（GameWorld 回退）
static func create_for_role(role_id: String) -> Live2DRig:
	if not is_available():
		return null
	var candidate := model_path_for_role(role_id)
	if candidate.is_empty():
		return null
	var rig := Live2DRig.new()
	rig.role_id = role_id.strip_edges().to_lower()
	rig.model_path = candidate
	return rig


static func _role_model_map() -> Dictionary:
	var map := {"ling": "mao_pro", "nai": "shizuku"}
	var path := MODEL_ROOT + "/model_map.json"
	if FileAccess.file_exists(path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary:
			for key in ["ling", "nai"]:
				var entry: Variant = parsed.get(key, "")
				if entry is String and not (entry as String).is_empty():
					map[key] = entry
				elif entry is Dictionary and not str((entry as Dictionary).get("model", "")).is_empty():
					map[key] = str((entry as Dictionary)["model"])
	return map


var role_id := ""
var model_path := ""

# 渲染结构:Control → SubViewportContainer → SubViewport → 模型。
# v0.9 起 gd_cubism 给部件网格设 z_index=renderOrder(可达上百),直接挂在
# Control 下会穿透后续 UI(实测压住心织面板蒙纱);纹理化后天然被 UI 覆盖,
# 且暂停渲染只需 UPDATE_DISABLED + process_mode——面板/3D 模式下零 GPU 成本。
var _viewport_container: SubViewportContainer
var _viewport: SubViewport
var _active := true

# GDCubismUserModel 与参数对象一律以 Object 动态持有（无静态类型依赖）
var _model: Object = null
var _mouth_param: Object = null
var _target_point: Object = null
var _expression_map: Dictionary = {}
var _applied_expression := ""

var _expression := "neutral"
var _thinking := false
var _body_state: Dictionary = {}
var _speech_remaining := 0.0
var _speech_mouth := 0.0
var _speech_phase := 0.0
var _tts_mouth_level := -1.0


func _ready() -> void:
	clip_contents = true
	_viewport_container = SubViewportContainer.new()
	_viewport_container.stretch = true
	_viewport_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_viewport_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_viewport_container)
	_viewport = SubViewport.new()
	_viewport.transparent_bg = true
	_viewport_container.add_child(_viewport)
	if model_path.is_empty():
		return
	_expression_map = _load_expression_map()
	_build_model()
	resized.connect(_fit_model)


## 挂起/恢复渲染:全屏面板盖在上方或 3D 模式时由 GameWorld 调 false,
## 立绘槽对全年龄内容也随时可关。挂起 = 停止重绘 + 停止模型与 Effect 的 _process。
func set_active(active: bool) -> void:
	if _active == active:
		return
	_active = active
	_update_render_state()


func _update_render_state() -> void:
	if _viewport == null or _viewport_container == null:
		return
	var should_render: bool = _active and is_visible_in_tree()
	_viewport_container.visible = should_render
	_viewport.render_target_update_mode = (
		SubViewport.UPDATE_ALWAYS if should_render else SubViewport.UPDATE_DISABLED
	)
	if _model != null:
		_model.process_mode = (
			Node.PROCESS_MODE_INHERIT if should_render else Node.PROCESS_MODE_DISABLED
		)


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		_update_render_state()


func _build_model() -> void:
	if _model != null:
		_model.queue_free()
		_mouth_param = null
	_model = ClassDB.instantiate("GDCubismUserModel")
	if _model == null:
		return
	_viewport.add_child(_model)
	_model.assets = model_path
	# 呼吸/眨眼/视线：框架自带 Effect，作为模型子节点接入
	for effect_type in ["GDCubismEffectBreath", "GDCubismEffectEyeBlink", "GDCubismEffectTargetPoint"]:
		var effect: Object = ClassDB.instantiate(effect_type)
		if effect != null:
			_model.add_child(effect)
			if effect_type == "GDCubismEffectTargetPoint":
				_target_point = effect
	_model.motion_finished.connect(_on_motion_finished)
	_applied_expression = ""
	_start_idle_motion.call_deferred()
	_fit_model.call_deferred()


func _start_idle_motion() -> void:
	if _model == null:
		return
	var motions: Dictionary = _model.get_motions()
	var group := ""
	for key in motions:
		if String(key).to_lower().contains("idle"):
			group = String(key)
			break
	if group.is_empty() and not motions.is_empty():
		group = String(motions.keys()[0])
	if group.is_empty():
		return
	# start_motion_loop(group, no, priority, loop, loop_fade_in) 循环播放
	if _model.has_method("start_motion_loop"):
		_model.start_motion_loop(group, 0, _model.PRIORITY_FORCE, true, true)
	else:
		_model.start_motion(group, 0, _model.PRIORITY_FORCE)


func _on_motion_finished() -> void:
	var motions: Dictionary = _model.get_motions() if _model != null else {}
	if motions.is_empty():
		return
	var group := ""
	for key in motions:
		if String(key).to_lower().contains("idle"):
			group = String(key)
			break
	if group.is_empty():
		group = String(motions.keys()[0])
	_model.start_motion(group, 0, _model.PRIORITY_FORCE)


func _process(delta: float) -> void:
	if _model == null or not _active or not is_visible_in_tree():
		return
	_update_mouth(delta)
	_follow_mouse()


func _update_mouth(delta: float) -> void:
	var level := 0.0
	if _tts_mouth_level >= 0.0:
		level = _tts_mouth_level
	elif _speech_remaining > 0.0:
		_speech_remaining -= delta
		_speech_phase += delta * 17.0
		# 说话口型：伪随机包络，比纯正弦更像念白开合
		level = 0.28 + 0.62 * absf(0.6 * sin(_speech_phase) + 0.4 * sin(_speech_phase * 2.7 + 1.3))
		if _speech_remaining <= 0.0 and not _thinking:
			set_expression(_expression_from_body_state())
	_mouth_param = _find_parameter(MOUTH_PARAM_ID)
	if _mouth_param != null:
		_mouth_param.value = clampf(level, 0.0, 1.0)


func _follow_mouse() -> void:
	if _target_point == null or _model == null:
		return
	var local := (_model as Node2D).to_local(get_global_mouse_position()) * Vector2(1.0, -1.0)
	var length := local.length()
	_target_point.set_target(local / length if length > 1.0 else Vector2.ZERO)


func _find_parameter(parameter_id: String) -> Object:
	if _model == null:
		return null
	for parameter_variant in _model.get_parameters():
		if str(parameter_variant.id) == parameter_id:
			return parameter_variant
	return null


func _fit_model() -> void:
	if _model == null:
		return
	var info: Dictionary = _model.get_canvas_info()
	if info.is_empty():
		return
	var canvas: Vector2 = info.size_in_pixels
	var longest: float = maxf(canvas.x, canvas.y)
	if longest <= 0.0:
		return
	var fit_scale: float = minf(size.y / canvas.y, size.x / canvas.x) * 0.94
	var node2d := _model as Node2D
	node2d.position = size / 2.0
	node2d.scale = Vector2(fit_scale, fit_scale)


# ── 调用面（与 PortraitRig2D 逐方法对齐）─────────────────────────

func set_role(next_role_id: String, next_manifest_path := "") -> void:
	var normalized := next_role_id.strip_edges().to_lower()
	if normalized not in ["ling", "nai"]:
		return
	var next_path := next_manifest_path.strip_edges()
	var candidate := next_path if not next_path.is_empty() else model_path_for_role(normalized)
	if candidate.is_empty():
		return
	role_id = normalized
	_expression = "neutral"
	_thinking = false
	_speech_remaining = 0.0
	if candidate != model_path or _model == null:
		model_path = candidate
		if is_inside_tree():
			_build_model()
	expression_changed.emit(_expression)


func set_expression(next_expression: String) -> void:
	var normalized := next_expression.strip_edges().to_lower()
	if normalized not in EXPRESSIONS:
		normalized = "neutral"
	if normalized == _expression:
		return
	_expression = normalized
	_apply_expression()
	expression_changed.emit(_expression)


func get_expression() -> String:
	return "thinking" if _thinking else _expression


func set_thinking(active: bool) -> void:
	if active == _thinking:
		return
	_thinking = active
	_apply_expression()


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
		"manifest_path": model_path,
		"external_art": true,
		"layer_count": 0,
		"expression": get_expression(),
		"backend": "live2d",
	}


# ── 内部 ────────────────────────────────────────────────────────

func _apply_expression() -> void:
	var key := "thinking" if _thinking else _expression
	if key == _applied_expression:
		return
	_applied_expression = key
	if _model == null:
		return
	var cubism_expression := str(_expression_map.get(key, ""))
	var available: Array = _model.get_expressions()
	if not cubism_expression.is_empty() and cubism_expression in available:
		_model.start_expression(cubism_expression)
	else:
		_model.stop_expression()


func _expression_from_body_state() -> String:
	var stats_variant: Variant = _body_state.get("stats", _body_state)
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


func _load_expression_map() -> Dictionary:
	var map := DEFAULT_EXPRESSION_MAP.duplicate(true)
	var path := MODEL_ROOT + "/model_map.json"
	if FileAccess.file_exists(path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary:
			var entry: Variant = parsed.get(role_id, {})
			if entry is Dictionary:
				var overrides: Variant = (entry as Dictionary).get("expressions", {})
				if overrides is Dictionary:
					for key in (overrides as Dictionary):
						if str(key) in EXPRESSIONS:
							map[str(key)] = str((overrides as Dictionary)[key])
	return map


func _contains_any(text: String, words: Array) -> bool:
	for word in words:
		if word in text:
			return true
	return false
