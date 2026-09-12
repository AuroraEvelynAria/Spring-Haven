class_name UIBreath
extends RefCounted

## 可复用的"呼吸感"动效工具(视觉评审:动效语言 - 呼吸)。
## 呼吸走 modulate 亮度脉动而非缩放:零几何变化 → 不扰动命中区域/布局,
## 与悬停缩放天然解耦,不会产生边缘 enter/exit 抖动。
## 用法:UIBreath.breathe(control) 一行接入;UIBreath.stop(control) 复位。

const MODULATE_META := "_ui_breath_tween"

static func breathe(control: Control, peak := 0.05, period := 2.8) -> Tween:
	stop(control)
	var bright := Color(1.0 + peak, 1.0 + peak, 1.0 + peak)
	var tween := control.create_tween().set_loops()
	tween.tween_property(control, "modulate", bright, period * 0.5) \
		.set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)
	tween.tween_property(control, "modulate", Color.WHITE, period * 0.5) \
		.set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)
	control.set_meta(MODULATE_META, tween)
	return tween

static func stop(control: Control) -> void:
	if control.has_meta(MODULATE_META):
		var tween: Tween = control.get_meta(MODULATE_META)
		if tween is Tween and tween.is_valid():
			tween.kill()
		control.remove_meta(MODULATE_META)
	control.modulate = Color.WHITE
