import 'retry.dart';

/// Error codes. The first group comes from the contract (`Error.code`). The
/// server may add new codes in v1, so treat an unknown code by its
/// [TododdleSupportException.httpStatus].
///
/// The second group is raised by the SDK itself and never comes from the
/// server.
abstract final class TododdleErrorCodes {
  // Contract codes.

  /// Malformed JSON, an unknown property or a value of the wrong type.
  static const invalidRequest = 'INVALID_REQUEST';

  /// The key is missing or unknown.
  static const invalidKey = 'INVALID_KEY';

  /// The key was revoked.
  static const keyRevoked = 'KEY_REVOKED';

  /// The browser origin is not allowed for this key.
  static const originNotAllowed = 'ORIGIN_NOT_ALLOWED';

  /// The app ID is not allowed for this key.
  static const appNotAllowed = 'APP_NOT_ALLOWED';

  /// The Support module is off or paused for this project.
  static const supportUnavailable = 'SUPPORT_UNAVAILABLE';

  /// One or more fields failed validation. See
  /// [TododdleSupportException.fields]. The SDK also uses this code for its
  /// own client-side validation, with a null `httpStatus`.
  static const invalidFields = 'INVALID_FIELDS';

  /// The form changed since the config was read. Fetch the config again.
  static const fieldsChanged = 'FIELDS_CHANGED';

  /// The body, a field or an attachment is over its limit.
  static const payloadTooLarge = 'PAYLOAD_TOO_LARGE';

  /// Too many attachments.
  static const tooManyAttachments = 'TOO_MANY_ATTACHMENTS';

  /// An attachment's content type is not allowed.
  static const attachmentTypeNotAllowed = 'ATTACHMENT_TYPE_NOT_ALLOWED';

  /// The idempotency key was used before with a different body.
  static const idempotencyKeyReused = 'IDEMPOTENCY_KEY_REUSED';

  /// Submit was called before all attachments were uploaded.
  static const attachmentsNotReady = 'ATTACHMENTS_NOT_READY';

  /// No such report for this key.
  static const reportNotFound = 'REPORT_NOT_FOUND';

  /// The report was not submitted in time and was discarded.
  static const reportExpired = 'REPORT_EXPIRED';

  /// Too many requests.
  static const rateLimited = 'RATE_LIMITED';

  // SDK codes.

  /// The request did not reach the server, or no response came back.
  static const networkError = 'NETWORK_ERROR';

  /// The server answered with an error status and no readable error body.
  static const httpError = 'HTTP_ERROR';

  /// The server answered with a body the SDK cannot read.
  static const invalidResponse = 'INVALID_RESPONSE';

  /// An attachment upload to its `uploadUrl` failed.
  static const uploadFailed = 'UPLOAD_FAILED';
}

/// A failed SDK call.
class TododdleSupportException implements Exception {
  /// Creates an exception.
  const TododdleSupportException({
    required this.code,
    required this.message,
    this.httpStatus,
    this.fields = const {},
    this.requestId,
    this.retryAfter,
  });

  /// An [TododdleErrorCodes.invalidResponse] error.
  factory TododdleSupportException.invalidResponse(String message) =>
      TododdleSupportException(
        code: TododdleErrorCodes.invalidResponse,
        message: 'Unexpected response: $message',
      );

  /// A stable machine code, usually one of [TododdleErrorCodes]. Unknown
  /// server codes are kept as sent.
  final String code;

  /// The HTTP status, or null when no response came back or the SDK raised
  /// the error itself (for example client-side validation).
  final int? httpStatus;

  /// Plain English and safe to log. Show your own wording to people.
  final String message;

  /// For [TododdleErrorCodes.invalidFields] and
  /// [TododdleErrorCodes.fieldsChanged]: a message per field key. Built-in
  /// keys are `type`, `title`, `description` and `attachments`.
  final Map<String, String> fields;

  /// The server's request ID, when it sent one.
  final String? requestId;

  /// For rate limits: how long the server asked the SDK to wait.
  final Duration? retryAfter;

  /// Whether retrying the same call later may succeed: a network error or a
  /// status in [RetryPolicy.retryStatuses].
  bool get isTransient =>
      code == TododdleErrorCodes.networkError ||
      (httpStatus != null &&
          RetryPolicy.standard.retryStatuses.contains(httpStatus));

  @override
  String toString() {
    final status = httpStatus == null ? '' : ' (HTTP $httpStatus)';
    return 'TododdleSupportException $code$status: $message';
  }
}
