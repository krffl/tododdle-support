package com.tododdle.support

import kotlinx.serialization.Serializable
import java.util.UUID

/**
 * A one-way report. Create one instance per report and reuse it when you retry, so the same
 * [idempotencyKey] is sent and the server never creates a second ticket.
 */
public class Report(
    public val type: ReportType,
    public val description: String? = null,
    public val title: String? = null,
    /** Values by field key: text for text fields and one of the options for SELECT. */
    public val fields: Map<String, String> = emptyMap(),
    /**
     * Context the app adds. Values set here win over the automatic context (app version, build,
     * Android version, device model and locale).
     */
    public val context: ReportContext? = null,
    /** Optional and unverified. ToDoddle never emails this address. */
    public val reporter: Reporter? = null,
    /** Files the person chose and previewed. Up to 5. */
    public val attachments: List<Attachment> = emptyList(),
    /** The form version the person filled in. When null, the SDK uses the current config. */
    public val formVersion: Int? = null,
    public val idempotencyKey: String = newIdempotencyKey(),
) {
    public companion object {
        /** A new key that matches `^[A-Za-z0-9_-]{16,64}$` (a UUID without dashes). */
        @JvmStatic
        public fun newIdempotencyKey(): String = UUID.randomUUID().toString().replace("-", "")
    }
}

/** A file the person chose. The SDK never adds one by itself. */
public class Attachment(
    public val fileName: String,
    public val contentType: String,
    public val bytes: ByteArray,
) {
    public val size: Long get() = bytes.size.toLong()
}

/** Facts about the app and device. All optional. Never put URL query strings or personal data here. */
@Serializable
public data class ReportContext(
    val platform: String? = null,
    val appVersion: String? = null,
    val build: String? = null,
    val osName: String? = null,
    val osVersion: String? = null,
    val deviceModel: String? = null,
    val locale: String? = null,
    /** Screen or route name, without a query string. */
    val screen: String? = null,
    /** App-defined key/value context, shown on the ticket as is. Up to 20 entries. */
    val extra: Map<String, String>? = null,
) {
    /** Returns this context with blank values filled from [fallback]. */
    public fun mergedOver(fallback: ReportContext?): ReportContext {
        if (fallback == null) return this
        return ReportContext(
            platform = platform ?: fallback.platform,
            appVersion = appVersion ?: fallback.appVersion,
            build = build ?: fallback.build,
            osName = osName ?: fallback.osName,
            osVersion = osVersion ?: fallback.osVersion,
            deviceModel = deviceModel ?: fallback.deviceModel,
            locale = locale ?: fallback.locale,
            screen = screen ?: fallback.screen,
            extra = extra ?: fallback.extra,
        )
    }
}

/** Optional and unverified details about the person reporting. */
@Serializable
public data class Reporter(
    val name: String? = null,
    val email: String? = null,
    /** The app's own user or account ID. */
    val customerReference: String? = null,
)

/** The result of a report. [reportId] is opaque and safe to show as a reference. */
@Serializable
public data class ReportReceipt(
    val reportId: String,
    val status: String,
) {
    public companion object {
        public const val STATUS_RECEIVED: String = "received"
        public const val STATUS_AWAITING_UPLOADS: String = "awaiting_uploads"
    }
}
