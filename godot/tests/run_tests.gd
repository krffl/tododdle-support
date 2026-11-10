extends SceneTree
## Runs every test_* method in the test files below, headless, and exits with 1 on any failure.
##
##   godot --headless --path godot --script res://tests/run_tests.gd
##
## Needs the mock server's URL in TODODDLE_MOCK_URL; godot/run-tests.sh starts it.
## Pass a name filter after "--", for example: ... --script res://tests/run_tests.gd -- dialog

const TEST_FILES: Array[String] = [
	"res://tests/test_conformance.gd",
	"res://tests/test_client.gd",
	"res://tests/test_models.gd",
	"res://tests/test_dialog.gd",
]


func _initialize() -> void:
	_run()


func _run() -> void:
	var mock_url := OS.get_environment("TODODDLE_MOCK_URL").trim_suffix("/")
	if mock_url.is_empty():
		printerr("TODODDLE_MOCK_URL is not set. Run godot/run-tests.sh.")
		quit(2)
		return
	var cases_path := ProjectSettings.globalize_path("res://").path_join("../contract/cases/cases.json")
	var suite: Variant = JSON.parse_string(FileAccess.get_file_as_string(cases_path))
	if not suite is Dictionary:
		printerr("Could not read %s" % cases_path)
		quit(2)
		return

	var filter := ""
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		filter = args[0]

	var passed := 0
	var failed := 0
	for path in TEST_FILES:
		var script := load(path) as GDScript
		if script == null:
			printerr("FAIL %s did not load" % path)
			failed += 1
			continue
		var names: Array[String] = []
		for method in script.get_script_method_list():
			var name: String = method["name"]
			if name.begins_with("test_") and not names.has(name):
				names.append(name)
		for name in names:
			var full := "%s:%s" % [path.get_file().get_basename(), name]
			if not filter.is_empty() and not full.contains(filter):
				continue
			var test: RefCounted = script.new()
			test.set("mock_url", mock_url)
			test.set("suite", suite)
			var started := Time.get_ticks_msec()
			await test.call(name)
			test.call("cleanup")
			var problems: PackedStringArray = test.get("failures")
			var elapsed := Time.get_ticks_msec() - started
			if problems.is_empty():
				passed += 1
				print("PASS %s (%d ms)" % [full, elapsed])
			else:
				failed += 1
				print("FAIL %s (%d ms)" % [full, elapsed])
				for problem in problems:
					print("     - %s" % problem)
	print("")
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)
