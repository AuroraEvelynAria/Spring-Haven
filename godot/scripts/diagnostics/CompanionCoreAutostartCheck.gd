extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	await process_frame
	var client := root.get_node_or_null("CompanionCore")
	_expect(client != null, "Companion Core 客户端 Autoload 不存在")
	if client == null:
		return
	_expect(bool(client.call("_is_loopback_core_url")), "默认 Companion Core 地址不是回环地址")
	var launch = client.call("_local_core_launch_spec")
	_expect(launch is Dictionary and not (launch as Dictionary).is_empty(), "没有找到本地 Core 启动规格")
	if launch is Dictionary:
		var executable := str((launch as Dictionary).get("executable", ""))
		var arguments = (launch as Dictionary).get("arguments", PackedStringArray())
		_expect(FileAccess.file_exists(executable), "Core 启动程序不存在")
		_expect(arguments is PackedStringArray, "Core 启动参数类型错误")
		var rendered := " ".join(arguments as PackedStringArray) if arguments is PackedStringArray else ""
		_expect("--config" in rendered and "--roles" in rendered, "Core 启动参数缺少配置或角色注册表")
		_expect("--log-file" in rendered, "Core 启动参数缺少轮转日志路径")
		_expect("X-API-Key" not in rendered and "Bearer" not in rendered, "Core 启动参数泄露凭据")
	var managed: Dictionary = client.call("get_managed_core_status")
	_expect(not bool(managed.get("owned", false)), "诊断错误接管了用户现有 Core 进程")
	print("COMPANION_CORE_AUTOSTART_CHECK=PASS")
	quit(0)

func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	push_error(message)
	quit(1)
