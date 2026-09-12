class_name UIBreath
extends RefCounted

## 可复用的"呼吸感"动效工具(ADR 视觉评审:动效语言 - 呼吸)。
## 用法:UIBreath.start(control) 一行接入;UIBreath.stop(control) 停止并复位。
## 原理:以控件中心为轴的循环缩放脉冲,幅度/周期可调;默认克制
## (1.5% 幅度、2.6 秒周期),配合 hover 缩放时先 stop 避免争抢。

const SCALE_META := "_ui_breath_tween"

static func start(control: Control, amplitude := 0.015, period := 2.6) -> Tween:
	stop(control)
	if control.size.x <= 0.0 or control.size.y <= 0.0:
		return null
	control.pivot_offset = control.size / 2.0
	var tween := control.create_tween().set_loops()
	tween.tween_property(
		control, "scale", Vector2.ONE * (1.0 + amplitude), period * 0.5
	).set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)
	tween.tween_property(
		control, "scale", Vector2.ONE, period * 0.5
	).set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)
	control.set_meta(SCALE_META, tween)
	return tween

static func stop(control: Control) -> void:
	if control.has_meta(SCALE_META):
		var tween: Tween = control.get_meta(SCALE_META)
		if tween is Tween and tween.is_valid():
			tween.kill()
		control.remove_meta(SCALE_META)
	control.scale = Vector2.ONE
