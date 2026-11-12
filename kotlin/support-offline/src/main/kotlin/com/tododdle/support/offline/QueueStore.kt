package com.tododdle.support.offline

import com.tododdle.support.Attachment
import com.tododdle.support.Configuration
import com.tododdle.support.Report
import com.tododdle.support.ReportContext
import com.tododdle.support.ReportType
import com.tododdle.support.Reporter
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File

/**
 * Queued reports on disk, one folder per idempotency key: `report.json` plus one file per
 * attachment. The key is kept so a resend never creates a second ticket.
 *
 * The queue is capped: at most [maxReports] reports, none older than [maxAgeMillis], and at most
 * [maxBytes] of report files in total. Saving a report drops the oldest ones first until the
 * queue fits. The report just saved is always kept.
 */
internal class QueueStore(
    private val root: File,
    private val maxReports: Int = SupportQueue.MAX_QUEUED_REPORTS,
    private val maxAgeMillis: Long = SupportQueue.MAX_QUEUED_AGE_MILLIS,
    private val maxBytes: Long = SupportQueue.MAX_QUEUED_BYTES,
    private val now: () -> Long = System::currentTimeMillis,
) {

    fun save(configuration: Configuration, report: Report): String {
        val id = report.idempotencyKey
        val folder = File(root, id)
        val temp = File(root, "$id.tmp")
        temp.deleteRecursively()
        temp.mkdirs()
        report.attachments.forEachIndexed { index, attachment -> File(temp, "attachment-$index").writeBytes(attachment.bytes) }
        val stored = StoredReport(
            key = configuration.key,
            baseUrl = configuration.baseUrl,
            appId = configuration.appId,
            collectContext = configuration.collectContext,
            cacheConfigOnDisk = configuration.cacheConfigOnDisk,
            maxRetryAfterSeconds = configuration.maxRetryAfterSeconds,
            savedAt = now(),
            idempotencyKey = id,
            type = report.type.value,
            formVersion = report.formVersion,
            title = report.title,
            description = report.description,
            fields = report.fields,
            context = report.context,
            reporter = report.reporter,
            attachments = report.attachments.map { StoredAttachment(it.fileName, it.contentType) },
        )
        File(temp, REPORT_FILE).writeText(json.encodeToString(StoredReport.serializer(), stored))
        folder.deleteRecursively()
        check(temp.renameTo(folder)) { "Could not save the queued report." }
        prune(keep = id)
        return id
    }

    /**
     * Drops expired reports, then the oldest reports until the count and byte caps hold.
     * [keep] is never dropped.
     */
    fun prune(keep: String? = null) {
        val entries = ids().map { id -> Entry(id, savedAt(id), sizeOf(File(root, id))) }.sortedBy { it.savedAt }
        val cutoff = now() - maxAgeMillis
        val remaining = entries.filterTo(mutableListOf()) { entry ->
            val expired = entry.savedAt < cutoff && entry.id != keep
            if (expired) delete(entry.id)
            !expired
        }
        var bytes = remaining.sumOf { it.bytes }
        val iterator = remaining.iterator()
        var count = remaining.size
        while (iterator.hasNext() && (count > maxReports || bytes > maxBytes)) {
            val entry = iterator.next()
            if (entry.id == keep) continue
            delete(entry.id)
            iterator.remove()
            count--
            bytes -= entry.bytes
        }
    }

    private class Entry(val id: String, val savedAt: Long, val bytes: Long)

    private fun savedAt(id: String): Long {
        val file = File(File(root, id), REPORT_FILE)
        val stored = runCatching { json.decodeFromString(StoredReport.serializer(), file.readText()) }.getOrNull()
        // Reports saved before savedAt existed fall back to the file time.
        return stored?.savedAt ?: file.lastModified()
    }

    private fun sizeOf(folder: File): Long = folder.walkTopDown().filter { it.isFile }.sumOf { it.length() }

    fun load(id: String): Pair<Configuration, Report>? {
        val folder = File(root, id)
        val file = File(folder, REPORT_FILE).takeIf { it.isFile } ?: return null
        val stored = runCatching { json.decodeFromString(StoredReport.serializer(), file.readText()) }.getOrNull()
            ?: return null
        if ((stored.savedAt ?: file.lastModified()) < now() - maxAgeMillis) return null
        val attachments = stored.attachments.mapIndexed { index, meta ->
            val bytes = File(folder, "attachment-$index").takeIf { it.isFile }?.readBytes() ?: return null
            Attachment(meta.fileName, meta.contentType, bytes)
        }
        val configuration = Configuration(
            key = stored.key,
            baseUrl = stored.baseUrl,
            appId = stored.appId,
            collectContext = stored.collectContext,
            cacheConfigOnDisk = stored.cacheConfigOnDisk,
            maxRetryAfterSeconds = stored.maxRetryAfterSeconds,
        )
        val report = Report(
            type = ReportType(stored.type),
            description = stored.description,
            title = stored.title,
            fields = stored.fields,
            context = stored.context,
            reporter = stored.reporter,
            attachments = attachments,
            formVersion = stored.formVersion,
            idempotencyKey = stored.idempotencyKey,
        )
        return configuration to report
    }

    fun delete(id: String) {
        File(root, id).deleteRecursively()
    }

    fun ids(): List<String> =
        root.listFiles()?.filter { it.isDirectory && !it.name.endsWith(".tmp") }?.map { it.name }.orEmpty()

    private companion object {
        const val REPORT_FILE = "report.json"
        val json = Json { ignoreUnknownKeys = true }
    }
}

@Serializable
internal class StoredReport(
    val key: String,
    val baseUrl: String,
    val appId: String? = null,
    val collectContext: Boolean = true,
    val cacheConfigOnDisk: Boolean = true,
    val maxRetryAfterSeconds: Long = 60,
    /** When the report was queued, in epoch milliseconds. */
    val savedAt: Long? = null,
    val idempotencyKey: String,
    val type: String,
    val formVersion: Int? = null,
    val title: String? = null,
    val description: String? = null,
    val fields: Map<String, String> = emptyMap(),
    val context: ReportContext? = null,
    val reporter: Reporter? = null,
    val attachments: List<StoredAttachment> = emptyList(),
)

@Serializable
internal class StoredAttachment(val fileName: String, val contentType: String)
