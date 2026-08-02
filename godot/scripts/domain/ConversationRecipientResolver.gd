class_name ConversationRecipientResolver
extends RefCounted

const TEXT_SANITIZER := preload("res://scripts/domain/TextSanitizer.gd")
const ROUTE_PROTOCOL := "spring_heaven.conversation_route.v1"

const ROLE_ALIASES := {
	"ling": ["小玲", "铃音", "鈴音", "春日铃音", "春日鈴音"],
	"nai": ["小奈", "雪奈", "白瀬雪奈", "白濑雪奈"],
}

const DUAL_MARKERS := [
	"你们都回答", "你们两个都回答", "两个人都回答", "兩個人都回答",
	"你们都说说", "你们两个都说说", "两个人都说说", "一起回答",
	"小玲和小奈都", "小奈和小玲都",
]

const DIRECTIVE_TEMPLATES := [
	"@%s", "%s来回答", "%s來回答", "让%s回答", "讓%s回答",
	"请%s回答", "請%s回答", "由%s回答", "问问%s", "問問%s", "想问%s", "想問%s",
]

const NAMED_DELEGATION_TEMPLATES := [
	"%s去问%s", "%s去问问%s", "%s问问%s", "%s问一下%s",
	"让%s去问%s", "讓%s去問%s", "让%s问问%s", "讓%s問問%s",
	"请%s去问%s", "請%s去問%s", "叫%s去问%s", "叫%s去問%s",
	"%s去跟%s商量", "%s跟%s商量", "让%s跟%s商量", "讓%s跟%s商量",
]

const SELECTED_DELEGATION_TEMPLATES := [
	"你去问%s", "你去問%s", "你去问问%s", "你去問問%s",
	"你问问%s", "你問問%s", "你帮我问%s", "你幫我問%s",
	"你帮我问问%s", "你幫我問問%s", "帮我问%s", "幫我問%s",
	"帮我问问%s", "幫我問問%s", "替我问%s", "替我問%s",
	"让她去问%s", "讓她去問%s", "让她问问%s", "讓她問問%s",
	"叫她去问%s", "叫她去問%s", "你去跟%s商量", "你跟%s商量",
	"让她跟%s商量", "讓她跟%s商量",
]

const DELEGATION_NEGATIONS := [
	"别去问", "別去問", "不要去问", "不要去問", "不用去问", "不用去問",
	"别让她问", "別讓她問", "不要让她问", "不要讓她問",
]

static func resolve(text: String, selected_role: String, conversational_role := "") -> Dictionary:
	var fallback := selected_role if ROLE_ALIASES.has(selected_role) else "ling"
	var context_role := conversational_role if ROLE_ALIASES.has(conversational_role) else ""
	var normalized := TEXT_SANITIZER.strip_nul(text).strip_edges()
	if normalized.is_empty():
		return _result([fallback], "selected")

	for marker in DUAL_MARKERS:
		if normalized.findn(marker) >= 0:
			return _result([fallback, _other_role(fallback)], "explicit_dual")

	var compact := _compact_for_routing(normalized)
	var delegation := _resolve_delegation(compact, fallback, context_role)
	if not delegation.is_empty():
		return delegation

	for role_variant in ROLE_ALIASES:
		var role := str(role_variant)
		for alias_variant in ROLE_ALIASES[role]:
			var alias := str(alias_variant)
			for template in DIRECTIVE_TEMPLATES:
				if normalized.findn(str(template) % alias) >= 0:
					return _result([role], "explicit_directive")

	for role_variant in ROLE_ALIASES:
		var role := str(role_variant)
		for alias_variant in ROLE_ALIASES[role]:
			if normalized.begins_with(str(alias_variant)):
				return _result([role], "leading_name")

	var mentioned: Array[String] = []
	for role_variant in ROLE_ALIASES:
		var role := str(role_variant)
		for alias_variant in ROLE_ALIASES[role]:
			if normalized.findn(str(alias_variant)) >= 0:
				mentioned.append(role)
				break
	if mentioned.size() == 1:
		return _result([mentioned[0]], "single_mention")
	return _result([fallback], "selected")

static func _result(roles: Array, reason: String, route: Dictionary = {}) -> Dictionary:
	var normalized_roles: Array[String] = []
	for role_variant in roles:
		var role := str(role_variant)
		if ROLE_ALIASES.has(role) and role not in normalized_roles:
			normalized_roles.append(role)
	var result := {
		"roles": normalized_roles,
		"reason": reason,
		"audience_roles": ["ling", "nai"],
		"visibility": "shared_room",
	}
	if not route.is_empty():
		result["route"] = route.duplicate(true)
	return result

static func _resolve_delegation(
	text: String,
	selected_role: String,
	conversational_role: String
) -> Dictionary:
	for negation in DELEGATION_NEGATIONS:
		if text.findn(negation) >= 0:
			return _result([selected_role], "delegation_negated")
	var non_executing := (
		"了吗" in text
		or "了嗎" in text
		or "过吗" in text
		or "過嗎" in text
	)
	for origin_variant in ROLE_ALIASES:
		var origin := str(origin_variant)
		for target_variant in ROLE_ALIASES:
			var target := str(target_variant)
			if origin == target:
				continue
			for origin_alias_variant in ROLE_ALIASES[origin]:
				var origin_alias := str(origin_alias_variant)
				for target_alias_variant in ROLE_ALIASES[target]:
					var target_alias := str(target_alias_variant)
					for template in NAMED_DELEGATION_TEMPLATES:
						if text.findn(str(template) % [origin_alias, target_alias]) >= 0:
							if non_executing:
								return _result([origin], "delegation_question")
							return _delegation_result(origin, target, "named_delegation")
	for target_variant in ROLE_ALIASES:
		var target := str(target_variant)
		var origin := selected_role
		if target == origin:
			if ROLE_ALIASES.has(conversational_role) and conversational_role != target:
				origin = conversational_role
			else:
				continue
		for target_alias_variant in ROLE_ALIASES[target]:
			var target_alias := str(target_alias_variant)
			for template in SELECTED_DELEGATION_TEMPLATES:
				if text.findn(str(template) % target_alias) >= 0:
					if non_executing:
						return _result([origin], "delegation_question")
					return _delegation_result(origin, target, "selected_delegation")
	return {}

static func _delegation_result(origin_role: String, target_role: String, reason: String) -> Dictionary:
	return _result([origin_role, target_role], reason, {
		"protocol": ROUTE_PROTOCOL,
		"kind": "delegate_question",
		"origin_role": origin_role,
		"target_role": target_role,
	})

static func _compact_for_routing(text: String) -> String:
	var compact := text
	for separator in [" ", "\t", "\r", "\n", "，", ",", "。", "！", "!"]:
		compact = compact.replace(str(separator), "")
	return compact

static func _other_role(role: String) -> String:
	return "nai" if role == "ling" else "ling"
