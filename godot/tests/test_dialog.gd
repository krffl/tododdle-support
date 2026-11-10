extends "res://tests/test_base.gd"
## The default report dialog, driven headless against the mock server.

const CONFIG_OK := {
	"request": {"method": "GET", "path": "/config"},
	"response": {"status": 200, "headers": {"ETag": "\"cfg-3\""}, "body": "$config"},
}


func _received(id: String, must: Dictionary = {}) -> Dictionary:
	var request: Dictionary = {"method": "POST", "path": "/reports"}
	if not must.is_empty():
		request["must"] = must
	return {"request": request, "response": {"status": 201, "body": {"reportId": id, "status": "received"}}}


func _open_dialog(attachments: Array[TododdleSupportAttachment] = []) -> TododdleSupportDialog:
	var dialog := TododdleSupportDialog.create()
	dialog.open_on_ready = false
	dialog.free_on_close = true
	var client := new_client()
	client.retry_policy.backoff_seconds = [0.05, 0.05, 0.05]
	dialog.client = client
	dialog.screen = "Level 3"
	dialog.extra = {"seed": "42"}
	for attachment in attachments:
		dialog.add_attachment(attachment)
	(Engine.get_main_loop() as SceneTree).root.add_child(dialog)
	await dialog.open()
	return dialog


func _error_text(dialog: TododdleSupportDialog, key: String) -> String:
	var label: Label = dialog._error_labels.get(key)
	return label.text if label != null and label.visible else ""


func _attachments() -> Array[TododdleSupportAttachment]:
	var image := Image.create(8, 8, false, Image.FORMAT_RGB8)
	image.fill(Color.ORANGE)
	return [
		TododdleSupportAttachment.from_image(image),
		TododdleSupportAttachment.from_text("frame 812: 140 ms\n", "hitch_log.txt"),
	]


func test_form_is_built_from_the_config() -> void:
	await load_exchanges([CONFIG_OK])
	var dialog := await _open_dialog(_attachments())
	check_eq(dialog.get_state(), TododdleSupportDialog.State.FORM, "state")
	check_eq((dialog.get_node("%Heading") as Label).text, "Tell us what happened", "dialog title")
	check_eq((dialog.get_node("%Intro") as Label).text, "Your report goes straight to the Mosslight team.", "intro")
	check_eq((dialog.get_node("%SubmitButton") as Button).text, "Send report", "submit label")
	var picker := dialog.get_node("%TypePicker") as OptionButton
	check_eq(picker.item_count, 3, "report types")
	check_eq(picker.get_item_text(1), "Share feedback", "type label")
	check((dialog.get_node("%TitleEdit") as LineEdit).visible, "title shown")
	check_eq((dialog.get_node("%DescriptionLabel") as Label).text, "What happened? *", "required description")
	check(dialog._inputs["area"] is OptionButton, "SELECT field")
	check_eq((dialog._inputs["area"] as OptionButton).item_count, 4, "choose + 3 options")
	check(dialog._inputs["steps"] is TextEdit, "LONG_TEXT field")
	check_eq(dialog._attachment_checks.size(), 2, "two attachments offered")
	check(dialog._attachment_checks[0].button_pressed and dialog._attachment_checks[1].button_pressed, "ticked by default")
	check_mock_clean(await mock_state())
	dialog.close()


func test_sends_and_shows_thank_you() -> void:
	await load_exchanges(
		[
			CONFIG_OK,
			_received("rpt_CCCCCCCCCCCCCCCC0001", {"body": {"type": "feedback", "fields": {"area": "Settings", "steps": "Open settings"}, "description": "It crashed."}}),
		]
	)
	var dialog := await _open_dialog()
	var sent: Array[String] = []
	var closed: Array[bool] = []
	dialog.report_sent.connect(func(r: TododdleSupportResult) -> void: sent.append(r.report_id))
	dialog.closed.connect(func() -> void: closed.append(true))
	dialog.set_value("type", "feedback")
	dialog.set_value("description", "  It crashed.  ")
	dialog.set_value("area", "Settings")
	dialog.set_value("steps", "Open settings")
	var result := await dialog.submit()
	check(result.ok, str(result))
	check_eq(dialog.get_state(), TododdleSupportDialog.State.THANK_YOU, "state")
	check((dialog.get_node("%ThankYou") as Control).visible, "thank-you shown")
	check_eq((dialog.get_node("%ThankYouTitle") as Label).text, "Thanks!", "thank-you title")
	check_eq((dialog.get_node("%ThankYouMessage") as Label).text, "We read every report.", "thank-you message")
	check_eq(sent, ["rpt_CCCCCCCCCCCCCCCC0001"] as Array[String], "report_sent")
	var state := await mock_state()
	check_mock_clean(state)
	var body: Dictionary = request_json((state["requests"] as Array)[1])
	check_eq(body["context"]["screen"], "Level 3", "screen")
	check_eq(body["context"]["extra"], {"seed": "42"}, "extra")
	(dialog.get_node("%DoneButton") as Button).pressed.emit()
	check_eq(closed, [true] as Array[bool], "closed")


func test_local_field_errors_are_shown_next_to_fields() -> void:
	await load_exchanges([CONFIG_OK])
	var dialog := await _open_dialog()
	var result := await dialog.submit()
	check_eq(result.error_code, TododdleSupportResult.INVALID_FIELDS, "code")
	check_eq(_error_text(dialog, "description"), "Enter What happened?.", "description error")
	check_eq(_error_text(dialog, "area"), "Enter Where in the app?.", "area error")
	check_eq(_error_text(dialog, "steps"), "", "no error on an optional field")
	check((dialog.get_node("%FormError") as Label).visible, "form error shown")
	check_eq(dialog.get_state(), TododdleSupportDialog.State.FORM, "still on the form")
	var state := await mock_state()
	check_eq((state["requests"] as Array).size(), 1, "only the config request")
	dialog.close()


func test_server_field_errors_are_shown_next_to_fields() -> void:
	await load_exchanges(
		[
			CONFIG_OK,
			{
				"request": {"method": "POST", "path": "/reports"},
				"response": {"status": 422, "body": {"error": {"code": "INVALID_FIELDS", "message": "Check.", "fields": {"area": "Choose where in the app.", "title": "Too vague."}}}},
			},
		]
	)
	var dialog := await _open_dialog()
	dialog.set_value("description", "Broken.")
	dialog.set_value("area", "Home")
	var failed: Array[String] = []
	dialog.report_failed.connect(func(r: TododdleSupportResult) -> void: failed.append(r.error_code))
	await dialog.submit()
	check_eq(_error_text(dialog, "area"), "Choose where in the app.", "area error from the server")
	check_eq(_error_text(dialog, "title"), "Too vague.", "title error from the server")
	check_eq((dialog.get_node("%FormError") as Label).text, dialog.fields_error_text, "form error")
	check_eq(failed, ["INVALID_FIELDS"] as Array[String], "report_failed")
	check_mock_clean(await mock_state())
	dialog.close()


func test_unticked_attachment_is_not_sent() -> void:
	await load_exchanges([CONFIG_OK, _received("rpt_CCCCCCCCCCCCCCCC0002")])
	var dialog := await _open_dialog(_attachments())
	dialog.set_value("description", "Hitch.")
	dialog.set_value("area", "Other")
	dialog.set_attachment_included(0, false)
	var result := await dialog.submit()
	check(result.ok, str(result))
	var state := await mock_state()
	var body: Dictionary = request_json((state["requests"] as Array)[1])
	var declared: Array = body["attachments"]
	check_eq(declared.size(), 1, "one attachment")
	check_eq(declared[0]["fileName"], "hitch_log.txt", "the log only")
	dialog.close()


func test_load_error_then_retry() -> void:
	await load_exchanges([{"request": {"method": "GET", "path": "/config"}, "response": {"status": 403, "body": {"error": {"code": "SUPPORT_UNAVAILABLE", "message": "Off."}}}}])
	var dialog := await _open_dialog()
	check_eq(dialog.get_state(), TododdleSupportDialog.State.LOAD_ERROR, "load error")
	check((dialog.get_node("%LoadError") as Control).visible, "load error shown")
	await load_exchanges([CONFIG_OK])
	await dialog.open()
	check_eq(dialog.get_state(), TododdleSupportDialog.State.FORM, "form after retry")
	dialog.close()


func test_same_report_after_network_error_reuses_the_key() -> void:
	await load_exchanges(
		[
			CONFIG_OK,
			{"request": {"method": "POST", "path": "/reports"}, "response": {"status": 503}},
			{"request": {"method": "POST", "path": "/reports"}, "response": {"status": 503}},
			{"request": {"method": "POST", "path": "/reports"}, "response": {"status": 503}},
			_received("rpt_CCCCCCCCCCCCCCCC0003", {"sameIdempotencyKeyAsPrevious": true}),
		]
	)
	var dialog := await _open_dialog()
	dialog.set_value("description", "Lag.")
	dialog.set_value("area", "Home")
	var first := await dialog.submit()
	check_eq(first.error_code, TododdleSupportResult.HTTP_ERROR, "first send fails")
	check_eq((dialog.get_node("%FormError") as Label).text, dialog.send_error_text, "error shown")
	var second := await dialog.submit()
	check(second.ok, str(second))
	check_mock_clean(await mock_state())
	dialog.close()


func test_changed_report_gets_a_new_key() -> void:
	await load_exchanges([CONFIG_OK])
	var dialog := await _open_dialog()
	dialog.set_value("description", "One.")
	var first := dialog._build_report()
	var again := dialog._build_report()
	dialog.set_value("description", "Two.")
	var changed := dialog._build_report()
	check_eq(again.idempotency_key, first.idempotency_key, "same report, same key")
	check(changed.idempotency_key != first.idempotency_key, "changed report, new key")
	dialog.close()


func test_fields_changed_reloads_the_form_and_keeps_values() -> void:
	var newer: Dictionary = suite["config"].duplicate(true)
	newer["form"]["version"] = 4
	newer["form"]["fields"].append({"key": "platform-choice", "label": "Platform", "type": "SHORT_TEXT", "required": true})
	await load_exchanges(
		[
			CONFIG_OK,
			{
				"request": {"method": "POST", "path": "/reports"},
				"response": {"status": 422, "body": {"error": {"code": "FIELDS_CHANGED", "message": "Changed.", "fields": {"platform-choice": "Enter Platform."}}}},
			},
			{"request": {"method": "GET", "path": "/config"}, "response": {"status": 200, "headers": {"ETag": "\"cfg-4\""}, "body": newer}},
		]
	)
	var dialog := await _open_dialog()
	dialog.set_value("description", "Kept text.")
	dialog.set_value("area", "Settings")
	var result := await dialog.submit()
	check_eq(result.error_code, TododdleSupportResult.FIELDS_CHANGED, "code")
	check_eq(dialog.config.form_version, 4, "new form")
	check(dialog._inputs.has("platform-choice"), "new field shown")
	check_eq(_error_text(dialog, "platform-choice"), "Enter Platform.", "new field error")
	check_eq(dialog.get_values()["description"], "Kept text.", "description kept")
	check_eq(dialog.get_values()["area"], "Settings", "area kept")
	check_eq((dialog.get_node("%FormError") as Label).text, dialog.form_changed_text, "form error")
	check_mock_clean(await mock_state())
	dialog.close()


func test_cancel_closes_and_pause_is_restored() -> void:
	await load_exchanges([CONFIG_OK])
	var tree := Engine.get_main_loop() as SceneTree
	var dialog := TododdleSupportDialog.create()
	dialog.open_on_ready = false
	dialog.pause_game = true
	dialog.client = new_client()
	tree.root.add_child(dialog)
	await dialog.open()
	check(tree.paused, "paused while open")
	var cancel := InputEventAction.new()
	cancel.action = "ui_cancel"
	cancel.pressed = true
	dialog._unhandled_input(cancel)
	check(not tree.paused, "pause restored")
	check(dialog.is_queued_for_deletion(), "freed on close")
