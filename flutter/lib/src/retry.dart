/// When and how long the SDK waits before it tries a call again.
///
/// [RetryPolicy.standard] matches `retryPolicy` in the shared conformance
/// cases, which every ToDoddle Support SDK follows: retry only network errors
/// and the [retryStatuses], honour `Retry-After` (seconds), otherwise back off
/// by [backoff], with at most [maxAttempts] attempts for one call.
class RetryPolicy {
  /// Creates a policy.
  const RetryPolicy({
    required this.maxAttempts,
    required this.backoff,
    required this.retryStatuses,
    this.maxRetryAfter = const Duration(seconds: 60),
  });

  /// The shared policy: 3 attempts, back off 1 s, 2 s, 4 s, retry 408, 429,
  /// 500, 502, 503 and 504.
  static const standard = RetryPolicy(
    maxAttempts: 3,
    backoff: [Duration(seconds: 1), Duration(seconds: 2), Duration(seconds: 4)],
    retryStatuses: {408, 429, 500, 502, 503, 504},
  );

  /// The number of attempts for one call, including the first.
  final int maxAttempts;

  /// The wait before retry number `n` (0-based) when the response has no
  /// `Retry-After`. The last value is reused if there are more retries.
  final List<Duration> backoff;

  /// HTTP statuses worth retrying.
  final Set<int> retryStatuses;

  /// The longest `Retry-After` the SDK waits in the foreground. A longer
  /// value ends the call with the error, so the app (or the offline queue)
  /// can try later instead of blocking the person.
  final Duration maxRetryAfter;

  /// The wait before retry number [retry] (0-based).
  Duration backoffFor(int retry) {
    if (backoff.isEmpty) return Duration.zero;
    return backoff[retry < backoff.length ? retry : backoff.length - 1];
  }
}

/// Waits for [duration]. Inject a fake in tests to keep them fast.
typedef DelayFunction = Future<void> Function(Duration duration);

/// The default [DelayFunction].
Future<void> realDelay(Duration duration) => Future<void>.delayed(duration);

/// Parses a `Retry-After` header in seconds. HTTP dates are not used by the
/// contract and return null.
Duration? parseRetryAfter(String? value) {
  if (value == null) return null;
  final seconds = int.tryParse(value.trim());
  if (seconds == null || seconds < 0) return null;
  return Duration(seconds: seconds);
}
