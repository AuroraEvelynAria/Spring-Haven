@tool
extends EditorExportPlugin

const LOCAL_ASSET_PREFIX := "res://local_assets/"


func _get_name() -> String:
	return "SpringHeavenLocalAssetReleaseGuard"


func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if path.begins_with(LOCAL_ASSET_PREFIX):
		skip()
