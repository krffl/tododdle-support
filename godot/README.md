# ToDoddle Support for Godot

One-way in-game issue reporting into a ToDoddle Support project. Each report becomes a Support
ticket in the project's intake lane. The player gets no email, sign-in link or replies.

- A headless client: `TododdleSupport.get_config()` and `TododdleSupport.send_report()`.
- A plain report dialog built from your project's form config: `TododdleSupportDialog`.
- GDScript only, statically typed, no GDExtension. It exports to desktop, iOS, Android and web.

The HTTP contract is [`contract/openapi.yaml`](../contract/openapi.yaml).

Built and tested with Godot 4.7. Godot 4.3 or later should work, but only 4.7 is tested.

## Install

Copy `godot/addons/tododdle_support` from this repository into your game as
`res://addons/tododdle_support`. Keep that path: the dialog scene refers to it.

To take the files straight from a release tag:

```sh
git clone --depth 1 --branch v1.0.0 --filter=blob:none --sparse \
  https://github.com/krffl/tododdle-support.git tododdle-support
git -C tododdle-support sparse-checkout set godot/addons/tododdle_support
cp -R tododdle-support/godot/addons/tododdle_support <your-game>/addons/
```

Then open **Project > Project Settings > Plugins** and enable **ToDoddle Support**. The plugin only
adds the settings below to Project Settings; the addon works without it.

## Settings

Create a public SDK key in your ToDoddle Support project settings. A public key (`tdsk_pub_…`) can
only read the report form and send reports, so it is safe to ship inside a game. Test keys
(`tdsk_test_…`) work the same way and mark their tickets as test reports. The client refuses any
other key with `NOT_CONFIGURED`, and sends nothing.

The base URL must use HTTPS. Plain HTTP works only for a loopback host (`127.0.0.1`, `::1`,
`localhost`), for a local test server. Any other base URL fails with `NOT_CONFIGURED`.

Set these in **Project Settings > General > Tododdle Support**:

| Setting | Default | Use |
|---|---|---|
| `tododdle_support/key` | empty | Your public SDK key. Nothing is sent without one. |
| `tododdle_support/base_url` | `https://app.tododdle.com/api/support/sdk/v1` | Change only for ToDoddle staging: `https://app-stg.tododdle.com/api/support/sdk/v1`. |
| `tododdle_support/app_id` | empty | Sent as `X-Tododdle-App-Id` if the key lists allowed app IDs (bundle ID or package name). |
| `tododdle_support/build` | empty | Your build number or commit, sent with each report. |

The app version comes from `application/config/version`.

To override these in code (for example a staging key in debug builds), pass a
`TododdleSupportSettings` resource. Empty values in it fall back to Project Settings:

```gdscript
var settings := TododdleSupportSettings.new()
settings.key = "tdsk_test_…"
settings.base_url = TododdleSupport.STAGING_BASE_URL
var support := TododdleSupport.new(settings)
# or: TododdleSupport.create("tdsk_test_…", TododdleSupport.STAGING_BASE_URL)
```

You can also save a `TododdleSupportSettings` as a `.tres` and set it on the dialog's `settings`
property.

## The dialog

```gdscript
func _on_report_pressed() -> void:
    var dialog := TododdleSupportDialog.create()
    dialog.screen = "Level 3"
    dialog.extra = {"difficulty": "hard", "seed": str(level_seed)}
    # Take the screenshot before the dialog opens, so the dialog is not in it.
    dialog.add_attachment(TododdleSupportAttachment.from_viewport(get_viewport()))
    dialog.add_attachment(TododdleSupportAttachment.from_text_file("user://hitch_log.txt"))
    dialog.report_sent.connect(func(result: TododdleSupportResult) -> void: print(result.report_id))
    add_child(dialog)  # opens on ready
```

The dialog loads `GET /config` and shows the project's report types, title, description and custom
fields (short text, long text and select), with the project's wording. Each attachment has a tick
box, its file size and a small preview, so the player can leave it out. Images start ticked. Text
attachments such as logs start unticked, so the player chooses to send them. The dialog checks required fields before
sending, shows field errors from the server next to each field, and ends with the project's
thank-you message. If the form changed on the server (`FIELDS_CHANGED`), it reloads the form and
keeps what the player typed.

It is a `CanvasLayer` (layer 100), so it shows above the game wherever you add it. Useful
properties:

- `client`: a `TododdleSupport` to use. Without one the dialog makes its own from `settings`.
- `screen`, `extra`, `build`, `reporter_name`, `reporter_email`, `customer_reference`,
  `default_type`.
- `pause_game`: pause the SceneTree while the dialog is open (off by default).
- `close_on_cancel`, `open_on_ready`, `free_on_close`.
- Signals: `report_sent(result)`, `report_failed(result)`, `closed`.
- The texts that do not come from the config (`loading_text`, `sending_text`,
  `network_error_text` and so on) are exported properties, so you can translate them.

### Styling and replacing it

The dialog uses plain Control nodes (`PanelContainer`, `Label`, `LineEdit`, `TextEdit`,
`OptionButton`, `CheckBox`, `Button`). Set its `theme` property to your game's Theme and it uses
that. Without a Theme it gives the panel a solid background and the send button the project's
accent colour and corner style from the config; set `use_project_style = false` to turn that off.

For a different layout, duplicate `ui/report_dialog.tscn` into your game and change it. The script
finds its nodes by unique name (`%Heading`, `%TypePicker`, `%TitleEdit`, `%DescriptionEdit`,
`%CustomFields`, `%AttachmentList`, `%SubmitButton` and so on), so keep those names.

For a fully custom UI, use the client directly (below). `config.types`, `config.fields`,
`config.attachments_*` and the wording members have everything the form needs.

## The client

Every call is awaitable, returns a result object and never raises an error. Keep the client in a
variable while a call runs.

```gdscript
var support := TododdleSupport.new()  # key and base URL from Project Settings

var loaded := await support.get_config()
if not loaded.ok:
    push_warning("Report form unavailable: %s" % loaded.message)
    return

var report := TododdleSupportReport.new()
report.type = "problem"
report.title = "Boss froze"
report.description = "The boss stopped moving after the cutscene."
report.fields = {"area": "Combat"}  # custom field values by key
report.screen = "Level 3"
report.extra = {"seed": "1234"}
report.add_attachment(TododdleSupportAttachment.from_viewport(get_viewport()))

var result := await support.send_report(report, loaded.config)
if result.ok:
    print("Sent ", result.report_id)
elif not result.fields.is_empty():
    show_field_errors(result.fields)  # field key -> message
elif result.error_code == TododdleSupportResult.RATE_LIMITED:
    print("Try again in %d s" % result.retry_after_seconds)
```

`TododdleSupport`:

- `get_config() -> TododdleSupportConfigResult`. Sends `If-None-Match` with the last ETag and keeps
  the last good config in `user://tododdle_support/`, so the form still opens offline. The result
  has `config` and `from_cache`.
- `send_report(report, config = null) -> TododdleSupportResult`. Checks the report against the
  config, creates it with the report's idempotency key, uploads each attachment to its `uploadUrl`
  with the returned headers, then submits it. An `uploadUrl` that is not HTTPS (plain HTTP only for
  a loopback host) fails with `INVALID_RESPONSE` before any file is sent. The client never sends
  `Host`, `Authorization`, `Cookie`, `Proxy-*`, `Connection`, `Transfer-Encoding` or
  `Content-Length` from the returned headers. It does not follow redirects: a 3xx answer fails
  with `HTTP_ERROR`. Without `config` it loads the config first.
- `validate_report(report, config = null) -> Dictionary`: the same checks, without sending.
- `build_context(report) -> Dictionary`: the context that will be sent.
- `clear_config_cache()`, `get_cached_config()`.
- Signals: `config_loaded(result)` and `report_finished(result)`.
- Members you can set: `key`, `base_url`, `app_id`, `app_version`, `build`, `timeout_seconds`
  (30), `collect_device_context` (true), `config_cache_path` (empty turns the cache off).

`TododdleSupportResult` (and `TododdleSupportConfigResult`, which adds `config` and `from_cache`):
`ok`, `status` (`received` or `failed`; `loaded` or `cached` for config), `report_id`,
`error_code`, `message`, `fields`, `retry_after_seconds` (-1 when not sent), `http_status`,
`request_id`, `is_transient()`. Error codes are constants on `TododdleSupportResult`: the contract
codes (`INVALID_FIELDS`, `FIELDS_CHANGED`, `RATE_LIMITED`, `KEY_REVOKED`, …) plus `NETWORK_ERROR`,
`HTTP_ERROR`, `INVALID_RESPONSE`, `UPLOAD_FAILED` and `NOT_CONFIGURED`. The server may add new codes,
so treat an unknown code by its `http_status`. `message` is plain English for logs; show players
your own wording.

Field errors use the keys `type`, `title`, `description`, `attachments`, `reporter` and the
project's custom field keys.

### Retries

Like every ToDoddle Support SDK, the client retries only network errors and HTTP 408, 429, 500,
502, 503 and 504, at most 3 attempts per call, waiting 1 s and then 2 s, or the `Retry-After` the
server sends. A `Retry-After` over 60 seconds ends the call at once with `RATE_LIMITED` and
`retry_after_seconds`, so the game can try later. Every attempt reuses the report's idempotency
key, so a retry never makes a second ticket. To retry a failed report yourself, send the same
`TododdleSupportReport` object again.

## Context

The client fills in:

- `platform`: `godot`
- `appVersion`: `application/config/version` (or the report's or client's `app_version`)
- `build`: the report's or client's `build`, or `tododdle_support/build`
- `osName` and `osVersion`: `OS.get_name()` and `OS.get_version()`
- `deviceModel`: `OS.get_model_name()` (left out on desktop, where it is a generic value)
- `locale`: `OS.get_locale()`, for example `en-GB`
- `screen`: what you set, without any query string (`?…`) or fragment (`#…`)
- `extra`: what you set. Up to 20 entries; values are converted to text and cut to 500 characters.

Values are cut to the contract's length limits. Set `collect_device_context = false` to send only
the platform, versions, screen and extra.

## Attachments

Nothing is attached unless the game hands it over. Each attachment is bytes, a file name and a
content type (`image/png`, `image/jpeg`, `image/webp`, `image/gif`, `application/pdf` or
`text/plain`), at most 10 MB and at most 5 per report, within the project's own limits.

- `TododdleSupportAttachment.from_viewport(get_viewport())`: a PNG screenshot. Call it before you
  show the dialog. It scales the image down if the PNG is over 10 MB, and returns null when there is
  no image (for example in a headless run).
- `TododdleSupportAttachment.from_image(image, "screenshot.png")`: a PNG of any `Image`.
- `TododdleSupportAttachment.from_text_file("user://hitch_log.txt")`: a `text/plain` file. If it
  is over 10 MB, only the end (the newest lines) is kept. Returns null when the file is missing.
- `TododdleSupportAttachment.from_text(text, "log.txt")`: the same for a string.
- `TododdleSupportAttachment.new(bytes, file_name, content_type)`: anything else.

`add_attachment()` on the report and the dialog ignores null, so you can pass the helpers straight
in.

**Scrub logs before you attach them.** A log goes to your ToDoddle project as it is. Remove player
names, email addresses, account IDs, tokens, IP addresses and file paths with user names before you
pass it to `from_text_file()` or `from_text()`.

## Privacy

- Nothing is collected unless the game passes it: no screenshots, logs, player names or IDs.
- The device context is the OS, OS version, device model and locale. Turn it off with
  `collect_device_context = false`.
- Reporter details (`reporter_name`, `reporter_email`, `customer_reference`) are optional and
  unverified. ToDoddle never emails the reporter.
- The dialog lets the player untick every attachment before sending. Text attachments start
  unticked.
- The only file written is the cached report form in `user://tododdle_support/`.

## Web exports

Browsers send no app ID. The key's allowed origins must include the page that hosts your game,
or the server refuses the request (`ORIGIN_NOT_ALLOWED`).

## Example and tests

`godot/` is a small Godot project for working on the addon. Open it in Godot and run it to see
`example/main.tscn`: a button that opens the dialog with a screenshot and a sample log. Its key in
`project.godot` is a placeholder; put your own test key there to send real reports.

Run the tests (Godot 4.7 and Node.js 20 or later):

```sh
GODOT=/path/to/godot godot/run-tests.sh
```

They run headless against a local mock server (`tests/mock_server.mjs`) and cover the 11 shared
conformance cases in `contract/cases/cases.json`, the client, the models and the dialog.
