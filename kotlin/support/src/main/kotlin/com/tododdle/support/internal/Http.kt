package com.tododdle.support.internal

import com.tododdle.support.ErrorCode
import com.tododdle.support.TododdleSupportException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Headers
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** A fully read HTTP response. */
internal class HttpResult(val status: Int, val headers: Headers, val body: String) {
    val isSuccessful: Boolean get() = status in 200..299
}

/**
 * The shared retry policy (`retryPolicy` in contract/cases/cases.json): retry 408, 429, 500, 502,
 * 503, 504 and network errors; honour `Retry-After` seconds, otherwise wait 1 s, 2 s, 4 s; at most
 * 3 attempts for one call. Every other status is returned at once.
 */
internal object RetryPolicy {
    const val MAX_ATTEMPTS = 3
    val BACKOFF_SECONDS = longArrayOf(1, 2, 4)
    val RETRY_STATUSES = setOf(408, 429, 500, 502, 503, 504)
}

internal class Http(
    private val client: OkHttpClient,
    private val sleep: suspend (Long) -> Unit,
    private val maxRetryAfterSeconds: Long,
) {
    /**
     * Sends the request from [build] with the retry policy. [build] is called again for each
     * attempt and must produce the same request (same idempotency key and body).
     */
    suspend fun send(build: () -> Request): HttpResult {
        var attempt = 1
        while (true) {
            val result = try {
                client.newCall(build()).await()
            } catch (e: CancellationException) {
                throw e
            } catch (e: IOException) {
                if (attempt >= RetryPolicy.MAX_ATTEMPTS) {
                    throw TododdleSupportException(
                        code = ErrorCode.NETWORK_ERROR,
                        httpStatus = null,
                        message = "Could not reach ToDoddle: ${e.message ?: e.javaClass.simpleName}",
                        cause = e,
                    )
                }
                sleep(backoffMillis(attempt))
                attempt++
                continue
            }
            if (result.status !in RetryPolicy.RETRY_STATUSES || attempt >= RetryPolicy.MAX_ATTEMPTS) {
                return result
            }
            val retryAfter = retryAfterSeconds(result.headers)
            if (retryAfter != null && retryAfter > maxRetryAfterSeconds) {
                // Too long to wait inside one call; the caller reports it with retryAfterSeconds.
                return result
            }
            sleep(if (retryAfter != null) retryAfter * 1000 else backoffMillis(attempt))
            attempt++
        }
    }

    private fun backoffMillis(attempt: Int): Long =
        RetryPolicy.BACKOFF_SECONDS[(attempt - 1).coerceIn(0, RetryPolicy.BACKOFF_SECONDS.size - 1)] * 1000
}

/** `Retry-After` in whole seconds. The contract uses seconds; other forms are ignored. */
internal fun retryAfterSeconds(headers: Headers): Long? =
    headers["Retry-After"]?.trim()?.toLongOrNull()?.takeIf { it >= 0 }

@Serializable
private class ErrorEnvelope(val error: ErrorBody? = null)

@Serializable
private class ErrorBody(
    val code: String? = null,
    val message: String? = null,
    val fields: Map<String, String>? = null,
    val requestId: String? = null,
)

/** Builds the typed exception for a failed response. Unknown codes keep their value. */
internal fun HttpResult.toException(json: Json, fallbackCode: String? = null): TododdleSupportException {
    val error = runCatching { json.decodeFromString(ErrorEnvelope.serializer(), body).error }.getOrNull()
    return TododdleSupportException(
        code = error?.code?.takeIf { it.isNotBlank() } ?: fallbackCode ?: ErrorCode.forStatus(status),
        httpStatus = status,
        message = error?.message ?: "ToDoddle answered with HTTP $status.",
        fields = error?.fields.orEmpty(),
        requestId = error?.requestId,
        retryAfterSeconds = retryAfterSeconds(headers),
    )
}

private suspend fun Call.await(): HttpResult = suspendCancellableCoroutine { continuation ->
    continuation.invokeOnCancellation { cancel() }
    enqueue(object : Callback {
        override fun onFailure(call: Call, e: IOException) {
            if (!continuation.isCancelled) continuation.resumeWithException(e)
        }

        override fun onResponse(call: Call, response: Response) {
            val result = try {
                response.use { HttpResult(it.code, it.headers, it.body?.string().orEmpty()) }
            } catch (e: IOException) {
                continuation.resumeWithException(e)
                return
            }
            continuation.resume(result)
        }
    })
}
