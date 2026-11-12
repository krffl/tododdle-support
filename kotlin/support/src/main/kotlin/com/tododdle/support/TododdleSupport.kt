package com.tododdle.support

import android.content.Context
import com.tododdle.support.internal.AndroidEnvironment
import com.tododdle.support.internal.ConfigCache
import com.tododdle.support.internal.DeclaredAttachment
import com.tododdle.support.internal.Environment
import com.tododdle.support.internal.Http
import com.tododdle.support.internal.HttpResult
import com.tododdle.support.internal.ReportRequestBody
import com.tododdle.support.internal.ReportResponseBody
import com.tododdle.support.internal.SubmitBody
import com.tododdle.support.internal.SupportJson
import com.tododdle.support.internal.UploadTarget
import com.tododdle.support.internal.isForbiddenUploadHeader
import com.tododdle.support.internal.isSecureOrLoopback
import com.tododdle.support.internal.stripQueryAndFragment
import com.tododdle.support.internal.toException
import kotlinx.coroutines.delay
import kotlinx.serialization.SerializationException
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

/**
 * The headless ToDoddle Support client.
 *
 * ```
 * val support = TododdleSupport(context, Configuration(key = "tdsk_pub_…"))
 * val config = support.config()
 * val receipt = support.report(Report(type = ReportType.PROBLEM, description = "…", formVersion = config.form.version))
 * ```
 *
 * Reports go one way: the person reporting gets no email or replies. Create one instance and reuse
 * it; it is safe to call from any coroutine.
 */
public class TododdleSupport internal constructor(
    public val configuration: Configuration,
    private val environment: Environment,
    private val sleep: suspend (Long) -> Unit,
) {
    public constructor(context: Context, configuration: Configuration) :
        this(configuration, AndroidEnvironment(context), { delay(it) })

    private val baseUrl: HttpUrl = configuration.baseUrl.trimEnd('/').toHttpUrl()
    private val appId: String? = configuration.appId ?: environment.appId
    private val http = Http(
        client = configuration.httpClient?.withoutRedirects() ?: defaultClient,
        sleep = sleep,
        maxRetryAfterSeconds = configuration.maxRetryAfterSeconds,
    )
    private val cache = ConfigCache(
        dir = if (configuration.cacheConfigOnDisk) environment.cacheDir else null,
        cacheId = "${configuration.baseUrl}|${configuration.key}",
    )

    /**
     * Reads the report form, wording and theme. Sends the last `ETag` so an unchanged config costs
     * almost nothing. When the network or server fails, it returns the last good config if there
     * is one, so the form still opens offline.
     *
     * @throws TododdleSupportException for an invalid or revoked key, Support being unavailable,
     *   or a failure with no cached config.
     */
    public suspend fun config(): SupportConfig {
        val cached = cache.get()
        val result = try {
            http.send {
                request(baseUrl.newBuilder().addPathSegment("config").build())
                    .apply { cached?.etag?.let { header("If-None-Match", it) } }
                    .get()
                    .build()
            }
        } catch (e: TododdleSupportException) {
            return cached?.config ?: throw e
        }
        return when {
            result.status == 304 && cached != null -> cached.config
            result.status == 200 -> {
                val config = decode(result) { SupportJson.decodeFromString(SupportConfig.serializer(), it) }
                cache.put(ConfigCache.Entry(result.headers["ETag"], config, result.body))
                config
            }
            result.status in RETRYABLE_FOR_CACHE && cached != null -> cached.config
            result.isSuccessful || result.status == 304 ->
                throw invalidResponse(result.status, "Unexpected config response.")
            else -> throw result.toException(SupportJson)
        }
    }

    /** The last good config from memory or the file cache, without a network call. */
    public fun cachedConfig(): SupportConfig? = cache.get()?.config

    /** Forgets the cached config. */
    public fun clearConfigCache() {
        cache.clear()
    }

    /**
     * Sends a report. With attachments it declares them, uploads the raw bytes to each returned
     * URL with exactly the returned headers, then submits. Every retry of this call reuses
     * [Report.idempotencyKey]. To retry later yourself, call again with the same [Report].
     *
     * The report is checked against the fixed contract limits and, when a config is known, the
     * project's form. Problems throw [ErrorCode.INVALID_FIELDS] before anything is sent.
     *
     * @throws TododdleSupportException when the report is refused or cannot be sent.
     */
    public suspend fun report(report: Report): ReportReceipt {
        val formVersion: Int
        val formConfig: SupportConfig?
        if (report.formVersion != null) {
            formVersion = report.formVersion
            formConfig = cachedConfig()?.takeIf { it.form.version == formVersion }
        } else {
            formConfig = config()
            formVersion = formConfig.form.version
        }
        ReportValidator.requireValid(report, formConfig)

        val body = ReportRequestBody(
            idempotencyKey = report.idempotencyKey,
            type = report.type,
            formVersion = formVersion,
            title = report.title?.takeIf { it.isNotBlank() },
            description = report.description?.takeIf { it.isNotBlank() },
            fields = report.fields.filterValues { it.isNotBlank() }.takeIf { it.isNotEmpty() },
            context = reportContext(report.context),
            reporter = report.reporter,
            attachments = report.attachments
                .map { DeclaredAttachment(it.fileName, it.contentType, it.size) }
                .takeIf { it.isNotEmpty() },
        )
        val json = SupportJson.encodeToString(ReportRequestBody.serializer(), body)
        val created = http.send {
            request(baseUrl.newBuilder().addPathSegment("reports").build())
                .post(json.toRequestBody(JSON))
                .build()
        }
        if (created.status != 200 && created.status != 201) throw created.toException(SupportJson)
        val response = decode(created) { SupportJson.decodeFromString(ReportResponseBody.serializer(), it) }

        if (response.status != ReportReceipt.STATUS_AWAITING_UPLOADS) {
            return ReportReceipt(response.reportId, response.status)
        }
        val submitToken = response.submitToken
            ?: throw invalidResponse(created.status, "The report is waiting for uploads but has no submit token.")
        if (response.uploads.size != report.attachments.size) {
            throw invalidResponse(created.status, "The server returned ${response.uploads.size} upload URLs for ${report.attachments.size} attachments.")
        }
        response.uploads.zip(report.attachments).forEach { (target, attachment) -> upload(target, attachment) }
        return submit(response.reportId, submitToken)
    }

    private suspend fun upload(target: UploadTarget, attachment: Attachment) {
        val url = try {
            target.uploadUrl.toHttpUrl()
        } catch (e: IllegalArgumentException) {
            throw invalidResponse(null, "The upload URL is not valid.")
        }
        if (!url.isSecureOrLoopback()) throw invalidResponse(null, "The upload URL is not HTTPS.")
        // Send the returned headers, except ones that could leak credentials or break framing.
        // Never send the SDK key to the storage host.
        val headers = target.headers.filterKeys { !isForbiddenUploadHeader(it) }
        val contentType = headers.entries.firstOrNull { it.key.equals("Content-Type", ignoreCase = true) }?.value
        val result = http.send {
            val builder = Request.Builder().url(url)
            headers.forEach { (name, value) ->
                if (!name.equals("Content-Type", ignoreCase = true)) builder.header(name, value)
            }
            builder.put(attachment.bytes.toRequestBody(contentType?.toMediaTypeOrNull())).build()
        }
        if (!result.isSuccessful) {
            throw TododdleSupportException(
                code = ErrorCode.UPLOAD_FAILED,
                httpStatus = result.status,
                message = "Uploading ${attachment.fileName} failed with HTTP ${result.status}.",
            )
        }
    }

    private suspend fun submit(reportId: String, submitToken: String): ReportReceipt {
        val json = SupportJson.encodeToString(SubmitBody.serializer(), SubmitBody(submitToken))
        val result = http.send {
            request(
                baseUrl.newBuilder().addPathSegment("reports").addPathSegment(reportId).addPathSegment("submit").build(),
            ).post(json.toRequestBody(JSON)).build()
        }
        if (!result.isSuccessful) throw result.toException(SupportJson)
        val response = decode(result) { SupportJson.decodeFromString(ReportResponseBody.serializer(), it) }
        return ReportReceipt(response.reportId, response.status)
    }

    private fun reportContext(appContext: ReportContext?): ReportContext? {
        val merged = if (!configuration.collectContext) {
            appContext
        } else {
            val automatic = runCatching { environment.automaticContext() }.getOrNull()
            appContext?.mergedOver(automatic) ?: automatic
        }
        // Query strings and fragments can carry tokens or personal data.
        return merged?.screen?.let { merged.copy(screen = stripQueryAndFragment(it)) } ?: merged
    }

    private fun request(url: HttpUrl): Request.Builder = Request.Builder()
        .url(url)
        .header("X-Tododdle-Key", configuration.key)
        .header("X-Tododdle-Sdk", SDK_HEADER)
        .header("Accept", "application/json")
        .apply { appId?.let { header("X-Tododdle-App-Id", it.take(200)) } }

    private inline fun <T> decode(result: HttpResult, parse: (String) -> T): T = try {
        parse(result.body)
    } catch (e: SerializationException) {
        throw invalidResponse(result.status, "Could not read the server response.", e)
    } catch (e: IllegalArgumentException) {
        throw invalidResponse(result.status, "Could not read the server response.", e)
    }

    private fun invalidResponse(status: Int?, message: String, cause: Throwable? = null) =
        TododdleSupportException(ErrorCode.INVALID_RESPONSE, status, message, cause = cause)

    public companion object {
        /** The SDK version, from the repository's VERSION file. */
        public const val VERSION: String = BuildConfig.SDK_VERSION

        /** The value sent as `X-Tododdle-Sdk`. */
        public const val SDK_HEADER: String = "kotlin/$VERSION"

        private val JSON = "application/json; charset=utf-8".toMediaType()
        private val RETRYABLE_FOR_CACHE = setOf(408, 429, 500, 502, 503, 504)

        private val defaultClient: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .connectTimeout(15, TimeUnit.SECONDS)
                .readTimeout(30, TimeUnit.SECONDS)
                .writeTimeout(60, TimeUnit.SECONDS)
                .followRedirects(false)
                .followSslRedirects(false)
                .build()
        }

        /** A copy that shares the app client's pool but never follows a redirect. */
        private fun OkHttpClient.withoutRedirects(): OkHttpClient =
            newBuilder().followRedirects(false).followSslRedirects(false).build()
    }
}
