extends SceneTree

const RESOLVER := preload("res://scripts/domain/ConversationRecipientResolver.gd")

var _checks := 0
var _failures: Array[String] = []

func _initialize() -> void:
	_expect_roles("小奈知道小玲是自己的老婆吧", "ling", ["nai"])
	_expect_roles("小玲来回答一下小奈的问题", "nai", ["ling"])
	_expect_roles("小玲，你觉得小奈可爱吗", "nai", ["ling"])
	_expect_roles("我今天很想小奈", "ling", ["nai"])
	_expect_roles("你们都回答一下", "nai", ["nai", "ling"])
	_expect_roles("你们今天怎么样", "nai", ["nai"])
	_expect_roles("小玲和小奈今天都很可爱", "ling", ["ling"])
	_expect_roles("（我今天有点累，括号内容也让两个人看见）", "ling", ["ling"])
	_expect_delegation("你去问小奈吧，晚饭吃什么", "ling", "ling", "nai")
	_expect_delegation("你去问问小奈想吃什么？", "ling", "ling", "nai")
	_expect_delegation("让她去问小奈，早餐想吃什么", "ling", "ling", "nai")
	_expect_delegation("让小玲问问小奈午饭想吃什么", "nai", "ling", "nai")
	_expect_delegation("小奈去问小玲夜宵吃什么", "ling", "nai", "ling")
	_expect_delegation("你帮我问问小奈明天想吃什么", "ling", "ling", "nai")
	_expect_delegation("你去跟小奈商量一下晚饭", "ling", "ling", "nai")
	_expect_roles("问问小奈想吃什么", "ling", ["nai"])
	_expect_roles("别去问小奈", "ling", ["ling"])
	_expect_roles("你去问小奈了吗？", "ling", ["ling"])
	_expect_roles("你去问小奈想吃什么", "nai", ["nai"])
	_expect_context_delegation("让她去问小奈", "nai", "ling", "ling", "nai")
	_expect_context_delegation("你去问问小奈想吃什么？", "nai", "ling", "ling", "nai")
	_expect_context_delegation("你去问小奈", "nai", "ling", "ling", "nai")
	_expect_context_roles("你去问小奈", "ling", "nai", ["ling", "nai"])
	for _round in 100:
		_expect_delegation("让她去问小奈，今晚吃什么", "ling", "ling", "nai")
	if _failures.is_empty():
		print("RECIPIENT_RESOLVER_CHECK passed=", _checks)
		quit(0)
		return
	for failure in _failures:
		printerr("RECIPIENT_RESOLVER_CHECK failure=", failure)
	quit(1)

func _expect_roles(text: String, selected_role: String, expected: Array) -> void:
	_checks += 1
	var result: Dictionary = RESOLVER.resolve(text, selected_role)
	var actual: Array = result.get("roles", [])
	if actual != expected or not _has_shared_visibility(result):
		_failures.append("%s expected=%s actual=%s" % [text, expected, actual])

func _expect_delegation(
	text: String,
	selected_role: String,
	expected_origin: String,
	expected_target: String
) -> void:
	_checks += 1
	var result: Dictionary = RESOLVER.resolve(text, selected_role)
	var expected_roles := [expected_origin, expected_target]
	var actual_roles: Array = result.get("roles", [])
	var route_variant = result.get("route", {})
	var route: Dictionary = route_variant if route_variant is Dictionary else {}
	if (
		actual_roles != expected_roles
		or not _has_shared_visibility(result)
		or str(route.get("protocol", "")) != "spring_heaven.conversation_route.v1"
		or str(route.get("kind", "")) != "delegate_question"
		or str(route.get("origin_role", "")) != expected_origin
		or str(route.get("target_role", "")) != expected_target
	):
		_failures.append("%s delegation expected=%s actual=%s route=%s" % [
			text, expected_roles, actual_roles, route
		])

func _expect_context_delegation(
	text: String,
	selected_role: String,
	conversational_role: String,
	expected_origin: String,
	expected_target: String
) -> void:
	_checks += 1
	var result: Dictionary = RESOLVER.resolve(text, selected_role, conversational_role)
	var route_variant = result.get("route", {})
	var route: Dictionary = route_variant if route_variant is Dictionary else {}
	if (
		result.get("roles", []) != [expected_origin, expected_target]
		or not _has_shared_visibility(result)
		or str(route.get("origin_role", "")) != expected_origin
		or str(route.get("target_role", "")) != expected_target
	):
		_failures.append("%s contextual delegation invalid result=%s" % [text, result])

func _expect_context_roles(
	text: String,
	selected_role: String,
	conversational_role: String,
	expected: Array
) -> void:
	_checks += 1
	var result: Dictionary = RESOLVER.resolve(text, selected_role, conversational_role)
	if result.get("roles", []) != expected or not _has_shared_visibility(result):
		_failures.append("%s contextual expected=%s actual=%s" % [
			text, expected, result.get("roles", [])
		])

func _has_shared_visibility(result: Dictionary) -> bool:
	return (
		result.get("audience_roles", []) == ["ling", "nai"]
		and str(result.get("visibility", "")) == "shared_room"
	)
