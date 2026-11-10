extends RefCounted
## Base for the test files: checks, the mock server's control routes and shared fixtures.

const Http := preload("res://addons/tododdle_support/http.gd")

## Set by the runner.
var mock_url: String = ""
## contract/cases/cases.json, parsed.
var suite: Dictionary = {}
## Problems found by the running test.
var failures: PackedStringArray = PackedStringArray()
var _cache_paths: PackedStringArray = PackedStringArray()


func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func check_eq(actual: Variant, expected: Variant, message: String = "") -> void:
	if typeof(actual) != typeof(expected) or actual != expected:
		failures.append("%s: got %s, expected %s" % [message, var_to_str(actual), var_to_str(expected)])


## A client for the mock server, with its own config cache file.
func new_client(base_url: String = "", cache_path: String = "") -> TododdleSupport:
	var client := TododdleSupport.create(str(suite["key"]), base_url if not base_url.is_empty() else mock_url)
	client.config_cache_path = cache_path if not cache_path.is_empty() else new_cache_path()
	return client


func new_cache_path() -> String:
	var path := "user://tododdle_support_tests/config-%s.json" % TododdleSupportReport.new_idempotency_key()
	_cache_paths.append(path)
	return path


func cleanup() -> void:
	for path in _cache_paths:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	_cache_paths.clear()


func shared_config() -> TododdleSupportConfig:
	return TododdleSupportConfig.parse(suite["config"].duplicate(true))


## The shared report from cases.json.
func shared_report() -> TododdleSupportReport:
	var data: Dictionary = suite["report"]
	var report := TododdleSupportReport.new()
	report.type = data["type"]
	report.description = data["description"]
	report.fields = (data["fields"] as Dictionary).duplicate()
	var context: Dictionary = data["context"]
	report.app_version = context.get("appVersion", "")
	report.build = context.get("build", "")
	report.screen = context.get("screen", "")
	var reporter: Dictionary = data["reporter"]
	report.reporter_name = reporter.get("name", "")
	report.customer_reference = reporter.get("customerReference", "")
	return report


## Loads a shared case by name into the mock.
func load_case(name: String) -> void:
	await _control("POST", "/__mock/scenario", {"case": name})


## Loads custom exchanges into the mock.
func load_exchanges(exchanges: Array, attachment_base64: String = "") -> void:
	var body: Dictionary = {"exchanges": exchanges}
	if not attachment_base64.is_empty():
		body["attachmentBase64"] = attachment_base64
	await _control("POST", "/__mock/scenario", body)


## {failures, remaining, requests: [{method, path, headers, at, bodyBase64}]}
func mock_state() -> Dictionary:
	var state: Variant = await _control("GET", "/__mock/state", null)
	return state if state is Dictionary else {}


## The JSON body of a recorded request.
static func request_json(request: Dictionary) -> Variant:
	var raw := Marshalls.base64_to_raw(str(request.get("bodyBase64", "")))
	return JSON.parse_string(raw.get_string_from_utf8()) if not raw.is_empty() else null


## The mock must have seen no problems and served every exchange.
func check_mock_clean(state: Dictionary, served_all: bool = true) -> void:
	var problems: Array = state.get("failures", [])
	check(problems.is_empty(), "mock failures: %s" % str(problems))
	if served_all:
		check_eq(int(state.get("remaining", -1)), 0, "exchanges left in the mock")


func _control(method: String, path: String, body: Variant) -> Variant:
	var bytes := PackedByteArray() if body == null else JSON.stringify(body).to_utf8_buffer()
	var headers: Dictionary = {"Content-Type": "application/json"} if body != null else {}
	var response: Http.Response = await Http.new().request(method, mock_url + path, headers, bytes, 10.0)
	if not response.network_error.is_empty() or response.status != 200:
		failures.append("mock control %s %s failed: %s %d" % [method, path, response.network_error, response.status])
		return null
	return JSON.parse_string(response.body_text())
