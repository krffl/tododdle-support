package com.tododdle.support.compose

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import com.tododdle.support.Attachment
import com.tododdle.support.AttachmentRules
import com.tododdle.support.Attachments
import com.tododdle.support.Limits
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream

/**
 * A screenshot the host app hands to [ReportSheet]. The sheet never captures the screen itself;
 * the person sees a preview and can remove it before sending.
 */
public sealed class ScreenshotSource {
    /** A bitmap the app captured when the person asked for it. */
    public class FromBitmap(public val bitmap: Bitmap) : ScreenshotSource()

    /** An image the person chose, for example with the photo picker. */
    public class FromUri(public val uri: Uri) : ScreenshotSource()
}

/** Turns images into attachments that fit the project's attachment rules. */
internal object ScreenshotEncoder {
    private const val MAX_SIDE = 2560
    private val IMAGE_TYPES = listOf("image/png", "image/jpeg", "image/webp", "image/gif")

    fun canAttachImages(rules: AttachmentRules): Boolean =
        rules.enabled && rules.maxCount > 0 && rules.contentTypes.any { it in IMAGE_TYPES }

    suspend fun encode(context: Context, source: ScreenshotSource, rules: AttachmentRules): Attachment? =
        withContext(Dispatchers.Default) {
            when (source) {
                is ScreenshotSource.FromBitmap -> fromBitmap(source.bitmap, "screenshot", rules)
                is ScreenshotSource.FromUri -> fromUri(context, source.uri, rules)
            }
        }

    private suspend fun fromUri(context: Context, uri: Uri, rules: AttachmentRules): Attachment? {
        // Read up to the contract limit; re-encode below when the project's limit is smaller.
        val original = Attachments.fromUri(context, uri, maxBytes = maxOf(rules.maxBytes, Limits.MAX_ATTACHMENT_BYTES))
        if (original != null && original.contentType in rules.contentTypes && original.size <= rules.maxBytes) {
            return original
        }
        // An unsupported format (HEIC, for example) or too large: decode and re-encode.
        val bitmap = withContext(Dispatchers.IO) { decodeSampled(context, uri) } ?: return null
        val baseName = original?.fileName?.substringBeforeLast('.')?.ifBlank { null } ?: "screenshot"
        return fromBitmap(bitmap, baseName, rules)
    }

    fun fromBitmap(bitmap: Bitmap, baseName: String, rules: AttachmentRules): Attachment? {
        val formats = listOfNotNull(
            ("image/png" to Bitmap.CompressFormat.PNG).takeIf { "image/png" in rules.contentTypes },
            ("image/jpeg" to Bitmap.CompressFormat.JPEG).takeIf { "image/jpeg" in rules.contentTypes },
            @Suppress("DEPRECATION")
            ("image/webp" to Bitmap.CompressFormat.WEBP).takeIf { "image/webp" in rules.contentTypes },
        )
        if (formats.isEmpty()) return null
        var current = bitmap.scaledToFit(MAX_SIDE)
        repeat(4) {
            for ((type, format) in formats) {
                val bytes = ByteArrayOutputStream().use { out ->
                    current.compress(format, if (format == Bitmap.CompressFormat.PNG) 100 else 85, out)
                    out.toByteArray()
                }
                if (bytes.isNotEmpty() && bytes.size <= rules.maxBytes) {
                    return Attachment("$baseName.${extension(type)}", type, bytes)
                }
            }
            current = Bitmap.createScaledBitmap(current, (current.width / 2).coerceAtLeast(1), (current.height / 2).coerceAtLeast(1), true)
        }
        return null
    }

    /** A small bitmap for the preview. */
    fun preview(attachment: Attachment, maxSide: Int = 1024): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(attachment.bytes, 0, attachment.bytes.size, bounds)
        val options = BitmapFactory.Options().apply { inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight, maxSide) }
        return BitmapFactory.decodeByteArray(attachment.bytes, 0, attachment.bytes.size, options)
    }

    private fun decodeSampled(context: Context, uri: Uri): Bitmap? = runCatching {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        val options = BitmapFactory.Options().apply { inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight, MAX_SIDE) }
        context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) }
    }.getOrNull()

    internal fun sampleSize(width: Int, height: Int, maxSide: Int): Int {
        var sample = 1
        while (width / sample > maxSide || height / sample > maxSide) sample *= 2
        return sample
    }

    private fun Bitmap.scaledToFit(maxSide: Int): Bitmap {
        val largest = maxOf(width, height)
        if (largest <= maxSide) return this
        val scale = maxSide.toFloat() / largest
        return Bitmap.createScaledBitmap(this, (width * scale).toInt().coerceAtLeast(1), (height * scale).toInt().coerceAtLeast(1), true)
    }

    private fun extension(type: String) = when (type) {
        "image/png" -> "png"
        "image/jpeg" -> "jpg"
        "image/webp" -> "webp"
        else -> "img"
    }
}
