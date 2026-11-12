class_name TododdleSupportDialog
extends CanvasLayer
## A plain report dialog built from the project's config: report type, title, description,
## custom fields and the attachments the game handed over (each with a preview the player can
## untick). It shows the sending, error and thank-you states and puts field errors next to fields.
##
## [codeblock]
## var dialog := TododdleSupportDialog.create()
## dialog.screen = "Level 3"
## dialog.add_attachment(TododdleSupportAttachment.from_viewport(get_viewport()))
## add_child(dialog)  # opens on ready
## [/codeblock]
##
## It uses plain Control nodes, so the game's Theme applies: set [member theme] or edit a copy of
## the scene. The texts that do not come from the config are exported properties.

## Emitted when a report reached ToDoddle.
signal report_sent(result: TododdleSupportResult)
## Emitted when sending failed. The dialog stays open so the player can try again.
signal report_failed(result: TododdleSupportResult)
## Emitted when the dialog closes, sent or not.
signal closed

enum State { LOADING, LOAD_ERROR, FORM, SENDING, THANK_YOU }

## Connection settings. Empty values fall back to Project Settings. Ignored when [member client]
## is set.
@export var settings: TododdleSupportSettings
## A Theme for the dialog. Without one it inherits the project's default theme.
@export var theme: Theme
## Open as soon as the dialog enters the tree.
@export var open_on_ready: bool = true
## Without a [member theme], give the panel a solid background and the send button the project's
## accent colour and corners from the config. Set a Theme, or turn this off, to style it yourself.
@export var use_project_style: bool = true
## Close on [code]ui_cancel[/code] (Escape or the controller's back button).
@export var close_on_cancel: bool = true
## Pause the SceneTree while the dialog is open.
@export var pause_game: bool = false
## Free the dialog when it closes.
@export var free_on_close: bool = true

@export_group("Text")
@export var loading_text: String = "Loading…"
@export var load_error_text: String = "The report form could not be loaded. Check your connection and try again."
@export var retry_text: String = "Try again"
@export var close_text: String = "Close"
@export var type_text: String = "Type"
@export var attachments_text: String = "Attach"
@export var choose_text: String = "Choose…"
@export var send_text: String = "Send"
@export var sending_text: String = "Sending…"
@export var fields_error_text: String = "Check the highlighted fields."
@export var form_changed_text: String = "The form has changed. Check the fields and send again."
@export var network_error_text: String = "The report was not sent because there is no connection. Try again."
@export var rate_limited_text: String = "Too many reports were sent. Try again in a few minutes."
@export var send_error_text: String = "The report was not sent. Try again."
## Added to the labels of required fields.
@export var required_suffix: String = " *"

## The client. Made from [member settings] when empty.
var client: TododdleSupport
## The screen, level or menu the player was on.
var screen: String = ""
## Game-defined context, up to 20 entries.
var extra: Dictionary = {}
## Overrides the client's build for this report.
var build: String = ""
## Optional and unverified reporter details.
var reporter_name: String = ""
var reporter_email: String = ""
var customer_reference: String = ""
## The report type picked first, for example [code]"feedback"[/code].
var default_type: String = ""
## The attachments offered to the player. Use [method add_attachment].
var attachments: Array[TododdleSupportAttachment] = []
## The loaded config, or null.
var config: TododdleSupportConfig = null
## The result of the last send, or null.
var last_result: TododdleSupportResult = null

var _state: State = State.LOADING
var _inputs: Dictionary = {}
var _error_labels: Dictionary = {}
var _attachment_checks: Array[CheckBox] = []
var _offered: Array[TododdleSupportAttachment] = []
var _last_key: String = ""
var _last_signature: String = ""
var _was_paused: bool = false
var _is_open: bool = false

@onready var _root: Control = %Root
@onready var _panel: PanelContainer = %Panel
@onready var _heading: Label = %Heading
@onready var _close_button: Button = %CloseButton
@onready var _intro: Label = %Intro
@onready var _loading: Label = %Loading
@onready var _load_error: Control = %LoadError
@onready var _load_error_message: Label = %LoadErrorMessage
@onready var _retry_button: Button = %RetryButton
@onready var _form: ScrollContainer = %Form
@onready var _type_label: Label = %TypeLabel
@onready var _type_picker: OptionButton = %TypePicker
@onready var _title_label: Label = %TitleLabel
@onready var _title_edit: LineEdit = %TitleEdit
@onready var _description_label: Label = %DescriptionLabel
@onready var _description_edit: TextEdit = %DescriptionEdit
@onready var _custom_fields: VBoxContainer = %CustomFields
@onready var _attachments_label: Label = %AttachmentsLabel
@onready var _attachment_list: VBoxContainer = %AttachmentList
@onready var _form_error: Label = %FormError
@onready var _status: Label = %Status
@onready var _submit_button: Button = %SubmitButton
@onready var _thank_you: Control = %ThankYou
@onready var _thank_you_title: Label = %ThankYouTitle
@onready var _thank_you_message: Label = %ThankYouMessage
@onready var _done_button: Button = %DoneButton


## A new dialog from the default scene. Add it to the tree to open it.
static func create() -> TododdleSupportDialog:
	var script_path: String = (TododdleSupportDialog as Script).resource_path
	var scene := load(script_path.get_base_dir().path_join("report_dialog.tscn")) as PackedScene
	return scene.instantiate() as TododdleSupportDialog


func _ready() -> void:
	if theme != null:
		_root.theme = theme
	_error_labels = {
		"type": %TypeError,
		"title": %TitleError,
		"description": %DescriptionError,
		"attachments": %AttachmentsError,
	}
	_close_button.pressed.connect(close)
	_done_button.pressed.connect(close)
	_retry_button.pressed.connect(open)
	_submit_button.pressed.connect(_on_submit_pressed)
	_apply_texts()
	get_viewport().size_changed.connect(_fit_to_viewport)
	_fit_to_viewport()
	visible = false
	if open_on_ready:
		open.call_deferred()


func _unhandled_input(event: InputEvent) -> void:
	if not _is_open or not close_on_cancel or _state == State.SENDING:
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		close()


## Offers [param attachment] to the player, who can untick it. Null is ignored, so the helpers
## can be passed straight in.
func add_attachment(attachment: TododdleSupportAttachment) -> void:
	if attachment != null:
		attachments.append(attachment)
		if _state == State.FORM and is_node_ready():
			_build_attachments()


## The current state.
func get_state() -> State:
	return _state


## Shows the dialog and loads the config. Await it to know when the form is ready.
func open() -> void:
	if not _is_open:
		_is_open = true
		visible = true
		if pause_game:
			_was_paused = get_tree().paused
			process_mode = Node.PROCESS_MODE_ALWAYS
			get_tree().paused = true
	if client == null:
		client = TododdleSupport.new(settings)
	_set_state(State.LOADING)
	var result := await client.get_config()
	if not _is_open:
		return
	if not result.ok:
		_load_error_message.text = load_error_text
		_set_state(State.LOAD_ERROR)
		_retry_button.grab_focus()
		return
	_build_form(result.config)
	_set_state(State.FORM)
	_focus_first_input()


## Closes the dialog. While a report is sending it keeps sending in the background.
func close() -> void:
	if not _is_open:
		return
	_is_open = false
	visible = false
	if pause_game:
		get_tree().paused = _was_paused
	closed.emit()
	if free_on_close:
		queue_free()


## Sets a value as if the player typed or picked it: [code]type[/code], [code]title[/code],
## [code]description[/code] or a custom field key. Call it after the form is ready.
func set_value(key: String, value: String) -> void:
	match key:
		"type":
			_select_option(_type_picker, value)
		"title":
			_title_edit.text = value
		"description":
			_description_edit.text = value
		_:
			var input: Control = _inputs.get(key)
			if input is OptionButton:
				_select_option(input as OptionButton, value)
			elif input is LineEdit:
				(input as LineEdit).text = value
			elif input is TextEdit:
				(input as TextEdit).text = value


## The values in the form, by key.
func get_values() -> Dictionary:
	var values: Dictionary = {
		"type": _selected_value(_type_picker),
		"title": _title_edit.text,
		"description": _description_edit.text,
	}
	for key: String in _inputs:
		values[key] = _input_value(_inputs[key])
	return values


## Ticks or unticks the attachment at [param index] in the list the player sees.
func set_attachment_included(index: int, included: bool) -> void:
	if index >= 0 and index < _attachment_checks.size():
		_attachment_checks[index].button_pressed = included


## Sends the form, as the submit button does. Returns null when the form is not showing.
func submit() -> TododdleSupportResult:
	if _state != State.FORM:
		return null
	_clear_errors()
	var report := _build_report()
	var local := client.validate_report(report, config)
	if not local.is_empty():
		_show_field_errors(local)
		_show_form_error(fields_error_text)
		var invalid := TododdleSupportResult.failure(TododdleSupportResult.INVALID_FIELDS, "Check the highlighted fields.", local)
		last_result = invalid
		report_failed.emit(invalid)
		return invalid

	_set_state(State.SENDING)
	var result := await client.send_report(report, config)
	last_result = result
	if result.ok:
		_set_state(State.THANK_YOU)
		_done_button.grab_focus()
		report_sent.emit(result)
		return result

	if result.error_code == TododdleSupportResult.FIELDS_CHANGED:
		var values := get_values()
		var reloaded := await client.get_config()
		if reloaded.ok:
			_build_form(reloaded.config)
			for key: String in values:
				set_value(key, str(values[key]))
	_set_state(State.FORM)
	_show_field_errors(result.fields)
	match result.error_code:
		TododdleSupportResult.INVALID_FIELDS:
			_show_form_error(fields_error_text)
		TododdleSupportResult.FIELDS_CHANGED:
			_show_form_error(form_changed_text)
		TododdleSupportResult.NETWORK_ERROR:
			_show_form_error(network_error_text)
		TododdleSupportResult.RATE_LIMITED:
			_show_form_error(rate_limited_text)
		_:
			_show_form_error(send_error_text)
	report_failed.emit(result)
	return result


func _on_submit_pressed() -> void:
	submit()


# --- Building the form ------------------------------------------------------------------------


func _build_form(value: TododdleSupportConfig) -> void:
	config = value
	_heading.text = config.dialog_title if not config.dialog_title.is_empty() else config.project_name
	_intro.text = config.intro
	_intro.visible = not config.intro.is_empty()
	_submit_button.text = config.submit_label if not config.submit_label.is_empty() else send_text
	_thank_you_title.text = config.thank_you_title
	_thank_you_message.text = config.thank_you_message

	var previous_type := _selected_value(_type_picker)
	_type_picker.clear()
	for type in config.types:
		_type_picker.add_item(str(type["label"]))
		_type_picker.set_item_metadata(_type_picker.item_count - 1, str(type["value"]))
	_type_picker.select(0)
	_select_option(_type_picker, previous_type if not previous_type.is_empty() else default_type)
	var many_types := config.types.size() > 1
	_type_label.visible = many_types
	_type_picker.visible = many_types

	_title_label.text = config.title_label + (required_suffix if config.title_required else "")
	_title_label.visible = config.title_enabled
	_title_edit.visible = config.title_enabled
	_title_edit.max_length = config.title_max_length
	_description_label.text = config.description_label + (required_suffix if config.description_required else "")
	_description_edit.placeholder_text = config.description_placeholder

	for child in _custom_fields.get_children():
		_custom_fields.remove_child(child)
		child.queue_free()
	_inputs.clear()
	for key: String in _error_labels.keys():
		if not key in ["type", "title", "description", "attachments"]:
			_error_labels.erase(key)
	for field in config.fields:
		_add_custom_field(field)

	_build_attachments()
	_clear_errors()
	_apply_project_style()


func _add_custom_field(field: TododdleSupportField) -> void:
	var label := Label.new()
	label.text = field.label + (required_suffix if field.required else "")
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_custom_fields.add_child(label)
	var input: Control
	match field.type:
		TododdleSupportField.SELECT:
			var picker := OptionButton.new()
			picker.add_item(choose_text)
			picker.set_item_metadata(0, "")
			for option in field.options:
				picker.add_item(option)
				picker.set_item_metadata(picker.item_count - 1, option)
			input = picker
		TododdleSupportField.LONG_TEXT:
			var area := TextEdit.new()
			area.custom_minimum_size = Vector2(0, 90)
			area.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
			input = area
		_:
			var line := LineEdit.new()
			line.max_length = field.effective_max_length()
			input = line
	input.name = "Field_%s" % field.key.replace("-", "_")
	_custom_fields.add_child(input)
	_inputs[field.key] = input
	var error := _error_labels["title"].duplicate() as Label
	error.visible = false
	_custom_fields.add_child(error)
	_error_labels[field.key] = error


func _build_attachments() -> void:
	for child in _attachment_list.get_children():
		_attachment_list.remove_child(child)
		child.queue_free()
	_attachment_checks.clear()
	_offered.clear()
	if config != null and config.attachments_enabled:
		for attachment in attachments:
			if config.accepts_content_type(attachment.content_type):
				_offered.append(attachment)
	_attachments_label.text = attachments_text
	_attachments_label.visible = not _offered.is_empty()
	_attachment_list.visible = not _offered.is_empty()
	# Images start ticked. Text such as logs starts unticked, so the player opts in to sending it.
	var ticked := 0
	for i in _offered.size():
		var attachment := _offered[i]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var check := CheckBox.new()
		check.text = "%s (%s)" % [attachment.file_name, String.humanize_size(attachment.get_size())]
		check.button_pressed = attachment.is_image() and ticked < maxi(config.attachments_max_count, 0)
		if check.button_pressed:
			ticked += 1
		check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		check.clip_text = true
		row.add_child(check)
		var preview := _preview_for(attachment)
		if preview != null:
			row.add_child(preview)
		_attachment_list.add_child(row)
		_attachment_checks.append(check)


func _preview_for(attachment: TododdleSupportAttachment) -> Control:
	if attachment.is_image():
		var image := Image.new()
		var err := FAILED
		match attachment.content_type:
			"image/png":
				err = image.load_png_from_buffer(attachment.bytes)
			"image/jpeg":
				err = image.load_jpg_from_buffer(attachment.bytes)
			"image/webp":
				err = image.load_webp_from_buffer(attachment.bytes)
		if err != OK or image.is_empty():
			return null
		var rect := TextureRect.new()
		rect.texture = ImageTexture.create_from_image(image)
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		rect.custom_minimum_size = Vector2(96, 54)
		return rect
	if attachment.is_text():
		var text := attachment.bytes.slice(0, 600).get_string_from_utf8()
		var lines := text.split("\n", false)
		var label := Label.new()
		label.text = "\n".join(lines.slice(0, 3)).left(160)
		label.custom_minimum_size = Vector2(180, 0)
		label.clip_text = true
		label.modulate = Color(1, 1, 1, 0.7)
		return label
	return null


# --- Sending ----------------------------------------------------------------------------------


func _build_report() -> TododdleSupportReport:
	var report := TododdleSupportReport.new()
	report.type = _selected_value(_type_picker)
	report.form_version = config.form_version
	if config.title_enabled:
		report.title = _title_edit.text
	report.description = _description_edit.text
	for key: String in _inputs:
		var value := _input_value(_inputs[key]).strip_edges()
		if not value.is_empty():
			report.fields[key] = value
	report.screen = screen
	report.extra = extra
	report.build = build
	report.reporter_name = reporter_name
	report.reporter_email = reporter_email
	report.customer_reference = customer_reference
	var names: Array[String] = []
	for i in _offered.size():
		if _attachment_checks[i].button_pressed:
			report.attachments.append(_offered[i])
			names.append("%s:%d" % [_offered[i].file_name, _offered[i].get_size()])
	# Reuse the idempotency key when the player sends the same report again (for example after a
	# network error), so the server never makes two tickets. A changed report gets a new key.
	var signature := JSON.stringify([report.type, report.form_version, report.title, report.description, report.fields, names])
	if signature == _last_signature and not _last_key.is_empty():
		report.idempotency_key = _last_key
	_last_key = report.idempotency_key
	_last_signature = signature
	return report


func _show_field_errors(errors: Dictionary) -> void:
	for key: Variant in errors:
		var label: Label = _error_labels.get(str(key))
		if label != null:
			label.text = str(errors[key])
			label.visible = true


func _show_form_error(text: String) -> void:
	_form_error.text = text
	_form_error.visible = not text.is_empty()


func _clear_errors() -> void:
	for key: Variant in _error_labels:
		var label: Label = _error_labels[key]
		label.text = ""
		label.visible = false
	_show_form_error("")


# --- State and layout -------------------------------------------------------------------------


func _set_state(state: State) -> void:
	_state = state
	_loading.visible = state == State.LOADING
	_load_error.visible = state == State.LOAD_ERROR
	_form.visible = state == State.FORM or state == State.SENDING
	_submit_button.visible = state == State.FORM or state == State.SENDING
	_submit_button.disabled = state == State.SENDING
	_status.text = sending_text if state == State.SENDING else ""
	_thank_you.visible = state == State.THANK_YOU
	_intro.visible = (state == State.FORM or state == State.SENDING) and not _intro.text.is_empty()
	if state != State.FORM and state != State.SENDING:
		_form_error.visible = false
	_close_button.disabled = state == State.SENDING
	_close_button.visible = state != State.THANK_YOU


func _apply_project_style() -> void:
	if theme != null or not use_project_style or config == null:
		return
	var radius := 0 if config.corners == "square" else 8
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(0.11, 0.12, 0.13)
	panel.set_corner_radius_all(radius)
	_panel.add_theme_stylebox_override("panel", panel)
	for state: String in ["normal", "hover", "pressed", "disabled", "focus"]:
		var box := StyleBoxFlat.new()
		box.set_corner_radius_all(radius)
		box.content_margin_left = 16
		box.content_margin_right = 16
		box.content_margin_top = 6
		box.content_margin_bottom = 6
		match state:
			"hover":
				box.bg_color = config.accent.lightened(0.12)
			"pressed":
				box.bg_color = config.accent.darkened(0.15)
			"disabled":
				box.bg_color = config.accent.darkened(0.35)
			"focus":
				box.draw_center = false
				box.border_color = config.on_accent
				box.set_border_width_all(2)
			_:
				box.bg_color = config.accent
		_submit_button.add_theme_stylebox_override(state, box)
	for color_name: String in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		_submit_button.add_theme_color_override(color_name, config.on_accent)
	_submit_button.add_theme_color_override("font_disabled_color", config.on_accent.darkened(0.3))


func _apply_texts() -> void:
	_loading.text = loading_text
	_retry_button.text = retry_text
	_close_button.text = close_text
	_done_button.text = close_text
	_type_label.text = type_text
	_attachments_label.text = attachments_text
	_submit_button.text = send_text


func _fit_to_viewport() -> void:
	var area := get_viewport().get_visible_rect().size
	_panel.custom_minimum_size.x = minf(560.0, maxf(area.x - 32.0, 200.0))
	_form.custom_minimum_size.y = clampf(area.y - 260.0, 120.0, 420.0)


func _focus_first_input() -> void:
	for candidate: Control in [_type_picker, _title_edit, _description_edit]:
		if candidate.is_visible_in_tree():
			candidate.grab_focus()
			return


static func _select_option(picker: OptionButton, value: String) -> void:
	if value.is_empty():
		return
	for i in picker.item_count:
		if str(picker.get_item_metadata(i)) == value:
			picker.select(i)
			return


static func _selected_value(picker: OptionButton) -> String:
	if picker.selected < 0:
		return ""
	return str(picker.get_item_metadata(picker.selected))


static func _input_value(input: Control) -> String:
	if input is OptionButton:
		return _selected_value(input as OptionButton)
	if input is LineEdit:
		return (input as LineEdit).text
	if input is TextEdit:
		return (input as TextEdit).text
	return ""
