class_name LocalRoomVisual
extends Node3D

signal load_finished(success: bool, resource_path: String)

const LOCAL_ROOM_BAKED_SCENE_PATH := (
	"res://local_assets/living_dining/living_dining_baked.tscn"
)
const LOCAL_ROOM_LIGHTMAP_DATA_PATH := (
	"res://local_assets/living_dining/living_dining_baked_v9.lmbake"
)
const LOCAL_ROOM_MODEL_PATH := (
	"res://local_assets/living_dining/living_dining_optimized.glb"
)

@export var load_local_room_model: bool = true
@export var load_local_room_in_headless: bool = false

var _model_instance: Node3D
var _loading := false
var _progress := 0.0
var _active_resource_path := ""


func _ready() -> void:
	_begin_load.call_deferred()


func is_model_loaded() -> bool:
	return is_instance_valid(_model_instance)


func get_load_progress() -> float:
	return _progress


func get_loaded_resource_path() -> String:
	return _active_resource_path if is_model_loaded() else ""


func is_using_baked_lightmap() -> bool:
	return is_model_loaded() and _active_resource_path == LOCAL_ROOM_BAKED_SCENE_PATH


func _begin_load() -> void:
	if _loading or is_model_loaded() or not load_local_room_model:
		return
	if DisplayServer.get_name() == "headless" and not load_local_room_in_headless:
		return
	_loading = true
	var preferred_path := _preferred_resource_path()
	if preferred_path.is_empty():
		_fail_load("本地客餐厅视觉资源不存在。", LOCAL_ROOM_MODEL_PATH)
		return
	if await _load_resource(preferred_path):
		return
	if preferred_path != LOCAL_ROOM_MODEL_PATH and await _load_resource(LOCAL_ROOM_MODEL_PATH):
		return
	_fail_load("本地客餐厅视觉资源均加载失败。", preferred_path)


func _preferred_resource_path() -> String:
	if (
		FileAccess.file_exists(LOCAL_ROOM_BAKED_SCENE_PATH)
		and FileAccess.file_exists(LOCAL_ROOM_LIGHTMAP_DATA_PATH)
		and ResourceLoader.exists(LOCAL_ROOM_BAKED_SCENE_PATH, "PackedScene")
		and ResourceLoader.exists(LOCAL_ROOM_LIGHTMAP_DATA_PATH, "LightmapGIData")
	):
		return LOCAL_ROOM_BAKED_SCENE_PATH
	if (
		FileAccess.file_exists(LOCAL_ROOM_MODEL_PATH)
		and ResourceLoader.exists(LOCAL_ROOM_MODEL_PATH, "PackedScene")
	):
		return LOCAL_ROOM_MODEL_PATH
	return ""


func _load_resource(resource_path: String) -> bool:
	if (
		not FileAccess.file_exists(resource_path)
		or not ResourceLoader.exists(resource_path, "PackedScene")
	):
		return false
	_progress = 0.0
	var request_error := ResourceLoader.load_threaded_request(
		resource_path,
		"PackedScene",
		false
	)
	if request_error != OK:
		push_warning("本地客餐厅加载请求失败：%s" % error_string(request_error))
		return false

	var progress: Array = []
	while is_inside_tree():
		var status := ResourceLoader.load_threaded_get_status(
			resource_path,
			progress
		)
		if not progress.is_empty():
			_progress = clampf(float(progress[0]), 0.0, 1.0)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			break
		if status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			push_warning("本地客餐厅资源无效：%s" % resource_path)
			return false
		await get_tree().process_frame
	if not is_inside_tree():
		return false

	var packed := ResourceLoader.load_threaded_get(resource_path) as PackedScene
	if packed == null:
		push_warning("本地客餐厅资源不是 PackedScene：%s" % resource_path)
		return false
	var instance := packed.instantiate()
	if not instance is Node3D:
		instance.queue_free()
		push_warning("本地客餐厅根节点不是 Node3D：%s" % resource_path)
		return false
	_model_instance = instance as Node3D
	_model_instance.name = (
		"LivingDiningBaked"
		if resource_path == LOCAL_ROOM_BAKED_SCENE_PATH
		else "LivingDiningOptimized"
	)
	add_child(_model_instance)
	_active_resource_path = resource_path
	_loading = false
	_progress = 1.0
	load_finished.emit(true, resource_path)
	return true


func _fail_load(message: String, resource_path: String) -> void:
	_loading = false
	_progress = 0.0
	_active_resource_path = ""
	push_warning(message)
	load_finished.emit(false, resource_path)
