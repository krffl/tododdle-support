extends "res://tests/test_base.gd"
## Client behaviour beyond the shared cases: headers, context, attachments, field errors,
## Retry-After, retries and the offline config.

const PNG_BASE64 := "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
const UNREACHABLE := "http://127.0.0.1:9"


func _fast(client: TododdleSupport) -> TododdleSupport:
	client.retry_policy.backoff_seconds = [0.05, 0.05, 0.05]
	return client


func _config_exchange(etag: String = "\"cfg-3\"") -> Dictionary:
	return {
		"request": {"method": "GET", "path": "/config"},
		"response": {"status": 200, "headers": {"ETag": etag}, "body": "$config"},
	}


func _received(id: String) -> Dictionary:
	return {"status": 201, "body": {"reportId": id, "status": "received"}}


func test_report_without_attachments_sends_headers_and_context() -> void:
	await load_exchanges([{"request": {"method": "POST", "path": "/reports"}, "response": _received("rpt_BBBBBBBBBBBBBBBB0001")}])
	var client := new_client()
	client.app_id = "com.example.game"
	var report := shared_report()
	report.title = "  Favourites vanish  "
	report.extra = {"seed": 1234, "difficulty": "hard"}
	var result := await client.send_report(report, shared_config())
	check(result.ok, str(result))
	check_eq(result.report_id, "rpt_BBBBBBBBBBBBBBBB0001", "reportId")
	var state := await mock_state()
	check_mock_clean(state)
	var request: Dictionary = (state["requests"] as Array)[0]
	var headers: Dictionary = request["headers"]
	check_eq(headers.get("x-tododdle-app-id"), "com.example.game", "X-Tododdle-App-Id")
	check_eq(headers.get("content-type"), "application/json", "Content-Type")
	var body: Dictionary = request_json(request)
	check_eq(body["idempotencyKey"], report.idempotency_key, "idempotencyKey")
	check_eq(body["title"], "Favourites vanish", "title is trimmed")
	check_eq(int(body["formVersion"]), 3, "formVersion")
	check(not body.has("attachments"), "no attachments declared")
	var context: Dictionary = body["context"]
	check_eq(context["platform"], "godot", "platform")
	check_eq(context["appVersion"], "2.4.0", "appVersion from the report")
	check_eq(context["build"], "118", "build")
	check_eq(context["screen"], "Favourites", "screen")
	check_eq(context["osName"], OS.get_name(), "osName")
	check_eq(context["extra"], {"seed": "1234", "difficulty": "hard"}, "extra as text")
	check_eq(body["reporter"], {"name": "Alex", "customerReference": "user-42"}, "reporter")


func test_app_id_header_is_left_out_when_empty() -> void:
	await load_exchanges([{"request": {"method": "POST", "path": "/reports"}, "response": _received("rpt_BBBBBBBBBBBBBBBB0002")}])
	var result := await new_client().send_report(shared_report(), shared_config())
	check(result.ok, str(result))
	var state := await mock_state()
	var headers: Dictionary = ((state["requests"] as Array)[0] as Dictionary)["headers"]
	check(not headers.has("x-tododdle-app-id"), "no X-Tododdle-App-Id")


func test_report_with_screenshot_and_log() -> void:
	var image := Image.create(4, 3, false, Image.FORMAT_RGB8)
	image.fill(Color.CORNFLOWER_BLUE)
	var screenshot := TododdleSupportAttachment.from_image(image)
	var log_attachment := TododdleSupportAttachment.from_text("frame 1: 16 ms\nframe 2: 120 ms\n", "hitch_log.txt")
	var report := shared_report().add_attachment(screenshot).add_attachment(log_attachment)
	await load_exchanges(
		[
			{
				"request": {
					"method": "POST",
					"path": "/reports",
					"must": {"body": ["attachments.0.fileName", "attachments.1.fileName"]},
				},
				"response": {
					"status": 201,
					"body": {
						"reportId": "rpt_BBBBBBBBBBBBBBBB0003",
						"status": "awaiting_uploads",
						"submitToken": "st_0123456789abcdef0123456789abcdef",
						"expiresAt": "2099-01-01T00:00:00Z",
						"uploads": [
							{"uploadUrl": "{{baseUrl}}/upload/a?sig=1", "headers": {"Content-Type": "image/png", "x-amz-meta-test": "yes", "Authorization": "Bearer leaked", "Cookie": "session=1", "Proxy-Authorization": "Basic eA==", "Host": "evil.example"}, "expiresAt": "2099-01-01T00:00:00Z"},
							{"uploadUrl": "{{baseUrl}}/upload/b", "headers": {"Content-Type": "text/plain"}, "expiresAt": "2099-01-01T00:00:00Z"},
						],
					},
				},
			},
			{
				"request": {"method": "PUT", "path": "/upload/a", "must": {"headers": {"Content-Type": "image/png", "x-amz-meta-test": "yes"}, "rawBodyBase64": "$attachment"}},
				"response": {"status": 200},
			},
			{
				"request": {"method": "PUT", "path": "/upload/b", "must": {"headers": {"Content-Type": "text/plain"}, "rawBodyBase64": Marshalls.raw_to_base64(log_attachment.bytes)}},
				"response": {"status": 204},
			},
			{
				"request": {"method": "POST", "path": "/reports/rpt_BBBBBBBBBBBBBBBB0003/submit", "must": {"body": {"submitToken": "st_0123456789abcdef0123456789abcdef"}}},
				"response": {"status": 200, "body": {"reportId": "rpt_BBBBBBBBBBBBBBBB0003", "status": "received"}},
			},
		],
		Marshalls.raw_to_base64(screenshot.bytes)
	)
	var result := await new_client().send_report(report, shared_config())
	check(result.ok, str(result))
	check_eq(result.report_id, "rpt_BBBBBBBBBBBBBBBB0003", "reportId")
	var state := await mock_state()
	check_mock_clean(state)
	var body: Dictionary = request_json((state["requests"] as Array)[0])
	var declared: Array = body["attachments"]
	check_eq(declared[0], {"fileName": "screenshot.png", "contentType": "image/png", "size": float(screenshot.get_size())}, "screenshot declared")
	check_eq(declared[1], {"fileName": "hitch_log.txt", "contentType": "text/plain", "size": float(log_attachment.get_size())}, "log declared")
	for request: Dictionary in state["requests"]:
		if str(request["path"]).begins_with("/upload/"):
			var headers: Dictionary = request["headers"]
			check(not headers.has("x-tododdle-key") and not headers.has("x-tododdle-sdk"), "uploads carry no SDK headers")
			for blocked: String in ["authorization", "cookie", "proxy-authorization"]:
				check(not headers.has(blocked), "upload drops the server's %s header" % blocked)
			check(str(headers.get("host", "")).begins_with("127.0.0.1"), "upload keeps its own Host")


func test_upload_url_over_plain_http_is_refused() -> void:
	await load_exchanges(
		[
			{
				"request": {"method": "POST", "path": "/reports"},
				"response": {
					"status": 201,
					"body": {
						"reportId": "rpt_BBBBBBBBBBBBBBBB0009",
						"status": "awaiting_uploads",
						"submitToken": "st_0123456789abcdef0123456789abcdef",
						"expiresAt": "2099-01-01T00:00:00Z",
						"uploads": [{"uploadUrl": "http://10.0.0.5/upload/x", "headers": {}, "expiresAt": "2099-01-01T00:00:00Z"}],
					},
				},
			},
		]
	)
	var report := shared_report().add_attachment(TododdleSupportAttachment.from_text("hello\n", "note.txt"))
	var result := await new_client().send_report(report, shared_config())
	check_eq(result.error_code, TododdleSupportResult.INVALID_RESPONSE, "code")
	check_eq((( await mock_state())["requests"] as Array).size(), 1, "no upload sent")


func test_redirect_is_not_followed() -> void:
	await load_exchanges(
		[
			{
				"request": {"method": "POST", "path": "/reports"},
				"response": {"status": 302, "headers": {"Location": "{{baseUrl}}/elsewhere"}},
			},
		]
	)
	var result := await _fast(new_client()).send_report(shared_report(), shared_config())
	check_eq(result.error_code, TododdleSupportResult.HTTP_ERROR, "code")
	check_eq(result.http_status, 302, "status")
	check_eq(((await mock_state())["requests"] as Array).size(), 1, "one request, no redirect followed")


func test_key_with_unknown_prefix_is_not_configured() -> void:
	await load_exchanges([])
	for bad_key: String in ["pk_live_123", "tdsk_secret_123", "TDSK_PUB_123"]:
		var client := new_client()
		client.key = bad_key
		var result := await client.send_report(shared_report(), shared_config())
		check_eq(result.error_code, TododdleSupportResult.NOT_CONFIGURED, "report with %s" % bad_key)
		var config_result := await client.get_config()
		check_eq(config_result.error_code, TododdleSupportResult.NOT_CONFIGURED, "config with %s" % bad_key)
	var test_key := new_client()
	test_key.key = "tdsk_test_ABC"
	check(test_key._config_problem() == null, "tdsk_test_ keys are accepted")
	check_eq(((await mock_state())["requests"] as Array).size(), 0, "nothing sent")


func test_plain_http_base_url_is_not_configured() -> void:
	var client := new_client("http://api.example.com/api/support/sdk/v1")
	var result := await client.send_report(shared_report(), shared_config())
	check_eq(result.error_code, TododdleSupportResult.NOT_CONFIGURED, "report")
	var config_result := await client.get_config()
	check_eq(config_result.error_code, TododdleSupportResult.NOT_CONFIGURED, "config")


func test_field_errors_from_422_invalid_fields() -> void:
	await load_exchanges(
		[
			{
				"request": {"method": "POST", "path": "/reports"},
				"response": {"status": 422, "body": {"error": {"code": "INVALID_FIELDS", "message": "Check the fields.", "fields": {"description": "Too short.", "area": "Choose one."}, "requestId": "req_123"}}},
			}
		]
	)
	var result := await new_client().send_report(shared_report(), shared_config())
	check(not result.ok, "fails")
	check_eq(result.error_code, TododdleSupportResult.INVALID_FIELDS, "code")
	check_eq(result.fields, {"description": "Too short.", "area": "Choose one."}, "fields")
	check_eq(result.http_status, 422, "status")
	check_eq(result.request_id, "req_123", "requestId")
	check(not result.is_transient(), "not transient")
	var state := await mock_state()
	check_eq((state["requests"] as Array).size(), 1, "not retried")


func test_field_errors_from_422_fields_changed() -> void:
	await load_exchanges(
		[
			{
				"request": {"method": "POST", "path": "/reports"},
				"response": {"status": 422, "body": {"error": {"code": "FIELDS_CHANGED", "message": "The form changed.", "fields": {"platform-choice": "Choose a platform."}}}},
			}
		]
	)
	var result := await new_client().send_report(shared_report(), shared_config())
	check_eq(result.error_code, TododdleSupportResult.FIELDS_CHANGED, "code")
	check_eq(result.fields, {"platform-choice": "Choose a platform."}, "fields")


func test_client_side_validation_sends_nothing() -> void:
	await load_exchanges([])
	var report := shared_report()
	report.description = "   "
	report.fields = {"area": "Moon"}
	report.title = "x".repeat(161)
	var result := await new_client().send_report(report, shared_config())
	check_eq(result.error_code, TododdleSupportResult.INVALID_FIELDS, "code")
	check_eq(result.http_status, 0, "no HTTP status")
	check(result.fields.has("description"), "description error")
	check(result.fields.has("area"), "select option error")
	check(result.fields.has("title"), "title length error")
	var state := await mock_state()
	check_eq((state["requests"] as Array).size(), 0, "no request")


func test_rate_limited_waits_for_retry_after() -> void:
	await load_exchanges(
		[
			{"request": {"method": "POST", "path": "/reports"}, "response": {"status": 429, "headers": {"Retry-After": "1"}}},
			{"request": {"method": "POST", "path": "/reports", "must": {"sameIdempotencyKeyAsPrevious": true}}, "response": _received("rpt_BBBBBBBBBBBBBBBB0004")},
		]
	)
	var client := _fast(new_client())
	var started := Time.get_ticks_msec()
	var result := await client.send_report(shared_report(), shared_config())
	check(result.ok, str(result))
	check(Time.get_ticks_msec() - started >= 900, "waited for Retry-After, not the short backoff")
	check_mock_clean(await mock_state())


func test_retry_after_over_60_fails_at_once() -> void:
	await load_exchanges(
		[
			{
				"request": {"method": "POST", "path": "/reports"},
				"response": {"status": 429, "headers": {"Retry-After": "120"}, "body": {"error": {"code": "RATE_LIMITED", "message": "Slow down."}}},
			}
		]
	)
	var started := Time.get_ticks_msec()
	var result := await new_client().send_report(shared_report(), shared_config())
	check(Time.get_ticks_msec() - started < 900, "did not wait")
	check_eq(result.error_code, TododdleSupportResult.RATE_LIMITED, "code")
	check_eq(result.retry_after_seconds, 120, "retryAfterSeconds")
	check_eq(result.http_status, 429, "status")
	var state := await mock_state()
	check_eq((state["requests"] as Array).size(), 1, "one attempt")


func test_retry_after_over_60_on_503_also_fails_with_rate_limited() -> void:
	await load_exchanges([{"request": {"method": "POST", "path": "/reports"}, "response": {"status": 503, "headers": {"Retry-After": "61"}}}])
	var result := await new_client().send_report(shared_report(), shared_config())
	check_eq(result.error_code, TododdleSupportResult.RATE_LIMITED, "code")
	check_eq(result.retry_after_seconds, 61, "retryAfterSeconds")
	check_eq(result.http_status, 503, "status")


func test_429_without_body_is_rate_limited() -> void:
	await load_exchanges(
		[
			{"request": {"method": "POST", "path": "/reports"}, "response": {"status": 429}},
			{"request": {"method": "POST", "path": "/reports"}, "response": {"status": 429}},
			{"request": {"method": "POST", "path": "/reports"}, "response": {"status": 429}},
		]
	)
	var result := await _fast(new_client()).send_report(shared_report(), shared_config())
	check_eq(result.error_code, TododdleSupportResult.RATE_LIMITED, "code")
	check_eq(result.retry_after_seconds, -1, "no Retry-After")
	check(result.is_transient(), "transient")
	check_mock_clean(await mock_state())


func test_at_most_three_attempts_with_the_same_key() -> void:
	var must := {"sameIdempotencyKeyAsPrevious": true}
	await load_exchanges(
		[
			{"request": {"method": "POST", "path": "/reports"}, "response": {"status": 500}},
			{"request": {"method": "POST", "path": "/reports", "must": must}, "response": {"status": 502}},
			{"request": {"method": "POST", "path": "/reports", "must": must}, "response": {"status": 504}},
		]
	)
	var result := await _fast(new_client()).send_report(shared_report(), shared_config())
	check_eq(result.error_code, TododdleSupportResult.HTTP_ERROR, "code")
	check_eq(result.http_status, 504, "last status")
	check_mock_clean(await mock_state())


func test_other_5xx_is_not_retried() -> void:
	await load_exchanges([{"request": {"method": "POST", "path": "/reports"}, "response": {"status": 501}}])
	var result := await _fast(new_client()).send_report(shared_report(), shared_config())
	check_eq(result.error_code, TododdleSupportResult.HTTP_ERROR, "code")
	check_eq((await mock_state())["requests"].size(), 1, "one attempt")


func test_conflict_is_not_retried() -> void:
	await load_exchanges(
		[
			{
				"request": {"method": "POST", "path": "/reports"},
				"response": {"status": 409, "body": {"error": {"code": "IDEMPOTENCY_KEY_REUSED", "message": "Reused."}}},
			}
		]
	)
	var result := await _fast(new_client()).send_report(shared_report(), shared_config())
	check_eq(result.error_code, TododdleSupportResult.IDEMPOTENCY_KEY_REUSED, "code")
	check_eq((await mock_state())["requests"].size(), 1, "one attempt")


func test_failed_upload_is_retried_then_reported() -> void:
	var report := shared_report().add_attachment(TododdleSupportAttachment.from_text("hello", "note.txt"))
	await load_exchanges(
		[
			{
				"request": {"method": "POST", "path": "/reports"},
				"response": {
					"status": 201,
					"body": {
						"reportId": "rpt_BBBBBBBBBBBBBBBB0005",
						"status": "awaiting_uploads",
						"submitToken": "st_0123456789abcdef0123456789abcdef",
						"expiresAt": "2099-01-01T00:00:00Z",
						"uploads": [{"uploadUrl": "{{baseUrl}}/upload/x", "headers": {"Content-Type": "text/plain"}, "expiresAt": "2099-01-01T00:00:00Z"}],
					},
				},
			},
			{"request": {"method": "PUT", "path": "/upload/x"}, "response": {"status": 500}},
			{"request": {"method": "PUT", "path": "/upload/x"}, "response": {"status": 500}},
			{"request": {"method": "PUT", "path": "/upload/x"}, "response": {"status": 500}},
		]
	)
	var result := await _fast(new_client()).send_report(report, shared_config())
	check_eq(result.error_code, TododdleSupportResult.UPLOAD_FAILED, "code")
	check_eq(result.http_status, 500, "status")
	check_mock_clean(await mock_state())


func test_network_error_is_retried_and_reported() -> void:
	var client := _fast(new_client(UNREACHABLE))
	client.timeout_seconds = 5.0
	var result := await client.send_report(shared_report(), shared_config())
	check_eq(result.error_code, TododdleSupportResult.NETWORK_ERROR, "code")
	check(result.is_transient(), "transient")


func test_missing_key_is_not_configured() -> void:
	var client := new_client()
	client.key = ""
	var result := await client.send_report(shared_report(), shared_config())
	check_eq(result.error_code, TododdleSupportResult.NOT_CONFIGURED, "report")
	var config_result := await client.get_config()
	check_eq(config_result.error_code, TododdleSupportResult.NOT_CONFIGURED, "config")


func test_send_report_loads_the_config_when_not_given() -> void:
	await load_exchanges(
		[
			_config_exchange(),
			{"request": {"method": "POST", "path": "/reports", "must": {"body": {"formVersion": 3}}}, "response": _received("rpt_BBBBBBBBBBBBBBBB0006")},
		]
	)
	var result := await new_client().send_report(shared_report())
	check(result.ok, str(result))
	check_mock_clean(await mock_state())


func test_signals_are_emitted() -> void:
	await load_exchanges([_config_exchange(), {"request": {"method": "POST", "path": "/reports"}, "response": _received("rpt_BBBBBBBBBBBBBBBB0007")}])
	var client := new_client()
	var seen: Array[String] = []
	client.config_loaded.connect(func(r: TododdleSupportConfigResult) -> void: seen.append("config:%s" % r.status))
	client.report_finished.connect(func(r: TododdleSupportResult) -> void: seen.append("report:%s" % r.report_id))
	var config_result := await client.get_config()
	await client.send_report(shared_report(), config_result.config)
	check_eq(seen, ["config:loaded", "report:rpt_BBBBBBBBBBBBBBBB0007"] as Array[String], "signals")


func test_offline_config_fallback_after_restart() -> void:
	var cache_path := new_cache_path()
	await load_exchanges([_config_exchange("\"cfg-9\"")])
	var first := await new_client("", cache_path).get_config()
	check(first.ok and not first.from_cache, "first load from the server")
	check(FileAccess.file_exists(cache_path), "config cached to user://")

	# A new client (as after a restart) with no network uses the cached copy.
	var offline := _fast(new_client(UNREACHABLE, cache_path))
	offline.timeout_seconds = 5.0
	var result := await offline.get_config()
	check(result.ok, str(result))
	check(result.from_cache, "from_cache")
	check_eq(result.status, TododdleSupportConfigResult.STATUS_CACHED, "status")
	check_eq(result.config.form_version, 3, "form version")
	check_eq(offline.get_cached_config(), result.config, "cached config kept in memory")


func test_offline_config_fallback_on_503() -> void:
	var cache_path := new_cache_path()
	await load_exchanges([_config_exchange()])
	await new_client("", cache_path).get_config()
	await load_exchanges(
		[
			{"request": {"method": "GET", "path": "/config", "must": {"headers": {"If-None-Match": "\"cfg-3\""}}}, "response": {"status": 503}},
			{"request": {"method": "GET", "path": "/config"}, "response": {"status": 503}},
			{"request": {"method": "GET", "path": "/config"}, "response": {"status": 503}},
		]
	)
	var result := await _fast(new_client("", cache_path)).get_config()
	check(result.ok and result.from_cache, str(result))
	check_mock_clean(await mock_state())


func test_cached_etag_is_sent_after_restart() -> void:
	var cache_path := new_cache_path()
	await load_exchanges([_config_exchange("\"cfg-7\"")])
	await new_client("", cache_path).get_config()
	await load_exchanges([{"request": {"method": "GET", "path": "/config", "must": {"headers": {"If-None-Match": "\"cfg-7\""}}}, "response": {"status": 304}}])
	var result := await new_client("", cache_path).get_config()
	check(result.ok and not result.from_cache, str(result))
	check_eq(result.config.project_name, "Mosslight", "config from the cache")
	check_mock_clean(await mock_state())


func test_offline_without_cache_fails() -> void:
	var client := _fast(new_client(UNREACHABLE))
	client.timeout_seconds = 5.0
	var result := await client.get_config()
	check(not result.ok, "fails")
	check_eq(result.error_code, TododdleSupportResult.NETWORK_ERROR, "code")


func test_revoked_key_does_not_use_the_cache() -> void:
	var cache_path := new_cache_path()
	await load_exchanges([_config_exchange()])
	await new_client("", cache_path).get_config()
	await load_exchanges([{"request": {"method": "GET", "path": "/config"}, "response": {"status": 401, "body": {"error": {"code": "KEY_REVOKED", "message": "Revoked."}}}}])
	var result := await new_client("", cache_path).get_config()
	check_eq(result.error_code, TododdleSupportResult.KEY_REVOKED, "code")
	check(result.config == null, "no config")


func test_invalid_config_body_is_invalid_response() -> void:
	await load_exchanges([{"request": {"method": "GET", "path": "/config"}, "response": {"status": 200, "body": {"project": {}}}}])
	var result := await new_client().get_config()
	check_eq(result.error_code, TododdleSupportResult.INVALID_RESPONSE, "code")


func test_clear_config_cache() -> void:
	var cache_path := new_cache_path()
	await load_exchanges([_config_exchange()])
	var client := new_client("", cache_path)
	await client.get_config()
	client.clear_config_cache()
	check(not FileAccess.file_exists(cache_path), "file removed")
	check(client.get_cached_config() == null, "memory cleared")
