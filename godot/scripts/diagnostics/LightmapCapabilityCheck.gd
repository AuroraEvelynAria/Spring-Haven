extends SceneTree


func _initialize() -> void:
	var report := {
		"methods": [],
		"properties": [],
		"data_methods": [],
		"mesh_properties": [],
		"mesh_methods": [],
	}
	for method in ClassDB.class_get_method_list("LightmapGI", true):
		var method_name := str(method.get("name", ""))
		if method_name.to_lower().contains("bake") or method_name.to_lower().contains("data"):
			report.methods.append(method)
	for property in ClassDB.class_get_property_list("LightmapGI", true):
		report.properties.append(property)
	for method in ClassDB.class_get_method_list("LightmapGIData", true):
		var data_method_name := str(method.get("name", ""))
		if (
			data_method_name.to_lower().contains("light")
			or data_method_name.to_lower().contains("texture")
			or data_method_name.to_lower().contains("user")
		):
			report.data_methods.append(method)
	for property in ClassDB.class_get_property_list("ArrayMesh", true):
		if str(property.get("name", "")).to_lower().contains("lightmap"):
			report.mesh_properties.append(property)
	for method in ClassDB.class_get_method_list("ArrayMesh", true):
		if str(method.get("name", "")).to_lower().contains("lightmap"):
			report.mesh_methods.append(method)
	var instance := LightmapGI.new()
	var defaults := {}
	for property in report.properties:
		var property_name := str(property.get("name", ""))
		if property_name.contains("/") or property_name in ["script"]:
			continue
		defaults[property_name] = instance.get(property_name)
	report["defaults"] = defaults
	print(
		"LIGHTMAP_MESH_CAPABILITY="
		+ JSON.stringify({"properties": report.mesh_properties, "methods": report.mesh_methods})
	)
	print("LIGHTMAP_CAPABILITY=" + JSON.stringify(report))
	quit(0)
