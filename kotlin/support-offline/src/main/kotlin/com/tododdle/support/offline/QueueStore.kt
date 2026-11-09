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
 */
internal class QueueStore(private val root: File) {

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
        return id
    }

    fun load(id: String): Pair<Configuration, Report>? {
        val folder = File(root, id)
        val file = File(folder, REPORT_FILE).takeIf { it.isFile } ?: return null
        val stored = runCatching { json.decodeFromString(StoredReport.serializer(), file.readText()) }.getOrNull()
            ?: return null
        val attachments = stored.attachments.mapIndexed { index, meta ->
            val bytes = File(folder, "attachment-$index").takeIf { it.isFile }?.readBytes() ?: return null
            Attachment(meta.fileName, meta.contentType, bytes)
        }
        val configuration = Configuration(
            key = stored.key,
            baseUrl = stored.baseUrl,
            appId = stored.appId,
            collectContext = stored.collectContext,
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
