class_name TododdleSupportRetryPolicy
extends RefCounted
## When and how long the client waits before it tries a call again.
##
## The defaults match [code]retryPolicy[/code] in the shared conformance cases, which every
## ToDoddle Support SDK follows: retry only network errors and [member retry_statuses], honour
## [code]Retry-After[/code] (seconds) up to [member max_retry_after_seconds], otherwise back off by
## [member backoff_seconds], with at most [member max_attempts] attempts for one call.

## Attempts for one call, including the first.
var max_attempts: int = 3
## The wait before retry number [code]n[/code] (0-based) when the response has no
## [code]Retry-After[/code]. The last value is reused if there are more retries.
var backoff_seconds: Array[float] = [1.0, 2.0, 4.0]
## HTTP statuses worth retrying. No other status is retried.
var retry_statuses: Array[int] = [408, 429, 500, 502, 503, 504]
## The longest [code]Retry-After[/code] the client waits inside one call. A longer value ends the
## call at once with [code]RATE_LIMITED[/code] and [member TododdleSupportResult.retry_after_seconds].
var max_retry_after_seconds: int = 60


## The wait before retry number [param retry] (0-based).
func backoff_for(retry: int) -> float:
	if backoff_seconds.is_empty():
		return 0.0
	return backoff_seconds[mini(retry, backoff_seconds.size() - 1)]


## Whether [param status] is worth retrying.
func is_retry_status(status: int) -> bool:
	return retry_statuses.has(status)


## Parses a [code]Retry-After[/code] header in seconds. Returns -1 when it is missing or not a
## number of seconds (the contract does not use HTTP dates).
static func parse_retry_after(value: String) -> int:
	var trimmed := value.strip_edges()
	if trimmed.is_empty() or not trimmed.is_valid_int():
		return -1
	var seconds := trimmed.to_int()
	return seconds if seconds >= 0 else -1
