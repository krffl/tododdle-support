class_name TododdleSupportSettings
extends Resource
## Connection settings for [TododdleSupport]. Every empty value falls back to Project Settings
## ([code]tododdle_support/*[/code]) and then to the default.
##
## Save one as a [code].tres[/code] to keep, for example, a staging key apart from production, and
## pass it to [code]TododdleSupport.new(settings)[/code].

const SETTING_KEY := "tododdle_support/key"
const SETTING_BASE_URL := "tododdle_support/base_url"
const SETTING_APP_ID := "tododdle_support/app_id"
const SETTING_BUILD := "tododdle_support/build"

const DEFAULT_BASE_URL := "https://app.tododdle.com/api/support/sdk/v1"
const STAGING_BASE_URL := "https://app-stg.tododdle.com/api/support/sdk/v1"

## The project's public SDK key ([code]tdsk_pub_…[/code] or [code]tdsk_test_…[/code]). It can only
## read the form and send reports, so it is safe to ship in the game.
@export var key: String = ""
## The API base URL, without a trailing slash.
@export var base_url: String = ""
## Sent as [code]X-Tododdle-App-Id[/code] when the key lists allowed app IDs (the iOS bundle ID or
## Android package name).
@export var app_id: String = ""
## The game version. Empty uses [code]application/config/version[/code].
@export var app_version: String = ""
## The build number or commit, if the game has one.
@export var build: String = ""
## Seconds before one HTTP attempt gives up.
@export var timeout_seconds: float = 30.0
## Keep the last good config in [code]user://[/code] so the dialog opens offline.
@export var cache_config: bool = true
## Fill in the OS name and version, device model and locale.
@export var collect_device_context: bool = true


## A copy where every empty value is filled from Project Settings and the defaults.
func resolved() -> TododdleSupportSettings:
	var out := duplicate() as TododdleSupportSettings
	if out.key.is_empty():
		out.key = str(ProjectSettings.get_setting(SETTING_KEY, ""))
	if out.base_url.is_empty():
		out.base_url = str(ProjectSettings.get_setting(SETTING_BASE_URL, ""))
	if out.base_url.is_empty():
		out.base_url = DEFAULT_BASE_URL
	if out.app_id.is_empty():
		out.app_id = str(ProjectSettings.get_setting(SETTING_APP_ID, ""))
	if out.app_version.is_empty():
		out.app_version = str(ProjectSettings.get_setting("application/config/version", ""))
	if out.build.is_empty():
		out.build = str(ProjectSettings.get_setting(SETTING_BUILD, ""))
	out.key = out.key.strip_edges()
	out.base_url = out.base_url.strip_edges().trim_suffix("/")
	out.app_id = out.app_id.strip_edges()
	return out
