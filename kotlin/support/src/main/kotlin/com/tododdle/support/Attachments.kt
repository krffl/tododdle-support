package com.tododdle.support

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Helpers that turn files the person chose into [Attachment]s. */
public object Attachments {
    /**
     * Reads a file the person chose (for example from the photo picker). Returns null when the
     * file cannot be read. The content type comes from the content resolver; check it against
     * [AttachmentRules.contentTypes] before sending, or use [ReportValidator].
     *
     * @param maxBytes Stop reading and return null when the file is larger than this.
     */
    @JvmStatic
    public suspend fun fromUri(
        context: Context,
        uri: Uri,
        maxBytes: Long = Limits.MAX_ATTACHMENT_BYTES,
    ): Attachment? = withContext(Dispatchers.IO) {
        val resolver = context.contentResolver
        val contentType = resolver.getType(uri) ?: return@withContext null
        val name = displayName(context, uri) ?: "attachment"
        val bytes = runCatching {
            resolver.openInputStream(uri)?.use { input ->
                val buffer = java.io.ByteArrayOutputStream()
                val chunk = ByteArray(64 * 1024)
                var total = 0L
                while (true) {
                    val read = input.read(chunk)
                    if (read < 0) break
                    total += read
                    if (total > maxBytes) return@use null
                    buffer.write(chunk, 0, read)
                }
                buffer.toByteArray()
            }
        }.getOrNull() ?: return@withContext null
        Attachment(name.take(Limits.FILE_NAME_MAX_LENGTH), contentType, bytes)
    }

    private fun displayName(context: Context, uri: Uri): String? = runCatching {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
    }.getOrNull()?.takeIf { it.isNotBlank() } ?: uri.lastPathSegment
}
