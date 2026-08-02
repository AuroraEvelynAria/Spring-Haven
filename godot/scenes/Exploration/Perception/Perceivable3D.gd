class_name Perceivable3D
extends Node

@export var entity_id := "object"
@export var display_name := "物体"
@export_multiline var description := ""
@export var perception_transparent := false
@export var available_actions: Array[String] = []
@export_category("容器状态")
@export var content_type := ""
@export_range(0.0, 1.0, 0.01) var fill_ratio := 0.0
@export var temperature := "常温"

func get_perception_snapshot(_observer: Node3D = null) -> Dictionary:
	var snapshot := {
		"entity_id": entity_id.left(64),
		"name": display_name.left(64),
		"description": description.left(240),
		"transparent": perception_transparent,
		"available_actions": available_actions.duplicate(),
	}
	if not content_type.strip_edges().is_empty():
		snapshot["contents"] = {
			"type": content_type.left(64),
			"fill_ratio": snappedf(fill_ratio, 0.01),
			"level": _fill_level(fill_ratio),
			"temperature": temperature.left(64),
		}
	return snapshot

func _fill_level(value: float) -> String:
	if value <= 0.02:
		return "空"
	if value < 0.25:
		return "只有一点"
	if value < 0.60:
		return "少量"
	if value < 0.90:
		return "大半"
	return "接近满杯"
