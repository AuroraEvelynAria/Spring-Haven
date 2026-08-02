extends SceneTree

const FORBIDDEN_PATHS := [
	"res://local_assets/ling_placeholder/ling_placeholder.glb",
	"res://local_assets/living_dining/living_dining_optimized.glb",
]


func _initialize() -> void:
	var leaked: Array[String] = []
	for path in FORBIDDEN_PATHS:
		if FileAccess.file_exists(path) or ResourceLoader.exists(path):
			leaked.append(path)
	if leaked.is_empty():
		print("PCK_LOCAL_ASSET_EXCLUSION_CHECK=PASS")
		quit(0)
	else:
		push_error("Local-only assets leaked into PCK: " + ", ".join(leaked))
		print("PCK_LOCAL_ASSET_EXCLUSION_CHECK=FAIL")
		quit(1)
