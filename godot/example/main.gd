extends Control
## A tiny game screen with a "Report a problem" button.
##
## The key comes from Project Settings (tododdle_support/key). The value in this project is a
## placeholder; put your own public key there to send real reports.

const HITCH_LOG := "user://hitch_log.txt"

@onready var _report_button: Button = %ReportButton
@onready var _status: Label = %Status


func _ready() -> void:
	_report_button.pressed.connect(_on_report_pressed)
	_write_sample_log()


func _on_report_pressed() -> void:
	var dialog := TododdleSupportDialog.create()
	dialog.screen = "Example level"
	dialog.extra = {"difficulty": "normal", "seed": str(1234)}
	# Take the screenshot first so the dialog is not in it. The player can untick it.
	dialog.add_attachment(TododdleSupportAttachment.from_viewport(get_viewport()))
	dialog.add_attachment(TododdleSupportAttachment.from_text_file(HITCH_LOG))
	dialog.report_sent.connect(func(result: TododdleSupportResult) -> void: _status.text = "Sent: %s" % result.report_id)
	dialog.closed.connect(func() -> void: _report_button.grab_focus())
	add_child(dialog)


## The game's own log. The addon reads nothing unless the game hands it over.
func _write_sample_log() -> void:
	var file := FileAccess.open(HITCH_LOG, FileAccess.WRITE)
	if file == null:
		return
	file.store_string("frame 812: 140 ms (shader compile)\nframe 1630: 95 ms (level stream)\n")
	file.close()
