class_name TododdleSupportField
extends RefCounted
## One custom field of the project's report form.

const SHORT_TEXT := "SHORT_TEXT"
const LONG_TEXT := "LONG_TEXT"
const SELECT := "SELECT"

const SHORT_TEXT_MAX_LENGTH := 300
const LONG_TEXT_MAX_LENGTH := 5000

## Stable key, for example [code]area[/code]. Field values and field errors use it.
var key: String = ""
var label: String = ""
## [constant SHORT_TEXT], [constant LONG_TEXT] or [constant SELECT]. New types may appear in v1;
## the dialog shows unknown types as short text.
var type: String = SHORT_TEXT
var required: bool = false
## For [constant SELECT] only.
var options: PackedStringArray = PackedStringArray()
## The limit the server sent, or 0.
var max_length: int = 0


## The longest value allowed: [member max_length] when the server sent one, otherwise 300 for
## short text and 5000 for everything else.
func effective_max_length() -> int:
	if max_length > 0:
		return mini(max_length, LONG_TEXT_MAX_LENGTH)
	return SHORT_TEXT_MAX_LENGTH if type == SHORT_TEXT else LONG_TEXT_MAX_LENGTH


## Reads one field definition. Returns null when [param data] is not a valid definition.
static func parse(data: Variant) -> TododdleSupportField:
	if not data is Dictionary:
		return null
	var d: Dictionary = data
	if not (d.get("key") is String and d.get("label") is String and d.get("type") is String):
		return null
	var field := TododdleSupportField.new()
	field.key = d["key"]
	field.label = d["label"]
	field.type = d["type"]
	field.required = d.get("required") == true
	var raw_options: Variant = d.get("options")
	if raw_options is Array:
		for option: Variant in raw_options:
			if option is String:
				field.options.append(option)
	var raw_max: Variant = d.get("maxLength")
	if raw_max is float or raw_max is int:
		field.max_length = int(raw_max)
	if field.key.is_empty():
		return null
	return field
