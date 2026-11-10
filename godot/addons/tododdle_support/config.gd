class_name TododdleSupportConfig
extends RefCounted
## The project's report form, wording and branding, read from [code]GET /config[/code].
##
## [member data] keeps the full JSON, including fields this version does not know about.

## The project's display name.
var project_name: String = ""
var logo_url: String = ""

## Send this back with each report. It increases whenever the project changes the form.
var form_version: int = 1
## Report types in order, each [code]{"value": "problem", "label": "Report a problem"}[/code].
var types: Array[Dictionary] = []

var title_enabled: bool = false
var title_required: bool = false
var title_label: String = "Title"
var title_max_length: int = 160

var description_required: bool = false
var description_label: String = "Description"
var description_placeholder: String = ""
var description_max_length: int = 10000

## The project's custom fields, in order.
var fields: Array[TododdleSupportField] = []

var attachments_enabled: bool = false
var attachments_max_count: int = 0
## Per file.
var attachments_max_bytes: int = 0
var attachment_content_types: PackedStringArray = PackedStringArray()

var dialog_title: String = ""
var intro: String = ""
var submit_label: String = ""
var thank_you_title: String = ""
## Never promises a reply: reports are one way.
var thank_you_message: String = ""

## The project's accent colour and the text colour to use on it.
var accent: Color = Color("#2f6d4f")
var on_accent: Color = Color.WHITE
## [code]"rounded"[/code] or [code]"square"[/code].
var corners: String = "rounded"
var heading_font: String = ""

## The full JSON object.
var data: Dictionary = {}


## The field with [param key], or null.
func get_field(key: String) -> TododdleSupportField:
	for field in fields:
		if field.key == key:
			return field
	return null


## Whether [param value] is one of the report types.
func has_type(value: String) -> bool:
	for type in types:
		if type.get("value") == value:
			return true
	return false


## Whether attachments of [param content_type] are accepted.
func accepts_content_type(content_type: String) -> bool:
	return attachments_enabled and attachment_content_types.has(content_type)


## Reads a config from parsed JSON. Returns null when the required parts are missing.
static func parse(json: Variant) -> TododdleSupportConfig:
	if not json is Dictionary:
		return null
	var root: Dictionary = json
	var project := _dict(root.get("project"))
	var form := _dict(root.get("form"))
	var wording := _dict(root.get("wording"))
	var theme := _dict(root.get("theme"))
	if project.is_empty() or form.is_empty() or wording.is_empty() or theme.is_empty():
		return null
	if not form.get("version") is float and not form.get("version") is int:
		return null

	var config := TododdleSupportConfig.new()
	config.data = root
	config.project_name = _str(project.get("name"))
	config.logo_url = _str(project.get("logoUrl"))
	config.form_version = int(form["version"])

	var raw_types: Variant = form.get("types")
	if raw_types is Array:
		for item: Variant in raw_types:
			var type := _dict(item)
			if type.get("value") is String and type.get("label") is String:
				config.types.append({"value": type["value"], "label": type["label"]})
	if config.types.is_empty():
		return null

	var title := _dict(form.get("title"))
	if not title.is_empty():
		config.title_enabled = title.get("enabled") == true
		config.title_required = title.get("required") == true
		config.title_label = _str(title.get("label"), config.title_label)
		config.title_max_length = _int(title.get("maxLength"), config.title_max_length)

	var description := _dict(form.get("description"))
	if not description.is_empty():
		config.description_required = description.get("required") == true
		config.description_label = _str(description.get("label"), config.description_label)
		config.description_placeholder = _str(description.get("placeholder"))
		config.description_max_length = _int(description.get("maxLength"), config.description_max_length)

	var raw_fields: Variant = form.get("fields")
	if raw_fields is Array:
		for item: Variant in raw_fields:
			var field := TododdleSupportField.parse(item)
			if field != null:
				config.fields.append(field)

	var attachments := _dict(form.get("attachments"))
	if not attachments.is_empty():
		config.attachments_enabled = attachments.get("enabled") == true
		config.attachments_max_count = _int(attachments.get("maxCount"), 0)
		config.attachments_max_bytes = _int(attachments.get("maxBytes"), 0)
		var raw_types_allowed: Variant = attachments.get("contentTypes")
		if raw_types_allowed is Array:
			for item: Variant in raw_types_allowed:
				if item is String:
					config.attachment_content_types.append(item)

	config.dialog_title = _str(wording.get("dialogTitle"))
	config.intro = _str(wording.get("intro"))
	config.submit_label = _str(wording.get("submitLabel"))
	config.thank_you_title = _str(wording.get("thankYouTitle"))
	config.thank_you_message = _str(wording.get("thankYouMessage"))

	config.accent = _color(theme.get("accent"), config.accent)
	config.on_accent = _color(theme.get("onAccent"), config.on_accent)
	config.corners = _str(theme.get("corners"), config.corners)
	config.heading_font = _str(theme.get("headingFont"))
	return config


static func _dict(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}


static func _str(value: Variant, fallback: String = "") -> String:
	return value if value is String else fallback


static func _int(value: Variant, fallback: int) -> int:
	if value is float or value is int:
		return int(value)
	return fallback


static func _color(value: Variant, fallback: Color) -> Color:
	if value is String and Color.html_is_valid(value):
		return Color.html(value)
	return fallback
