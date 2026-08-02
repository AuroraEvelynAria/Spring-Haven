class_name TextSanitizer
extends RefCounted

static func contains_nul(value: String) -> bool:
	for index in value.length():
		if value.unicode_at(index) == 0:
			return true
	return false

static func strip_nul(value: String) -> String:
	if not contains_nul(value):
		return value
	var sanitized := ""
	for index in value.length():
		var codepoint := value.unicode_at(index)
		if codepoint != 0:
			sanitized += String.chr(codepoint)
	return sanitized
