class_name TododdleSupportConfigResult
extends TododdleSupportResult
## The result of [method TododdleSupport.get_config]. When [member ok] is true, [member config]
## holds the report form. The error members are inherited from [TododdleSupportResult].

## [member status] when the config came from the server (200, or 304 with the cached copy).
const STATUS_LOADED := "loaded"
## [member status] when the server could not be reached and the last good config was used.
const STATUS_CACHED := "cached"

## The report form, wording and branding. Null when [member ok] is false.
var config: TododdleSupportConfig = null
## True when the server could not be reached and [member config] is the last good copy.
var from_cache: bool = false


## A successful config result.
static func loaded(value: TododdleSupportConfig, cached: bool) -> TododdleSupportConfigResult:
	var result := TododdleSupportConfigResult.new()
	result.ok = true
	result.status = STATUS_CACHED if cached else STATUS_LOADED
	result.config = value
	result.from_cache = cached
	return result


## A failed config result with the error from [param error].
static func failed(error: TododdleSupportResult) -> TododdleSupportConfigResult:
	var result := TododdleSupportConfigResult.new()
	result.copy_error_from(error)
	return result


func _to_string() -> String:
	if ok:
		return "TododdleSupportConfigResult(%s form v%d)" % [status, config.form_version]
	return super()
