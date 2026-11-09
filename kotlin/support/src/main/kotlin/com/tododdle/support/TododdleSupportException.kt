package com.tododdle.support

/**
 * A failed SDK call.
 *
 * [code] is the server's stable error code (see [ErrorCode]) or one of the SDK's own codes. New
 * server codes may appear; judge an unknown code by [httpStatus]. [message] is plain English and
 * safe to log; apps should show their own wording. [fields] maps a field key to a message for
 * [ErrorCode.INVALID_FIELDS] and [ErrorCode.FIELDS_CHANGED].
 */
public class TododdleSupportException(
    public val code: String,
    public val httpStatus: Int?,
    message: String,
    public val fields: Map<String, String> = emptyMap(),
    public val requestId: String? = null,
    /** Seconds the server asked the app to wait, when it sent `Retry-After`. */
    public val retryAfterSeconds: Long? = null,
    cause: Throwable? = null,
) : Exception(message, cause) {

    /**
     * True when sending the same report again later may succeed: network errors, timeouts,
     * rate limits and the server errors in the shared retry policy (500, 502, 503, 504). Retry with the same [Report] so the idempotency key is reused.
     */
    public val isRetryable: Boolean
        get() = when {
            code == ErrorCode.NETWORK_ERROR -> true
            httpStatus == null -> false
            else -> httpStatus in com.tododdle.support.internal.RetryPolicy.RETRY_STATUSES
        }

    override fun toString(): String =
        "TododdleSupportException(code=$code, httpStatus=$httpStatus, message=$message" +
            (if (fields.isNotEmpty()) ", fields=$fields" else "") +
            (if (requestId != null) ", requestId=$requestId" else "") + ")"
}

/** Error codes. Server codes come from the contract; new ones may be added. */
public object ErrorCode {
    // Server codes.
    public const val INVALID_REQUEST: String = "INVALID_REQUEST"
    public const val INVALID_KEY: String = "INVALID_KEY"
    public const val KEY_REVOKED: String = "KEY_REVOKED"
    public const val ORIGIN_NOT_ALLOWED: String = "ORIGIN_NOT_ALLOWED"
    public const val APP_NOT_ALLOWED: String = "APP_NOT_ALLOWED"
    public const val SUPPORT_UNAVAILABLE: String = "SUPPORT_UNAVAILABLE"
    public const val INVALID_FIELDS: String = "INVALID_FIELDS"
    public const val FIELDS_CHANGED: String = "FIELDS_CHANGED"
    public const val PAYLOAD_TOO_LARGE: String = "PAYLOAD_TOO_LARGE"
    public const val TOO_MANY_ATTACHMENTS: String = "TOO_MANY_ATTACHMENTS"
    public const val ATTACHMENT_TYPE_NOT_ALLOWED: String = "ATTACHMENT_TYPE_NOT_ALLOWED"
    public const val IDEMPOTENCY_KEY_REUSED: String = "IDEMPOTENCY_KEY_REUSED"
    public const val ATTACHMENTS_NOT_READY: String = "ATTACHMENTS_NOT_READY"
    public const val REPORT_NOT_FOUND: String = "REPORT_NOT_FOUND"
    public const val REPORT_EXPIRED: String = "REPORT_EXPIRED"
    public const val RATE_LIMITED: String = "RATE_LIMITED"

    // SDK codes.
    /** No connection, DNS failure or timeout, after all retries. */
    public const val NETWORK_ERROR: String = "NETWORK_ERROR"
    /** A 5xx or other status with no error body, after all retries. */
    public const val SERVER_ERROR: String = "SERVER_ERROR"
    /** The server answered with a body the SDK could not read. */
    public const val INVALID_RESPONSE: String = "INVALID_RESPONSE"
    /** An attachment upload was refused by the storage host. */
    public const val UPLOAD_FAILED: String = "UPLOAD_FAILED"

    /** The code to use when a response has no readable error code. */
    internal fun forStatus(status: Int): String = when (status) {
        400 -> INVALID_REQUEST
        401 -> INVALID_KEY
        403 -> SUPPORT_UNAVAILABLE
        404 -> REPORT_NOT_FOUND
        409 -> IDEMPOTENCY_KEY_REUSED
        410 -> REPORT_EXPIRED
        413 -> PAYLOAD_TOO_LARGE
        422 -> INVALID_FIELDS
        429 -> RATE_LIMITED
        else -> SERVER_ERROR
    }
}
