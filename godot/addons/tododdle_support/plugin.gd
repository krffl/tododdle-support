@tool
extends EditorPlugin
## Adds the ToDoddle Support settings to Project Settings (General > Tododdle Support).
## Values you change are saved with the project and stay when the plugin is turned off.

const _Settings := preload("settings.gd")

const _PROPERTIES: Array[Dictionary] = [
	{
		"name": _Settings.SETTING_KEY,
		"default": "",
		"hint": PROPERTY_HINT_PLACEHOLDER_TEXT,
		"hint_string": "tdsk_pub_…",
	},
	{
		"name": _Settings.SETTING_BASE_URL,
		"default": _Settings.DEFAULT_BASE_URL,
		"hint": PROPERTY_HINT_PLACEHOLDER_TEXT,
		"hint_string": _Settings.DEFAULT_BASE_URL,
	},
	{
		"name": _Settings.SETTING_APP_ID,
		"default": "",
		"hint": PROPERTY_HINT_PLACEHOLDER_TEXT,
		"hint_string": "com.example.game (only if the key lists allowed app IDs)",
	},
	{
		"name": _Settings.SETTING_BUILD,
		"default": "",
		"hint": PROPERTY_HINT_PLACEHOLDER_TEXT,
		"hint_string": "Build number or commit (optional)",
	},
]


func _enter_tree() -> void:
	for property in _PROPERTIES:
		var name: String = property["name"]
		if not ProjectSettings.has_setting(name):
			ProjectSettings.set_setting(name, property["default"])
		ProjectSettings.set_initial_value(name, property["default"])
		ProjectSettings.set_as_basic(name, true)
		ProjectSettings.add_property_info(
			{
				"name": name,
				"type": TYPE_STRING,
				"hint": property["hint"],
				"hint_string": property["hint_string"],
			}
		)
