extends "res://tests/test_base.gd"
## The shared conformance cases from contract/cases/cases.json, run against the mock server.


func test_there_are_14_shared_cases() -> void:
	check_eq((suite["cases"] as Array).size(), 14, "shared case count")


func test_retry_policy_matches_cases() -> void:
	var policy := TododdleSupportRetryPolicy.new()
	var shared: Dictionary = suite["retryPolicy"]
	check_eq(policy.max_attempts, int(shared["maxAttempts"]), "maxAttempts")
	var backoff: Array[float] = []
	for value: Variant in shared["backoffSeconds"]:
		backoff.append(float(value))
	check_eq(policy.backoff_seconds, backoff, "backoffSeconds")
	var statuses: Array[int] = []
	for value: Variant in shared["retryStatuses"]:
		statuses.append(int(value))
	check_eq(policy.retry_statuses, statuses, "retryStatuses")
	check_eq(policy.max_retry_after_seconds, 60, "max Retry-After")


func test_all_shared_cases() -> void:
	for item: Variant in suite["cases"]:
		var test_case: Dictionary = item
		var before := failures.size()
		await _run_case(test_case)
		var name: String = test_case["name"]
		if failures.size() == before:
			print("     ok   %s" % name)
		else:
			for i in range(before, failures.size()):
				failures[i] = "%s: %s" % [name, failures[i]]
			print("     FAIL %s" % name)


func _run_case(test_case: Dictionary) -> void:
	await load_case(test_case["name"])
	var client := new_client()
	var operation: String = test_case["operation"]
	var config_result: TododdleSupportConfigResult = null
	var result: TododdleSupportResult = null
	match operation:
		"getConfig":
			config_result = await client.get_config()
			result = config_result
		"getConfigTwice":
			await client.get_config()
			config_result = await client.get_config()
			result = config_result
		"report":
			result = await client.send_report(_case_report(test_case), shared_config())
		"reportWithAttachment":
			var attachment: Dictionary = test_case["attachment"]
			var report := _case_report(test_case)
			report.add_attachment(
				TododdleSupportAttachment.new(
					Marshalls.base64_to_raw(attachment["bytesBase64"]), attachment["fileName"], attachment["contentType"]
				)
			)
			result = await client.send_report(report, shared_config())
		_:
			failures.append("unknown operation %s" % operation)
			return

	var state := await mock_state()
	var want: Dictionary = test_case["expect"]
	var requests: Array = state.get("requests", [])
	check((state.get("failures", []) as Array).is_empty(), "mock failures: %s" % str(state.get("failures")))
	for request: Dictionary in requests:
		var headers: Dictionary = request["headers"]
		if str(request["path"]).begins_with("/upload/"):
			check(not headers.has("x-tododdle-key"), "the upload must not carry the key")
		else:
			check_eq(headers.get("x-tododdle-key"), suite["key"], "X-Tododdle-Key")
			check_eq(headers.get("x-tododdle-sdk"), "godot/" + TododdleSupport.SDK_VERSION, "X-Tododdle-Sdk")

	check_eq(result.ok, want["ok"], "ok (%s)" % str(result))
	if want["ok"]:
		check_eq(int(state.get("remaining", -1)), 0, "exchanges left")
	if want.has("formVersion"):
		check(config_result != null and config_result.config != null, "config loaded")
		if config_result != null and config_result.config != null:
			check_eq(config_result.config.form_version, int(want["formVersion"]), "formVersion")
	if want.has("fieldKeys") and config_result != null and config_result.config != null:
		var keys: Array = []
		for field in config_result.config.fields:
			keys.append(field.key)
		check_eq(keys, want["fieldKeys"], "field keys")
	if want.has("reportId"):
		check_eq(result.status, "received", "status")
		check_eq(result.report_id, want["reportId"], "reportId")
	if not want["ok"]:
		if want.has("errorCode"):
			check_eq(result.error_code, want["errorCode"], "errorCode")
		if want.has("fieldErrors"):
			check_eq(result.fields, want["fieldErrors"], "field errors")
		if want.has("httpStatus"):
			check_eq(result.http_status, int(want["httpStatus"]), "httpStatus")
	if want.has("requests"):
		check_eq(requests.size(), int(want["requests"]), "request count")
	if want.has("minDelayMs") and requests.size() > 1:
		var first: Dictionary = requests[0]
		var last: Dictionary = requests[requests.size() - 1]
		var delay := float(last["at"]) - float(first["at"])
		check(delay >= float(want["minDelayMs"]), "waited %d ms, expected at least %d" % [delay, int(want["minDelayMs"])])


## The shared report, with the case's `screen` when it has one.
func _case_report(test_case: Dictionary) -> TododdleSupportReport:
	var report := shared_report()
	if test_case.get("screen") is String:
		report.screen = test_case["screen"]
	return report
