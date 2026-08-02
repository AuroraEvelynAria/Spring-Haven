extends SceneTree

const BAKED_SCENE_PATH := (
	"res://local_assets/living_dining/living_dining_baked.tscn"
)
const LIGHTMAP_DATA_PATH := (
	"res://local_assets/living_dining/living_dining_baked_v9.lmbake"
)
const LIGHTMAP_TEXTURE_PATH := (
	"res://local_assets/living_dining/living_dining_baked_v9.exr"
)
var _checks := 0
var _failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_expect(ResourceLoader.exists(BAKED_SCENE_PATH, "PackedScene"), "烘焙场景不可加载")
	_expect(ResourceLoader.exists(LIGHTMAP_DATA_PATH, "LightmapGIData"), "LightmapGIData 不可加载")
	_expect(FileAccess.file_exists(LIGHTMAP_TEXTURE_PATH), "Lightmap EXR 不存在")
	if not _failures.is_empty():
		_finish()
		return

	var scene_text := FileAccess.get_file_as_string(BAKED_SCENE_PATH)
	_expect(scene_text.contains(LIGHTMAP_DATA_PATH), "烘焙场景没有引用 LightmapGIData")
	_expect(scene_text.contains("light_data = ExtResource"), "LightmapGI 节点没有绑定缓存")
	var dimensions := _read_exr_dimensions(LIGHTMAP_TEXTURE_PATH)
	var report := {
		"layer_width": int(dimensions.x),
		"stacked_height": int(dimensions.y),
		"atlas_layers": 5,
		"texture_slices": 5,
		"data_bytes": FileAccess.get_file_as_bytes(LIGHTMAP_DATA_PATH).size(),
		"texture_bytes": FileAccess.get_file_as_bytes(LIGHTMAP_TEXTURE_PATH).size(),
	}
	_expect(report.layer_width >= 512, "Lightmap 单层宽度低于 512")
	_expect(report.stacked_height >= 2_560, "完整房间 Lightmap 切片总高度低于 2560")
	_expect(report.data_bytes >= 75_000, "LightmapGIData 体积异常")
	_expect(report.texture_bytes >= 3_500_000, "完整房间 Lightmap 纹理体积异常")
	print("LIGHTMAP_BAKE_REPORT=" + JSON.stringify(report))

	_finish()


func _read_exr_dimensions(resource_path: String) -> Vector2i:
	var file := FileAccess.open(resource_path, FileAccess.READ)
	if file == null or file.get_length() < 16:
		return Vector2i.ZERO
	if file.get_32() != 0x01312F76:
		return Vector2i.ZERO
	file.get_32()
	while file.get_position() < file.get_length():
		var attribute_name := _read_c_string(file)
		if attribute_name.is_empty():
			break
		var attribute_type := _read_c_string(file)
		var attribute_size := int(file.get_32())
		if attribute_name == "dataWindow" and attribute_type == "box2i" and attribute_size == 16:
			var minimum_x := int(file.get_32())
			var minimum_y := int(file.get_32())
			var maximum_x := int(file.get_32())
			var maximum_y := int(file.get_32())
			return Vector2i(maximum_x - minimum_x + 1, maximum_y - minimum_y + 1)
		file.seek(file.get_position() + attribute_size)
	return Vector2i.ZERO


func _read_c_string(file: FileAccess) -> String:
	var bytes := PackedByteArray()
	while file.get_position() < file.get_length():
		var value := file.get_8()
		if value == 0:
			break
		bytes.append(value)
	return bytes.get_string_from_ascii()


func _finish() -> void:
	if _failures.is_empty():
		print("LIGHTMAP_BAKE_CHECK passed=", _checks)
		quit(0)
		return
	for failure in _failures:
		printerr("LIGHTMAP_BAKE_CHECK failure=", failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
