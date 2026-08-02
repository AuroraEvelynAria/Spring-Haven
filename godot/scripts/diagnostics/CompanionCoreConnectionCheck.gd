extends SceneTree

const TIMEOUT_SECONDS := 12.0

var _client: Node
var _last_health_message := ""

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	await process_frame
	_client = root.get_node_or_null("CompanionCore")
	if _client == null:
		printerr("COMPANION_CORE_CHECK client_autoload_missing")
		quit(2)
		return
	if not _client.has_credentials():
		printerr("COMPANION_CORE_CHECK core_key_missing")
		quit(2)
		return
	_client.health_changed.connect(_on_health_changed)
	_client.connect_to_core()
	var started_at := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_at < int(TIMEOUT_SECONDS * 1000.0):
		if _client.is_active():
			print(
				"COMPANION_CORE_CHECK backend=", _client.get_backend_name(),
				" url=", _client.get_base_url(),
				" authenticated=true"
			)
			quit(0)
			return
		await create_timer(0.05).timeout
	printerr("COMPANION_CORE_CHECK timeout message=", _last_health_message)
	quit(3)

func _on_health_changed(_active: bool, message: String) -> void:
	_last_health_message = message
