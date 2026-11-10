class_name TododdleSupportReport
extends RefCounted
## One report to send with [method TododdleSupport.send_report].
##
## Only what you set here (plus the device context the client fills in) is sent. Keep the same
## object, and so the same [member idempotency_key], when you retry a report, so the server never
## creates a second ticket.

## Generated once per report (UUID v4) and sent on every retry.
var idempotency_key: String = new_idempotency_key()
## One of the config's report types: [code]problem[/code], [code]feedback[/code] or
## [code]question[/code].
var type: String = "problem"
## The config's form version. 0 means "use the config the client loads".
var form_version: int = 0
var title: String = ""
var description: String = ""
## Custom field values by field key. Text for text fields and one of the options for SELECT.
var fields: Dictionary = {}

## The screen, level or menu the player was on, without personal data.
var screen: String = ""
## Overrides the client's app version for this report.
var app_version: String = ""
## Overrides the client's build for this report.
var build: String = ""
## Game-defined context, shown on the ticket as is. Up to 20 entries; values are converted to
## text and cut to 500 characters.
var extra: Dictionary = {}

## Optional and unverified. ToDoddle never emails the reporter.
var reporter_name: String = ""
var reporter_email: String = ""
## The game's own player or account ID.
var customer_reference: String = ""

## Files the game hands over. Nothing is attached automatically.
var attachments: Array[TododdleSupportAttachment] = []


## Adds [param attachment] unless it is null (the helpers return null when there is nothing to
## attach). Returns this report so calls can be chained.
func add_attachment(attachment: TododdleSupportAttachment) -> TododdleSupportReport:
	if attachment != null:
		attachments.append(attachment)
	return self


## A new random UUID v4, for example [code]0f8fad5b-d9cb-469f-a165-70867728950e[/code].
static func new_idempotency_key() -> String:
	var bytes := Crypto.new().generate_random_bytes(16)
	bytes[6] = (bytes[6] & 0x0F) | 0x40
	bytes[8] = (bytes[8] & 0x3F) | 0x80
	var hex := bytes.hex_encode()
	return "%s-%s-%s-%s-%s" % [hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4), hex.substr(16, 4), hex.substr(20, 12)]
