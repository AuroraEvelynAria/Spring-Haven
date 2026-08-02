extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	await process_frame
	var client := root.get_node_or_null("CompanionCore")
	if client == null:
		printerr("PROVIDER_SETTINGS_CONNECTION_CHECK client_missing")
		quit(2)
		return
	var result: Dictionary = await client.get_provider_status()
	if not bool(result.get("ok", false)):
		printerr("PROVIDER_SETTINGS_CONNECTION_CHECK request_failed")
		quit(3)
		return
	var data = result.get("data", {})
	if not data is Dictionary:
		printerr("PROVIDER_SETTINGS_CONNECTION_CHECK invalid_payload")
		quit(4)
		return
	if (data as Dictionary).has("api_key"):
		printerr("PROVIDER_SETTINGS_CONNECTION_CHECK key_was_exposed")
		quit(5)
		return
	var profiles = (data as Dictionary).get("profiles", {})
	if not profiles is Dictionary or (profiles as Dictionary).size() != 4:
		printerr("PROVIDER_SETTINGS_CONNECTION_CHECK capability_profiles_missing")
		quit(8)
		return
	for capability in ["chat", "vision", "embedding", "rerank"]:
		var profile = (profiles as Dictionary).get(capability, {})
		if not profile is Dictionary or (profile as Dictionary).has("api_key"):
			printerr("PROVIDER_SETTINGS_CONNECTION_CHECK capability_not_redacted")
			quit(9)
			return
	var fallbacks = (data as Dictionary).get("fallbacks", {})
	if not fallbacks is Dictionary or (fallbacks as Dictionary).size() != 4:
		printerr("PROVIDER_SETTINGS_CONNECTION_CHECK fallback_catalog_missing")
		quit(20)
		return
	for capability in ["chat", "vision", "embedding", "rerank"]:
		if not (fallbacks as Dictionary).get(capability, []) is Array:
			printerr("PROVIDER_SETTINGS_CONNECTION_CHECK fallback_catalog_invalid")
			quit(21)
			return
	var runtime = (data as Dictionary).get("runtime", {})
	var circuits = (runtime as Dictionary).get("circuits", {}) if runtime is Dictionary else {}
	if not circuits is Dictionary or (circuits as Dictionary).size() != 4:
		printerr("PROVIDER_SETTINGS_CONNECTION_CHECK failover_runtime_missing")
		quit(22)
		return
	var rag = (data as Dictionary).get("rag", {})
	if not rag is Dictionary or not (rag as Dictionary).has("chunk_size"):
		printerr("PROVIDER_SETTINGS_CONNECTION_CHECK rag_settings_missing")
		quit(10)
		return
	var network_proxy = (data as Dictionary).get("network_proxy", {})
	if not network_proxy is Dictionary or str((network_proxy as Dictionary).get("mode", "")).is_empty():
		printerr("PROVIDER_SETTINGS_CONNECTION_CHECK network_proxy_missing")
		quit(19)
		return
	if str((data as Dictionary).get("base_url", "")).is_empty():
		printerr("PROVIDER_SETTINGS_CONNECTION_CHECK base_url_missing")
		quit(6)
		return
	if str((data as Dictionary).get("model", "")).is_empty():
		printerr("PROVIDER_SETTINGS_CONNECTION_CHECK model_missing")
		quit(7)
		return
	var rag_status: Dictionary = await client.get_rag_status()
	if not bool(rag_status.get("ok", false)):
		printerr("PROVIDER_SETTINGS_CONNECTION_CHECK rag_status_failed")
		quit(11)
		return
	var document_id := "diagnostic-%d" % int(Time.get_unix_time_from_system() * 1000.0)
	var created: Dictionary = await client.put_rag_document({
		"document_id": document_id,
		"title": "Godot 联调临时知识",
		"text": "这是设置页联调创建的临时文档，测试完成后会立即删除。",
		"scope": "ling",
	})
	if not bool(created.get("ok", false)):
		printerr("PROVIDER_SETTINGS_CONNECTION_CHECK rag_create_failed")
		quit(12)
		return
	var fetched: Dictionary = await client.get_rag_document(document_id)
	var listed: Dictionary = await client.list_rag_documents(500)
	if not bool(fetched.get("ok", false)) or not bool(listed.get("ok", false)):
		await client.delete_rag_document(document_id)
		printerr("PROVIDER_SETTINGS_CONNECTION_CHECK rag_read_failed")
		quit(13)
		return
	var fetched_data = fetched.get("data", {})
	var fetched_document = (fetched_data as Dictionary).get("document", {}) if fetched_data is Dictionary else {}
	if not fetched_document is Dictionary or not (fetched_document as Dictionary).has("text"):
		await client.delete_rag_document(document_id)
		printerr("PROVIDER_SETTINGS_CONNECTION_CHECK rag_content_missing")
		quit(14)
		return
	var deleted: Dictionary = await client.delete_rag_document(document_id)
	if not bool(deleted.get("ok", false)):
		printerr("PROVIDER_SETTINGS_CONNECTION_CHECK rag_cleanup_failed")
		quit(15)
		return
	var file_import: Dictionary = await client.import_rag_file(
		"godot-diagnostic.md",
		"Godot 文件导入联调临时内容。".to_utf8_buffer(),
		"Godot 文件导入临时文档",
		"ling"
	)
	if not bool(file_import.get("ok", false)):
		printerr("PROVIDER_SETTINGS_CONNECTION_CHECK rag_file_import_failed")
		quit(16)
		return
	var import_data = file_import.get("data", {})
	var imported_document = (import_data as Dictionary).get("document", {}) if import_data is Dictionary else {}
	var imported_id := str((imported_document as Dictionary).get("document_id", "")) if imported_document is Dictionary else ""
	if imported_id.is_empty() or str((imported_document as Dictionary).get("scope", "")) != "ling":
		printerr("PROVIDER_SETTINGS_CONNECTION_CHECK rag_import_id_missing")
		quit(17)
		return
	var import_deleted: Dictionary = await client.delete_rag_document(imported_id)
	if not bool(import_deleted.get("ok", false)):
		printerr("PROVIDER_SETTINGS_CONNECTION_CHECK rag_import_cleanup_failed")
		quit(18)
		return
	print("PROVIDER_SETTINGS_CONNECTION_CHECK=PASS redacted=true")
	quit(0)
