class_name TododdleSupport
extends RefCounted
## A headless client for the ToDoddle Support SDK API (one-way issue reports).
##
## [codeblock]
## var support := TododdleSupport.new()  # key and base URL from Project Settings
## var config_result := await support.get_config()
## var report := TododdleSupportReport.new()
## report.description = "The boss fight froze after the cutscene."
## report.screen = "Level 3"
## var result := await support.send_report(report)
## if result.ok:
##     print("Sent ", result.report_id)
## [/codeblock]
##
## Keep the client in a variable for as long as a call is running. Every call returns a result
## object and never raises an error.

## Emitted when [method get_config] finishes.
signal config_loaded(result: TododdleSupportConfigResult)
## Emitted when [method send_report] finishes.
signal report_finished(result: TododdleSupportResult)

## This addon's version, sent as [code]X-Tododdle-Sdk: godot/<version>[/code]. Kept in step with
## the repository's VERSION file by scripts/sync-version.mjs.
const SDK_VERSION := "1.0.2"
const SDK_NAME := "godot"
const PLATFORM := "godot"
const DEFAULT_BASE_URL := TododdleSupportSettings.DEFAULT_BASE_URL
const STAGING_BASE_URL := TododdleSupportSettings.STAGING_BASE_URL

const _Http := preload("http.gd")
const _Validation := preload("validation.gd")
const _CACHE_DIR := "user://tododdle_support"
const _MAX_EXTRA := 20
const _MAX_EXTRA_VALUE := 500
## The key prefixes the SDK accepts.
const KEY_PREFIXES: PackedStringArray = ["tdsk_pub_", "tdsk_test_"]
## Hosts that may use plain HTTP, for local test servers.
const LOOPBACK_HOSTS: PackedStringArray = ["127.0.0.1", "::1", "localhost"]
## Upload headers from the server that the client never sends.
const _BLOCKED_UPLOAD_HEADERS: PackedStringArray = [
	"host", "authorization", "cookie", "connection", "transfer-encoding", "content-length"
]

## The public SDK key.
var key: String = ""
## The API base URL, without a trailing slash.
var base_url: String = DEFAULT_BASE_URL
## Sent as [code]X-Tododdle-App-Id[/code] when not empty.
var app_id: String = ""
## Sent as the context's [code]appVersion[/code] unless the report sets its own.
var app_version: String = ""
## Sent as the context's [code]build[/code] unless the report sets its own.
var build: String = ""
## Seconds before one HTTP attempt gives up.
var timeout_seconds: float = 30.0
## Fill in the OS name and version, device model and locale.
var collect_device_context: bool = true
## Where the last good config is kept. Empty turns the cache off.
var config_cache_path: String = ""
## The retry rules. Shared by every ToDoddle Support SDK; change them only in tests.
var retry_policy: TododdleSupportRetryPolicy = TododdleSupportRetryPolicy.new()

var _config: TododdleSupportConfig = null
var _cached_etag: String = ""
var _cached_body: String = ""
var _cache_loaded: bool = false


## Creates a client. Without [param settings], or for any empty value in it, the key, base URL
## and app ID come from Project Settings ([code]tododdle_support/*[/code]).
func _init(settings: TododdleSupportSettings = null) -> void:
	var resolved := (settings if settings != null else TododdleSupportSettings.new()).resolved()
	key = resolved.key
	base_url = resolved.base_url
	app_id = resolved.app_id
	app_version = resolved.app_version
	build = resolved.build
	timeout_seconds = resolved.timeout_seconds
	collect_device_context = resolved.collect_device_context
	if resolved.cache_config:
		config_cache_path = "%s/config-%s.json" % [_CACHE_DIR, (base_url + "|" + key).sha256_text().left(16)]


## Creates a client with [param p_key] and, optionally, a base URL and app ID. Empty values fall
## back to Project Settings.
static func create(p_key: String, p_base_url: String = "", p_app_id: String = "") -> TododdleSupport:
	var settings := TododdleSupportSettings.new()
	settings.key = p_key
	settings.base_url = p_base_url
	settings.app_id = p_app_id
	return TododdleSupport.new(settings)


## The value sent as [code]X-Tododdle-Sdk[/code].
static func sdk_header() -> String:
	return "%s/%s" % [SDK_NAME, SDK_VERSION]


## The last config read by [method get_config], or null.
func get_cached_config() -> TododdleSupportConfig:
	return _config


## Reads the report form, wording and branding.
##
## Sends [code]If-None-Match[/code] with the last [code]ETag[/code] and reuses the cached config on
## 304. If the server cannot be reached (a network error or a retryable status), the last good
## config is returned with [member TododdleSupportConfigResult.from_cache] set, so the dialog
## still opens offline.
func get_config() -> TododdleSupportConfigResult:
	var result := await _load_config()
	config_loaded.emit(result)
	return result


## Checks [param report] against the contract limits and, when given, [param config]. Returns a
## message per field key; empty means the report is valid. [method send_report] runs the same
## checks.
func validate_report(report: TododdleSupportReport, config: TododdleSupportConfig = null) -> Dictionary:
	return _Validation.validate(report, config)


## Sends [param report], uploading its attachments first if it has any.
##
## Pass the [param config] the player filled in. Without it the client uses the config for the
## report's [member TododdleSupportReport.form_version], loading it first if needed. Problems found
## before sending come back as [constant TododdleSupportResult.INVALID_FIELDS] with a message per
## field. Every attempt reuses the report's idempotency key, so retries never create a second
## ticket.
func send_report(report: TododdleSupportReport, config: TododdleSupportConfig = null) -> TododdleSupportResult:
	var result := await _send_report(report, config)
	report_finished.emit(result)
	return result


## The context sent with [param report]: platform, app version, build, OS, device model, locale,
## screen and extra, cut to the contract's limits.
func build_context(report: TododdleSupportReport) -> Dictionary:
	var context: Dictionary = {"platform": PLATFORM}
	_put(context, "appVersion", report.app_version if not report.app_version.is_empty() else app_version, 50)
	_put(context, "build", report.build if not report.build.is_empty() else build, 50)
	if collect_device_context:
		_put(context, "osName", OS.get_name(), 50)
		_put(context, "osVersion", OS.get_version(), 50)
		var model := OS.get_model_name()
		if model != "GenericDevice":
			_put(context, "deviceModel", model, 100)
		_put(context, "locale", _locale_tag(OS.get_locale()), 35)
	var screen := report.screen
	for separator: String in ["?", "#"]:
		var at := screen.find(separator)
		if at >= 0:
			screen = screen.left(at)
	_put(context, "screen", screen, 200)
	var extra: Dictionary = {}
	for name: Variant in report.extra:
		if extra.size() >= _MAX_EXTRA:
			break
		var key_text := str(name).strip_edges()
		if key_text.is_empty():
			continue
		extra[key_text] = _Validation.clip(str(report.extra[name]), _MAX_EXTRA_VALUE)
	if not extra.is_empty():
		context["extra"] = extra
	return context


# --- Config -----------------------------------------------------------------------------------


func _load_config() -> TododdleSupportConfigResult:
	var problem := _config_problem()
	if problem != null:
		return TododdleSupportConfigResult.failed(problem)
	_load_cache()
	var headers: Dictionary = {}
	if not _cached_etag.is_empty() and not _cached_body.is_empty():
		headers["If-None-Match"] = _cached_etag
	var outcome := await _send("GET", _url("/config"), headers, PackedByteArray(), true, _is_config_status)
	if not outcome.ok:
		if outcome.error.is_transient():
			var fallback := _cached_config()
			if fallback != null:
				_config = fallback
				return TododdleSupportConfigResult.loaded(fallback, true)
		return TododdleSupportConfigResult.failed(outcome.error)

	if outcome.response.status == 304:
		var cached := _cached_config()
		if cached == null:
			return TododdleSupportConfigResult.failed(_invalid_response("304 without a cached config"))
		_config = cached
		return TododdleSupportConfigResult.loaded(cached, false)

	var body := outcome.response.body_text()
	var config := TododdleSupportConfig.parse(_parse_json(body))
	if config == null:
		return TododdleSupportConfigResult.failed(_invalid_response("the config is not valid"))
	_config = config
	_cached_body = body
	_cached_etag = str(outcome.response.headers.get("etag", ""))
	_save_cache()
	return TododdleSupportConfigResult.loaded(config, false)


func _cached_config() -> TododdleSupportConfig:
	if _cached_body.is_empty():
		return null
	return TododdleSupportConfig.parse(_parse_json(_cached_body))


func _load_cache() -> void:
	if _cache_loaded:
		return
	_cache_loaded = true
	if config_cache_path.is_empty() or not FileAccess.file_exists(config_cache_path):
		return
	var text := FileAccess.get_file_as_string(config_cache_path)
	var stored: Variant = _parse_json(text)
	if stored is Dictionary and stored.get("body") is String:
		_cached_body = stored["body"]
		_cached_etag = str(stored.get("etag", ""))


func _save_cache() -> void:
	if config_cache_path.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(config_cache_path.get_base_dir())
	var file := FileAccess.open(config_cache_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({"etag": _cached_etag, "body": _cached_body}))
	file.close()


## Removes the cached config from memory and from [code]user://[/code].
func clear_config_cache() -> void:
	_config = null
	_cached_body = ""
	_cached_etag = ""
	_cache_loaded = true
	if not config_cache_path.is_empty() and FileAccess.file_exists(config_cache_path):
		DirAccess.remove_absolute(config_cache_path)


# --- Reports ----------------------------------------------------------------------------------


func _send_report(report: TododdleSupportReport, config: TododdleSupportConfig) -> TododdleSupportResult:
	if report == null:
		return TododdleSupportResult.failure(TododdleSupportResult.INVALID_FIELDS, "No report to send.")
	var problem := _config_problem()
	if problem != null:
		return problem

	var form_version := report.form_version
	if config != null:
		if form_version == 0:
			form_version = config.form_version
	elif form_version == 0:
		var loaded := await _load_config()
		if not loaded.ok:
			var failed := TododdleSupportResult.new()
			failed.copy_error_from(loaded)
			return failed
		config = loaded.config
		form_version = config.form_version
	else:
		_load_cache()
		var known := _config if _config != null else _cached_config()
		if known != null and known.form_version == form_version:
			config = known

	var errors := _Validation.validate(report, config)
	if not errors.is_empty():
		return TododdleSupportResult.failure(
			TododdleSupportResult.INVALID_FIELDS, "Check the highlighted fields.", errors
		)

	var request := _report_request(report, form_version)
	var created := await _send("POST", _url("/reports"), {}, _json_bytes(request), true, _is_created_status)
	if not created.ok:
		return created.error
	var response := _parse_report_response(created.response)
	if response.is_empty():
		return _invalid_response("the report response is not valid")
	if response["status"] == "received":
		return TododdleSupportResult.received(response["reportId"])
	if response["status"] != "awaiting_uploads":
		return _invalid_response("unknown report status %s" % response["status"])

	var submit_token: Variant = response.get("submitToken")
	var uploads: Variant = response.get("uploads")
	if not submit_token is String or not uploads is Array or (uploads as Array).size() != report.attachments.size():
		return _invalid_response("the uploads do not match the declared attachments")
	# Check every upload before sending any file.
	for upload: Variant in uploads:
		if not upload is Dictionary or not (upload as Dictionary).get("uploadUrl") is String:
			return _invalid_response("an upload has no uploadUrl")
		if not is_allowed_url(str((upload as Dictionary)["uploadUrl"])):
			return _invalid_response("the upload URL must use HTTPS")
	for i in report.attachments.size():
		var upload: Dictionary = (uploads as Array)[i]
		var upload_headers := upload_headers_to_send(upload.get("headers"))
		var put := await _send(
			"PUT",
			str(upload["uploadUrl"]),
			upload_headers,
			report.attachments[i].bytes,
			false,
			_is_success_status,
			TododdleSupportResult.UPLOAD_FAILED
		)
		if not put.ok:
			return put.error

	var report_id: String = response["reportId"]
	var submitted := await _send(
		"POST",
		_url("/reports/%s/submit" % report_id.uri_encode()),
		{},
		_json_bytes({"submitToken": submit_token}),
		true,
		_is_ok_status
	)
	if not submitted.ok:
		return submitted.error
	var final := _parse_report_response(submitted.response)
	if final.is_empty() or final["status"] != "received":
		return _invalid_response("submit did not return a received report")
	return TododdleSupportResult.received(final["reportId"])


func _report_request(report: TododdleSupportReport, form_version: int) -> Dictionary:
	var request: Dictionary = {
		"idempotencyKey": report.idempotency_key,
		"type": report.type,
		"formVersion": form_version,
	}
	var title := report.title.strip_edges()
	if not title.is_empty():
		request["title"] = title
	var description := report.description.strip_edges()
	if not description.is_empty():
		request["description"] = description
	var values: Dictionary = {}
	for name: Variant in report.fields:
		var value := str(report.fields[name]).strip_edges()
		if not value.is_empty():
			values[str(name)] = value
	if not values.is_empty():
		request["fields"] = values
	request["context"] = build_context(report)
	var reporter: Dictionary = {}
	if not report.reporter_name.strip_edges().is_empty():
		reporter["name"] = report.reporter_name.strip_edges()
	if not report.reporter_email.strip_edges().is_empty():
		reporter["email"] = report.reporter_email.strip_edges()
	if not report.customer_reference.strip_edges().is_empty():
		reporter["customerReference"] = report.customer_reference.strip_edges()
	if not reporter.is_empty():
		request["reporter"] = reporter
	if not report.attachments.is_empty():
		var declared: Array = []
		for attachment in report.attachments:
			declared.append(
				{
					"fileName": attachment.file_name,
					"contentType": attachment.content_type,
					"size": attachment.get_size(),
				}
			)
		request["attachments"] = declared
	return request


## Returns {reportId, status, submitToken?, uploads?} or an empty dictionary.
func _parse_report_response(response: _Http.Response) -> Dictionary:
	var parsed: Variant = _parse_json(response.body_text())
	if not parsed is Dictionary:
		return {}
	var body: Dictionary = parsed
	if not body.get("reportId") is String or not body.get("status") is String:
		return {}
	return body


# --- Transport and retries --------------------------------------------------------------------


class _Outcome:
	extends RefCounted
	var ok: bool = false
	var response: _Http.Response = null
	var error: TododdleSupportResult = null


## Sends one call with retries per [member retry_policy].
func _send(
	method: String,
	url: String,
	headers: Dictionary,
	body: PackedByteArray,
	sdk_headers: bool,
	accept: Callable,
	failure_code: String = ""
) -> _Outcome:
	var outcome := _Outcome.new()
	var attempt := 1
	while true:
		var all_headers: Dictionary = {}
		if sdk_headers:
			all_headers["X-Tododdle-Key"] = key
			all_headers["X-Tododdle-Sdk"] = sdk_header()
			if not app_id.is_empty():
				all_headers["X-Tododdle-App-Id"] = app_id
			all_headers["Accept"] = "application/json"
			if not body.is_empty():
				all_headers["Content-Type"] = "application/json"
		all_headers.merge(headers, true)

		var response: _Http.Response = await _Http.new().request(method, url, all_headers, body, timeout_seconds)
		var error: TododdleSupportResult
		var retry_after := -1
		if response.network_error.is_empty():
			if accept.call(response.status):
				outcome.ok = true
				outcome.response = response
				return outcome
			retry_after = TododdleSupportRetryPolicy.parse_retry_after(str(response.headers.get("retry-after", "")))
			error = _error_from(response, retry_after, failure_code)
		else:
			error = TododdleSupportResult.failure(
				TododdleSupportResult.NETWORK_ERROR, "The request failed: %s" % response.network_error
			)

		outcome.error = error
		var retryable := error.error_code == TododdleSupportResult.NETWORK_ERROR or retry_policy.is_retry_status(error.http_status)
		if not retryable:
			return outcome
		if retry_after > retry_policy.max_retry_after_seconds:
			# Too long to wait inside one call: let the game try again later.
			error.error_code = TododdleSupportResult.RATE_LIMITED
			return outcome
		if attempt >= retry_policy.max_attempts:
			return outcome
		var wait := float(retry_after) if retry_after >= 0 else retry_policy.backoff_for(attempt - 1)
		await _delay(wait)
		attempt += 1
	return outcome


func _error_from(response: _Http.Response, retry_after: int, failure_code: String) -> TododdleSupportResult:
	var status := response.status
	var result: TododdleSupportResult = null
	if failure_code.is_empty():
		var parsed: Variant = _parse_json(response.body_text())
		if parsed is Dictionary and (parsed as Dictionary).get("error") is Dictionary:
			var error: Dictionary = (parsed as Dictionary)["error"]
			var code: Variant = error.get("code")
			if code is String and not (code as String).is_empty():
				var field_errors: Dictionary = {}
				var raw_fields: Variant = error.get("fields")
				if raw_fields is Dictionary:
					for name: Variant in raw_fields:
						field_errors[str(name)] = str(raw_fields[name])
				result = TododdleSupportResult.failure(code, str(error.get("message", "")), field_errors)
				var request_id: Variant = error.get("requestId")
				if request_id is String:
					result.request_id = request_id
	if result == null:
		var code := failure_code
		if status == 429:
			code = TododdleSupportResult.RATE_LIMITED
		elif code.is_empty():
			code = TododdleSupportResult.HTTP_ERROR
		result = TododdleSupportResult.failure(code, "The server answered with HTTP %d." % status)
	result.http_status = status
	result.retry_after_seconds = retry_after
	return result


func _delay(seconds: float) -> void:
	if seconds <= 0.0:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	# Runs while the game is paused and ignores Engine.time_scale.
	await tree.create_timer(seconds, true, false, true).timeout


# --- Helpers ----------------------------------------------------------------------------------


func _url(path: String) -> String:
	return base_url.trim_suffix("/") + path


static func _is_config_status(status: int) -> bool:
	return status == 200 or status == 304


static func _is_created_status(status: int) -> bool:
	return status == 200 or status == 201


static func _is_ok_status(status: int) -> bool:
	return status == 200


static func _is_success_status(status: int) -> bool:
	return status >= 200 and status < 300


static func _parse_json(text: String) -> Variant:
	if text.is_empty():
		return null
	var json := JSON.new()
	if json.parse(text) != OK:
		return null
	return json.data


static func _json_bytes(value: Variant) -> PackedByteArray:
	return JSON.stringify(value).to_utf8_buffer()


static func _put(context: Dictionary, name: String, value: String, max_length: int) -> void:
	var trimmed := value.strip_edges()
	if not trimmed.is_empty():
		context[name] = _Validation.clip(trimmed, max_length)


## "en_GB.UTF-8" becomes "en-GB".
static func _locale_tag(locale: String) -> String:
	var tag := locale
	for separator: String in [".", "@"]:
		var at := tag.find(separator)
		if at >= 0:
			tag = tag.left(at)
	return tag.replace("_", "-")


## Whether [param url] is HTTPS, or plain HTTP to a loopback host (127.0.0.1, ::1, localhost).
static func is_allowed_url(url: String) -> bool:
	var target := _Http._parse_url(url)
	if target.is_empty():
		return false
	return target["tls"] or LOOPBACK_HOSTS.has(str(target["host"]).to_lower())


## The server-supplied upload [param headers] the client sends: without [code]Host[/code],
## [code]Authorization[/code], [code]Cookie[/code], [code]Proxy-*[/code], [code]Connection[/code],
## [code]Transfer-Encoding[/code] and [code]Content-Length[/code].
static func upload_headers_to_send(headers: Variant) -> Dictionary:
	var out: Dictionary = {}
	if not headers is Dictionary:
		return out
	for name: Variant in headers:
		var lower := str(name).strip_edges().to_lower()
		if _BLOCKED_UPLOAD_HEADERS.has(lower) or lower.begins_with("proxy-"):
			continue
		out[str(name)] = str(headers[name])
	return out


## Null when the key and base URL can be used, otherwise a NOT_CONFIGURED result.
func _config_problem() -> TododdleSupportResult:
	if key.is_empty():
		return _not_configured()
	var known_prefix := false
	for prefix in KEY_PREFIXES:
		if key.begins_with(prefix):
			known_prefix = true
	if not known_prefix:
		return TododdleSupportResult.failure(
			TododdleSupportResult.NOT_CONFIGURED, "The key must start with tdsk_pub_ or tdsk_test_."
		)
	if not is_allowed_url(base_url):
		return TododdleSupportResult.failure(
			TododdleSupportResult.NOT_CONFIGURED,
			"The base URL must use HTTPS. Plain HTTP is allowed only for 127.0.0.1, ::1 and localhost."
		)
	return null


static func _not_configured() -> TododdleSupportResult:
	return TododdleSupportResult.failure(
		TododdleSupportResult.NOT_CONFIGURED,
		"No ToDoddle Support key. Set tododdle_support/key in Project Settings or pass one."
	)


static func _invalid_response(detail: String) -> TododdleSupportResult:
	return TododdleSupportResult.failure(TododdleSupportResult.INVALID_RESPONSE, "Unexpected response: %s" % detail)
