extends RefCounted
## 对话管线纯逻辑（#19 第一步）：历史检索、共享转写构建、请求状态装配、收件人裁决。
## 不持有 UI 引用、不访问 autoload；运行时输入（角色表、正文状态）全部经参数注入，
## 便于脱离场景独立测试。

const TEXT_SANITIZER := preload("res://scripts/domain/TextSanitizer.gd")
const RECIPIENT_RESOLVER := preload("res://scripts/domain/ConversationRecipientResolver.gd")


static func find_entry(history: Array, message_id: String) -> Dictionary:
	for index in range(history.size() - 1, -1, -1):
		var entry: Dictionary = history[index]
		if str(entry.get("id", "")) == message_id:
			return entry
	return {}


static func latest_ai_speaker_role(history: Array, role_data: Dictionary) -> String:
	for index in range(history.size() - 1, -1, -1):
		var entry: Dictionary = history[index]
		if str(entry.get("sender", "")) != "ai" or str(entry.get("status", "sent")) != "sent":
			continue
		var role := str(entry.get("role", ""))
		if role_data.has(role):
			return role
	return ""


static func resolve_request_role(entry: Dictionary, role_data: Dictionary, fallback_role: String) -> String:
	var role := str(entry.get("target_role", entry.get("role", fallback_role)))
	return role if role_data.has(role) else fallback_role


static func entry_reply_roles(entry: Dictionary, role_data: Dictionary, fallback_role: String) -> Array[String]:
	var result: Array[String] = []
	var raw_roles = entry.get("target_roles", [])
	if raw_roles is Array:
		for role_variant in raw_roles:
			var role := str(role_variant)
			if role_data.has(role) and role not in result:
				result.append(role)
	if result.is_empty():
		var fallback := resolve_request_role(entry, role_data, fallback_role)
		if role_data.has(fallback):
			result.append(fallback)
	return result


static func entry_request_state(
	entry: Dictionary,
	role_data: Dictionary,
	fallback_role: String,
	visibility_protocol: String,
	body_state_resolver: Callable = Callable()
) -> Dictionary:
	var state_variant = entry.get("state", {})
	var state: Dictionary = state_variant.duplicate(true) if state_variant is Dictionary else {}
	var role := resolve_request_role(entry, role_data, fallback_role)
	if role_data.has(role) and body_state_resolver.is_valid():
		state["body_state"] = body_state_resolver.call(role)
	var source_message_id := str(entry.get("id", "")).strip_edges()
	if not source_message_id.is_empty():
		state["source_message_id"] = source_message_id
	var audience_roles: Array[String] = []
	var audience_variant = entry.get("audience_roles", ["ling", "nai"])
	if audience_variant is Array:
		for audience_variant_role in audience_variant:
			var audience_role := str(audience_variant_role)
			if role_data.has(audience_role) and audience_role not in audience_roles:
				audience_roles.append(audience_role)
	if audience_roles.is_empty():
		audience_roles.assign(["ling", "nai"])
	state["conversation_visibility"] = {
		"protocol": visibility_protocol,
		"mode": "shared_room",
		"audience_roles": audience_roles,
		"responder_role": role,
		"parenthetical_content_visible": true,
	}
	var route_variant = entry.get("conversation_route", {})
	if route_variant is Dictionary and not route_variant.is_empty():
		var route: Dictionary = (route_variant as Dictionary).duplicate(true)
		var origin_role := str(route.get("origin_role", ""))
		var target_role := str(route.get("target_role", ""))
		if role == origin_role:
			route["turn_role"] = role
			route["turn_index"] = 0
			state["conversation_route"] = route
		elif role == target_role:
			route["turn_role"] = role
			route["turn_index"] = 1
			state["conversation_route"] = route
	var local_effect_variant = entry.get("local_effect", {})
	var local_effects_variant = entry.get("local_effects_by_role", {})
	if local_effects_variant is Dictionary and (local_effects_variant as Dictionary).has(role):
		local_effect_variant = (local_effects_variant as Dictionary).get(role, {})
	if local_effect_variant is Dictionary and not local_effect_variant.is_empty():
		state["local_effect"] = (local_effect_variant as Dictionary).duplicate(true)
	return state


static func build_shared_history(
	history: Array,
	role_data: Dictionary,
	excluded_message_id := "",
	limit := 24
) -> Array[Dictionary]:
	var transcript: Array[Dictionary] = []
	var used_characters := 0
	for index in range(history.size() - 1, -1, -1):
		var item: Dictionary = history[index]
		if str(item.get("id", "")) == excluded_message_id:
			continue
		if str(item.get("status", "sent")) != "sent":
			continue
		var sender := str(item.get("sender", ""))
		if sender not in ["user", "ai"]:
			continue
		var history_role := str(item.get("role", ""))
		var speaker := "主人"
		if sender == "ai":
			if not role_data.has(history_role):
				continue
			speaker = str((role_data[history_role] as Dictionary).name)
		var history_text := TEXT_SANITIZER.strip_nul(str(item.get("text", ""))).strip_edges()
		if history_text.is_empty():
			continue
		if history_text.length() > 3000:
			history_text = history_text.left(3000)
		var history_event_type := str(item.get("event_type", "chat"))
		if history_event_type not in ["chat", "action"]:
			history_event_type = "chat"
		var entry := {
			"id": str(item.get("id", "")).left(128),
			"sender": sender,
			"speaker": speaker,
			"text": history_text,
			"event_type": history_event_type,
			"action": str(item.get("action", "")).left(64),
			"created_at": int(item.get("created_at", 0))
		}
		var audience_roles: Array[String] = []
		var audience_variant = item.get("audience_roles", ["ling", "nai"])
		if audience_variant is Array:
			for audience_role_variant in audience_variant:
				var audience_role := str(audience_role_variant)
				if role_data.has(audience_role) and audience_role not in audience_roles:
					audience_roles.append(audience_role)
		if audience_roles.is_empty():
			audience_roles.assign(["ling", "nai"])
		entry["audience_roles"] = audience_roles
		if sender == "ai":
			entry["role_id"] = history_role
			var ai_target_role := str(item.get("target_role", ""))
			if role_data.has(ai_target_role):
				entry["target_role"] = ai_target_role
		else:
			entry["role"] = "user"
			# Legacy saves may not have target_role. Omit this optional field unless valid.
			var legacy_target_role := str(item.get("target_role", ""))
			if role_data.has(legacy_target_role):
				entry["target_role"] = legacy_target_role
		var entry_size := JSON.stringify(entry).length()
		if transcript.size() >= limit or used_characters + entry_size > 6000:
			break
		transcript.push_front(entry)
		used_characters += entry_size
	return transcript


static func message_mentions_both_roles(text: String) -> bool:
	for role in ["ling", "nai"]:
		var mentioned := false
		for alias_variant in RECIPIENT_RESOLVER.ROLE_ALIASES[role]:
			if text.findn(str(alias_variant)) >= 0:
				mentioned = true
				break
		if not mentioned:
			return false
	return true
