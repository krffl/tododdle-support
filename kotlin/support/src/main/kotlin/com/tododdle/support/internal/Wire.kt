package com.tododdle.support.internal

import com.tododdle.support.ReportContext
import com.tododdle.support.ReportType
import com.tododdle.support.Reporter
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@OptIn(ExperimentalSerializationApi::class)
internal val SupportJson: Json = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    encodeDefaults = false
    coerceInputValues = true
}

/** `ReportRequest` in the contract. Null values are left out. */
@Serializable
internal class ReportRequestBody(
    val idempotencyKey: String,
    val type: ReportType,
    val formVersion: Int,
    val title: String? = null,
    val description: String? = null,
    val fields: Map<String, String>? = null,
    val context: ReportContext? = null,
    val reporter: Reporter? = null,
    val attachments: List<DeclaredAttachment>? = null,
)

@Serializable
internal class DeclaredAttachment(
    val fileName: String,
    val contentType: String,
    val size: Long,
)

@Serializable
internal class SubmitBody(val submitToken: String)

/** `ReportResponse` in the contract. */
@Serializable
internal class ReportResponseBody(
    val reportId: String,
    val status: String,
    val submitToken: String? = null,
    val expiresAt: String? = null,
    val uploads: List<UploadTarget> = emptyList(),
)

@Serializable
internal class UploadTarget(
    val uploadUrl: String,
    val headers: Map<String, String> = emptyMap(),
    val expiresAt: String? = null,
)

/** What the config file cache stores. */
@Serializable
internal class CachedConfig(val etag: String?, val body: String)
