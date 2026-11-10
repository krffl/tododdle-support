extends RefCounted
## Internal. Checks a report before it is sent, against the contract limits and, when known, the
## project's form. Returns a message per field key; an empty dictionary means the report is valid.

const MAX_TITLE := 160
const MAX_DESCRIPTION := 10000
const MAX_FIELD_VALUES := 20
const MAX_FIELD_VALUE := 5000
const MAX_ATTACHMENTS := 5
const MAX_REPORTER_NAME := 100
const MAX_REPORTER_EMAIL := 254
const MAX_CUSTOMER_REFERENCE := 100


static func validate(report: TododdleSupportReport, config: TododdleSupportConfig) -> Dictionary:
	var errors: Dictionary = {}
	var title := report.title.strip_edges()
	var description := report.description.strip_edges()

	# Contract limits (always).
	if _len(title) > MAX_TITLE:
		_add(errors, "title", "Use at most %d characters." % MAX_TITLE)
	if _len(description) > MAX_DESCRIPTION:
		_add(errors, "description", "Use at most %d characters." % MAX_DESCRIPTION)
	if report.fields.size() > MAX_FIELD_VALUES:
		_add(errors, "fields", "Send at most %d fields." % MAX_FIELD_VALUES)
	for key: Variant in report.fields:
		if _len(str(report.fields[key]).strip_edges()) > MAX_FIELD_VALUE:
			_add(errors, str(key), "Use at most %d characters." % MAX_FIELD_VALUE)
	if report.attachments.size() > MAX_ATTACHMENTS:
		_add(errors, "attachments", "Attach at most %d files." % MAX_ATTACHMENTS)
	for attachment in report.attachments:
		if attachment == null:
			_add(errors, "attachments", "An attachment is missing.")
			continue
		if attachment.get_size() < 1 or attachment.get_size() > TododdleSupportAttachment.MAX_BYTES:
			_add(errors, "attachments", "%s is empty or too large." % attachment.file_name)
		if attachment.file_name.is_empty() or _len(attachment.file_name) > 255:
			_add(errors, "attachments", "A file name is empty or too long.")
		if not TododdleSupportAttachment.CONTENT_TYPES.has(attachment.content_type):
			_add(errors, "attachments", "%s is not an allowed type." % attachment.file_name)
	if not _matches(report.idempotency_key, "^[A-Za-z0-9_-]{16,64}$"):
		_add(errors, "idempotencyKey", "The idempotency key is not valid.")
	if _len(report.reporter_name) > MAX_REPORTER_NAME:
		_add(errors, "reporter", "The reporter name is too long.")
	if _len(report.customer_reference) > MAX_CUSTOMER_REFERENCE:
		_add(errors, "reporter", "The customer reference is too long.")
	var email := report.reporter_email.strip_edges()
	if not email.is_empty() and (_len(email) > MAX_REPORTER_EMAIL or not _matches(email, "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$")):
		_add(errors, "reporter", "The reporter email is not valid.")

	if config == null:
		return errors

	# The project's form.
	if not config.has_type(report.type):
		_add(errors, "type", "Choose a report type.")
	if config.title_enabled:
		if config.title_required and title.is_empty():
			_add(errors, "title", "Enter %s." % config.title_label)
		elif _len(title) > config.title_max_length:
			_add(errors, "title", "Use at most %d characters." % config.title_max_length)
	if config.description_required and description.is_empty():
		_add(errors, "description", "Enter %s." % config.description_label)
	elif _len(description) > config.description_max_length:
		_add(errors, "description", "Use at most %d characters." % config.description_max_length)
	for field in config.fields:
		var value := str(report.fields.get(field.key, "")).strip_edges()
		if value.is_empty():
			if field.required:
				_add(errors, field.key, "Enter %s." % field.label)
			continue
		if field.type == TododdleSupportField.SELECT and not field.options.has(value):
			_add(errors, field.key, "Choose one of the options.")
		elif _len(value) > field.effective_max_length():
			_add(errors, field.key, "Use at most %d characters." % field.effective_max_length())
	if not report.attachments.is_empty():
		if not config.attachments_enabled:
			_add(errors, "attachments", "Attachments are not accepted.")
		elif report.attachments.size() > config.attachments_max_count:
			_add(errors, "attachments", "Attach at most %d files." % config.attachments_max_count)
		for attachment in report.attachments:
			if attachment == null:
				continue
			if not config.attachment_content_types.has(attachment.content_type):
				_add(errors, "attachments", "%s is not an allowed type." % attachment.file_name)
			elif config.attachments_max_bytes > 0 and attachment.get_size() > config.attachments_max_bytes:
				_add(errors, "attachments", "%s is too large." % attachment.file_name)
	return errors


static func _add(errors: Dictionary, key: String, message: String) -> void:
	if not errors.has(key):
		errors[key] = message


## The length the server counts: UTF-16 code units, as in JavaScript.
static func _len(value: String) -> int:
	return value.to_utf16_buffer().size() / 2


## [param value] cut to at most [param max_length] UTF-16 code units, without splitting a
## character.
static func clip(value: String, max_length: int) -> String:
	if _len(value) <= max_length:
		return value
	var out := value.left(max_length)
	while _len(out) > max_length:
		out = out.left(out.length() - 1)
	return out


static func _matches(value: String, pattern: String) -> bool:
	var regex := RegEx.create_from_string(pattern)
	return regex.search(value) != null
