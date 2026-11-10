class_name TododdleSupportResult
extends RefCounted
## The result of [method TododdleSupport.send_report]. Check [member ok] first.
##
## On failure, [member error_code] is a stable machine code. Codes from the server may be new in
## v1, so treat an unknown code by its [member http_status]. Show your own wording to players;
## [member message] is plain English for logs.

# Codes from the contract (Error.code).
const INVALID_REQUEST := "INVALID_REQUEST"
const INVALID_KEY := "INVALID_KEY"
const KEY_REVOKED := "KEY_REVOKED"
const ORIGIN_NOT_ALLOWED := "ORIGIN_NOT_ALLOWED"
const APP_NOT_ALLOWED := "APP_NOT_ALLOWED"
const SUPPORT_UNAVAILABLE := "SUPPORT_UNAVAILABLE"
## One or more fields failed validation; see [member fields]. The client also uses this code for
## its own checks before sending, with [member http_status] 0.
const INVALID_FIELDS := "INVALID_FIELDS"
## The form changed since the config was read. Load the config again; see [member fields].
const FIELDS_CHANGED := "FIELDS_CHANGED"
const PAYLOAD_TOO_LARGE := "PAYLOAD_TOO_LARGE"
const TOO_MANY_ATTACHMENTS := "TOO_MANY_ATTACHMENTS"
const ATTACHMENT_TYPE_NOT_ALLOWED := "ATTACHMENT_TYPE_NOT_ALLOWED"
const IDEMPOTENCY_KEY_REUSED := "IDEMPOTENCY_KEY_REUSED"
const ATTACHMENTS_NOT_READY := "ATTACHMENTS_NOT_READY"
const REPORT_NOT_FOUND := "REPORT_NOT_FOUND"
const REPORT_EXPIRED := "REPORT_EXPIRED"
## Too many requests. [member retry_after_seconds] says how long to wait, when the server sent it.
const RATE_LIMITED := "RATE_LIMITED"

# Codes the client raises itself; they never come from the server.
## The request did not reach the server, or no response came back.
const NETWORK_ERROR := "NETWORK_ERROR"
## The server answered with an error status and no readable error body.
const HTTP_ERROR := "HTTP_ERROR"
## The server answered with a body the client cannot read.
const INVALID_RESPONSE := "INVALID_RESPONSE"
## An attachment upload to its [code]uploadUrl[/code] failed.
const UPLOAD_FAILED := "UPLOAD_FAILED"
## No key is set. Set [code]tododdle_support/key[/code] in Project Settings, or pass one.
const NOT_CONFIGURED := "NOT_CONFIGURED"

## Statuses for [member status].
const STATUS_RECEIVED := "received"
const STATUS_FAILED := "failed"

## True when the call succeeded.
var ok: bool = false
## [code]"received"[/code] when the report reached ToDoddle, otherwise [code]"failed"[/code].
var status: String = STATUS_FAILED
## The report ID, for example [code]rpt_…[/code]. Safe to show the player as a reference.
var report_id: String = ""
## Empty on success.
var error_code: String = ""
## Plain English and safe to log.
var message: String = ""
## For [constant INVALID_FIELDS] and [constant FIELDS_CHANGED]: a message per field key. Built-in
## keys are [code]type[/code], [code]title[/code], [code]description[/code] and
## [code]attachments[/code]; other keys are the project's custom field keys.
var fields: Dictionary = {}
## Seconds the server asked the client to wait, or -1.
var retry_after_seconds: int = -1
## The HTTP status of the failed response, or 0 when no response came back or the client raised
## the error itself.
var http_status: int = 0
## The server's request ID, when it sent one. Useful when you contact ToDoddle about an error.
var request_id: String = ""


## Whether trying the same call again later may succeed: a network error or a retryable status.
func is_transient() -> bool:
	if error_code == NETWORK_ERROR:
		return true
	return TododdleSupportRetryPolicy.new().is_retry_status(http_status)


## Copies the error from [param other] into this result.
func copy_error_from(other: TododdleSupportResult) -> void:
	ok = false
	status = STATUS_FAILED
	error_code = other.error_code
	message = other.message
	fields = other.fields.duplicate()
	retry_after_seconds = other.retry_after_seconds
	http_status = other.http_status
	request_id = other.request_id


func _to_string() -> String:
	if ok:
		return "TododdleSupportResult(%s %s)" % [status, report_id]
	var http := "" if http_status == 0 else " HTTP %d" % http_status
	return "TododdleSupportResult(%s%s: %s)" % [error_code, http, message]


## A successful report result.
static func received(id: String) -> TododdleSupportResult:
	var result := TododdleSupportResult.new()
	result.ok = true
	result.status = STATUS_RECEIVED
	result.report_id = id
	return result


## A failed result with [param code] and [param text].
static func failure(code: String, text: String, field_errors: Dictionary = {}) -> TododdleSupportResult:
	var result := TododdleSupportResult.new()
	result.error_code = code
	result.message = text
	result.fields = field_errors
	return result
