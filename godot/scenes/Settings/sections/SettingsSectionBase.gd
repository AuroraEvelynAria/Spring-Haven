extends RefCounted
## 设置面板分节控制器基类（SettingsPanel 六步拆分）。
## 节实例由根脚本常驻持有，控件随类别重建；草稿与脏状态跟随节保存。
## request_rebuild 由根脚本注入，供节内需要整页重建的流程（如旅程切换）回调。
## is_panel_category 由根脚本注入，供节内异步回调判断当前面板类别。
## host 保持动态类型：节在过渡期需要读取根脚本上的跨界状态。

var host = null
var request_rebuild: Callable
var is_panel_category: Callable
var capture_category_draft: Callable
var restore_category_draft: Callable

func prepare(host_control: Control) -> void:
	host = host_control
	_prepare()

func _prepare() -> void:
	pass

func capture_draft() -> Dictionary:
	return {}

func restore_draft(_draft: Dictionary) -> void:
	pass

func has_unsaved_changes() -> bool:
	return false

func reset_draft_state() -> void:
	pass

func reset_for_show(_scope_save_id: String) -> void:
	pass

func release_controls() -> void:
	pass

func handle_scope_change(_active_save_id: String) -> bool:
	return false

func set_status(label: Label, text: String, color: Color) -> void:
	if is_instance_valid(label):
		label.text = text
		label.add_theme_color_override("font_color", color)
