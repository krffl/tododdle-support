extends "res://tests/test_base.gd"
## Version sync, settings, models, context and attachment helpers. No network.

const Validation := preload("res://addons/tododdle_support/validation.gd")


func test_sdk_version_matches_version_file() -> void:
	var version_path := ProjectSettings.globalize_path("res://").path_join("../VERSION")
	var version := FileAccess.get_file_as_string(version_path).strip_edges()
	check(not version.is_empty(), "VERSION was read")
	check_eq(TododdleSupport.SDK_VERSION, version, "SDK_VERSION (run npm run sync-version)")
	var plugin := ConfigFile.new()
	check_eq(plugin.load("res://addons/tododdle_support/plugin.cfg"), OK, "plugin.cfg loads")
	check_eq(str(plugin.get_value("plugin", "version", "")), version, "plugin.cfg version")
	var header := TododdleSupport.sdk_header()
	check_eq(header, "godot/" + version, "X-Tododdle-Sdk")
	check(RegEx.create_from_string("^[a-z-]+/[0-9A-Za-z.+-]+$").search(header) != null, "header matches the contract pattern")


func test_idempotency_key_is_a_uuid_v4() -> void:
	var pattern := RegEx.create_from_string("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
	var contract := RegEx.create_from_string("^[A-Za-z0-9_-]{16,64}$")
	var seen: Dictionary = {}
	for i in 50:
		var key := TododdleSupportReport.new_idempotency_key()
		check(pattern.search(key) != null, "UUID v4: %s" % key)
		check(contract.search(key) != null, "contract pattern: %s" % key)
		seen[key] = true
	check_eq(seen.size(), 50, "unique keys")
	var report := TododdleSupportReport.new()
	check_eq(report.idempotency_key, report.idempotency_key, "stable per report")
	check(report.idempotency_key != TododdleSupportReport.new().idempotency_key, "new per report")


func test_settings_fall_back_to_project_settings_and_defaults() -> void:
	var saved_key: Variant = ProjectSettings.get_setting(TododdleSupportSettings.SETTING_KEY, "")
	var saved_url: Variant = ProjectSettings.get_setting(TododdleSupportSettings.SETTING_BASE_URL, "")
	ProjectSettings.set_setting(TododdleSupportSettings.SETTING_KEY, "tdsk_test_FROMSETTINGS")
	ProjectSettings.set_setting(TododdleSupportSettings.SETTING_BASE_URL, "")
	var client := TododdleSupport.new()
	check_eq(client.key, "tdsk_test_FROMSETTINGS", "key from Project Settings")
	check_eq(client.base_url, TododdleSupport.DEFAULT_BASE_URL, "default base URL")
	check_eq(client.app_version, str(ProjectSettings.get_setting("application/config/version")), "app version")

	var settings := TododdleSupportSettings.new()
	settings.key = "tdsk_pub_OVERRIDE"
	settings.base_url = TododdleSupport.STAGING_BASE_URL + "/"
	settings.app_id = "com.example.game"
	settings.cache_config = false
	client = TododdleSupport.new(settings)
	check_eq(client.key, "tdsk_pub_OVERRIDE", "key from the resource")
	check_eq(client.base_url, "https://app-stg.tododdle.com/api/support/sdk/v1", "base URL without trailing slash")
	check_eq(client.app_id, "com.example.game", "app ID")
	check_eq(client.config_cache_path, "", "cache off")
	check_eq(TododdleSupport.create("tdsk_pub_X").key, "tdsk_pub_X", "create()")

	ProjectSettings.set_setting(TododdleSupportSettings.SETTING_KEY, saved_key)
	ProjectSettings.set_setting(TododdleSupportSettings.SETTING_BASE_URL, saved_url)


func test_cache_file_differs_per_key_and_base_url() -> void:
	var a := TododdleSupport.create("tdsk_pub_A", "http://one")
	var b := TododdleSupport.create("tdsk_pub_B", "http://one")
	var c := TododdleSupport.create("tdsk_pub_A", "http://two")
	check(a.config_cache_path.begins_with("user://tododdle_support/"), "in user://")
	check(a.config_cache_path != b.config_cache_path and a.config_cache_path != c.config_cache_path, "separate files")


func test_config_parses_the_shared_config() -> void:
	var config := shared_config()
	check(config != null, "parsed")
	check_eq(config.project_name, "Mosslight", "project")
	check_eq(config.form_version, 3, "version")
	check_eq(config.types.size(), 3, "types")
	check(config.has_type("feedback"), "has feedback")
	check(config.title_enabled and not config.title_required, "title")
	check(config.description_required, "description required")
	check_eq(config.fields.size(), 2, "fields")
	check_eq(config.get_field("area").type, TododdleSupportField.SELECT, "area is SELECT")
	check_eq(config.get_field("area").options, PackedStringArray(["Home", "Settings", "Other"]), "options")
	check_eq(config.get_field("steps").effective_max_length(), 5000, "steps max length")
	check(config.accepts_content_type("text/plain"), "text accepted")
	check_eq(config.attachments_max_bytes, 10485760, "max bytes")
	check_eq(config.submit_label, "Send report", "wording")
	check_eq(config.accent, Color("#2f6d4f"), "accent")
	check(TododdleSupportConfig.parse({"project": {}}) == null, "invalid config")
	check(TododdleSupportConfig.parse("nope") == null, "not a dictionary")


func test_unknown_field_types_and_extra_keys_are_kept() -> void:
	var data: Dictionary = suite["config"].duplicate(true)
	data["form"]["fields"].append({"key": "rating", "label": "Rating", "type": "STARS", "required": false})
	data["somethingNew"] = true
	var config := TododdleSupportConfig.parse(data)
	check_eq(config.get_field("rating").type, "STARS", "unknown type kept")
	check_eq(config.get_field("rating").effective_max_length(), 5000, "long limit for unknown types")
	check(config.data.has("somethingNew"), "raw data kept")


func test_context_is_filled_and_clipped() -> void:
	var client := TododdleSupport.create("tdsk_pub_X", "http://localhost")
	client.app_version = "9.9.9"
	client.build = "client-build"
	var report := TododdleSupportReport.new()
	report.screen = "Level 3?seed=42&name=alex"
	report.build = "b".repeat(80)
	for i in 25:
		report.extra["key%02d" % i] = "v".repeat(600) if i == 0 else i
	var context := client.build_context(report)
	check_eq(context["platform"], "godot", "platform")
	check_eq(context["appVersion"], "9.9.9", "client app version")
	check_eq(str(context["build"]).length(), 50, "build clipped to 50")
	check_eq(context["screen"], "Level 3", "query string removed")
	report.screen = "Level 3#token=abc"
	check_eq(client.build_context(report)["screen"], "Level 3", "fragment removed")
	report.screen = "Level 3#a?b"
	check_eq(client.build_context(report)["screen"], "Level 3", "fragment and query removed")
	check_eq(context["osName"], OS.get_name(), "osName")
	check(not str(context["locale"]).contains("_"), "locale uses a hyphen")
	check(str(context["locale"]).length() <= 35, "locale length")
	var extra: Dictionary = context["extra"]
	check_eq(extra.size(), 20, "extra capped at 20")
	check_eq(str(extra["key00"]).length(), 500, "extra value clipped to 500")
	check_eq(extra["key05"], "5", "extra values are text")

	client.collect_device_context = false
	context = client.build_context(TododdleSupportReport.new())
	check(not context.has("osName") and not context.has("locale"), "device context off")
	check_eq(context["platform"], "godot", "platform always sent")


func test_locale_tag() -> void:
	check_eq(TododdleSupport._locale_tag("en_GB.UTF-8"), "en-GB", "encoding removed")
	check_eq(TododdleSupport._locale_tag("sr_RS@latin"), "sr-RS", "modifier removed")
	check_eq(TododdleSupport._locale_tag("de"), "de", "language only")


func test_lengths_count_utf16_units_like_the_server() -> void:
	check_eq(Validation._len("abc"), 3, "ascii")
	check_eq(Validation._len("😀"), 2, "emoji is two units")
	check_eq(Validation.clip("ab😀", 3), "ab", "clip does not split a character")
	var report := TododdleSupportReport.new()
	report.description = "ok"
	report.title = "😀".repeat(81)
	var errors := Validation.validate(report, null)
	check(errors.has("title"), "162 units is over the 160 limit")


func test_validation_of_attachments_and_reporter() -> void:
	var config := shared_config()
	var report := shared_report()
	report.reporter_email = "not-an-email"
	report.add_attachment(TododdleSupportAttachment.new(PackedByteArray([1]), "a.exe", "application/x-msdownload"))
	var errors := Validation.validate(report, config)
	check(errors.has("attachments"), "type not allowed")
	check(errors.has("reporter"), "email")

	report = shared_report()
	for i in 6:
		report.add_attachment(TododdleSupportAttachment.from_text("x", "%d.txt" % i))
	check(Validation.validate(report, config).has("attachments"), "too many")

	config.attachments_enabled = false
	report = shared_report().add_attachment(TododdleSupportAttachment.from_text("x"))
	check_eq(Validation.validate(report, config).get("attachments"), "Attachments are not accepted.", "disabled")
	check(Validation.validate(shared_report(), shared_config()).is_empty(), "shared report is valid")


func test_text_attachment_keeps_the_end_when_trimmed() -> void:
	var attachment := TododdleSupportAttachment.from_text("first line\nlast line\n", "log.txt", 10)
	check_eq(attachment.bytes.get_string_from_utf8(), "last line\n", "newest bytes kept")
	check_eq(attachment.content_type, "text/plain", "type")
	# A cut inside a multi-byte character skips the broken start.
	check(TododdleSupportAttachment.from_text("aé", "x.txt", 1) == null, "only a broken character left gives null")
	var accent := TododdleSupportAttachment.from_text("xé!", "x.txt", 2)
	check_eq(accent.bytes.get_string_from_utf8(), "!", "continuation byte skipped")
	check(TododdleSupportAttachment.from_text("") == null, "empty text gives null")


func test_text_file_attachment() -> void:
	var path := "user://tododdle_support_tests/hitch_log.txt"
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("0123456789")
	file.close()
	var attachment := TododdleSupportAttachment.from_text_file(path)
	check_eq(attachment.file_name, "hitch_log.txt", "file name from the path")
	check_eq(attachment.get_size(), 10, "size")
	var trimmed := TododdleSupportAttachment.from_text_file(path, "log.txt", 4)
	check_eq(trimmed.bytes.get_string_from_utf8(), "6789", "end of the file")
	check_eq(trimmed.file_name, "log.txt", "custom name")
	check(TododdleSupportAttachment.from_text_file("user://missing.txt") == null, "missing file gives null")
	DirAccess.remove_absolute(path)


func test_image_attachment() -> void:
	var image := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			image.set_pixel(x, y, Color(randf(), randf(), randf()))
	var attachment := TododdleSupportAttachment.from_image(image)
	check_eq(attachment.content_type, "image/png", "png")
	check_eq(attachment.file_name, "screenshot.png", "default name")
	var png := Image.new()
	check_eq(png.load_png_from_buffer(attachment.bytes), OK, "valid PNG")
	check(attachment.is_image(), "is image")
	# Over the limit: scaled down until it fits.
	var small := TododdleSupportAttachment.from_image(image, "s.png", attachment.get_size() / 2)
	check(small != null and small.get_size() <= attachment.get_size() / 2, "scaled down to fit")
	check(TododdleSupportAttachment.from_image(null) == null, "null image")
	check(TododdleSupportAttachment.from_viewport(null) == null, "null viewport")
	# Headless has no rendered image; the helper must not crash.
	var tree := Engine.get_main_loop() as SceneTree
	var shot := TododdleSupportAttachment.from_viewport(tree.root)
	check(shot == null or shot.content_type == "image/png", "viewport helper is safe headless")


func test_every_script_and_scene_loads() -> void:
	for path: String in [
		"res://addons/tododdle_support/plugin.gd",
		"res://addons/tododdle_support/ui/report_dialog.gd",
		"res://example/main.gd",
	]:
		var script := load(path) as GDScript
		check(script != null and script.can_instantiate(), "%s compiles" % path)
	for path: String in ["res://addons/tododdle_support/ui/report_dialog.tscn", "res://example/main.tscn"]:
		var scene := load(path) as PackedScene
		check(scene != null and scene.can_instantiate(), "%s loads" % path)


func test_example_scene_runs_headless() -> void:
	var scene := load("res://example/main.tscn") as PackedScene
	var main := scene.instantiate() as Control
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(main)
	await tree.process_frame
	check(main.get_node("%ReportButton") is Button, "report button")
	check(FileAccess.file_exists("user://hitch_log.txt"), "sample log written")
	DirAccess.remove_absolute("user://hitch_log.txt")
	main.queue_free()


func test_project_keeps_text_resources_as_text_on_export() -> void:
	# Godot 4.7's binary conversion on export can drop data; keep it off.
	check_eq(ProjectSettings.get_setting("editor/export/convert_text_resources_to_binary", true), false, "convert_text_resources_to_binary")


func test_allowed_urls_are_https_or_loopback_http() -> void:
	for url: String in [
		"https://app.tododdle.com/api/support/sdk/v1",
		"https://uploads.example.com/x?sig=1",
		"http://127.0.0.1:8080/x",
		"http://[::1]:9000/x",
		"http://localhost/x",
		"http://LOCALHOST:3000",
	]:
		check(TododdleSupport.is_allowed_url(url), "allowed: %s" % url)
	for url: String in [
		"http://app.tododdle.com/api",
		"http://10.0.0.5/x",
		"http://localhost.example.com/x",
		"http://127.0.0.1.example.com/x",
		"ftp://example.com/x",
		"not a url",
		"",
	]:
		check(not TododdleSupport.is_allowed_url(url), "refused: %s" % url)


func test_upload_headers_drop_sensitive_names() -> void:
	var sent := TododdleSupport.upload_headers_to_send(
		{
			"Content-Type": "image/png",
			"x-amz-meta-test": "yes",
			"Host": "evil.example",
			"authorization": "Bearer x",
			"Cookie": "a=b",
			"Proxy-Authorization": "Basic x",
			"Proxy-Connection": "keep-alive",
			"Connection": "close",
			"Transfer-Encoding": "chunked",
			"Content-Length": "1",
		}
	)
	check_eq(sent, {"Content-Type": "image/png", "x-amz-meta-test": "yes"}, "kept headers")
	check_eq(TododdleSupport.upload_headers_to_send(null), {}, "no headers")
