package com.tododdle.support.internal

import com.tododdle.support.SupportConfig
import java.io.File
import java.security.MessageDigest

/**
 * The last good config, with its ETag. Kept in memory, and in a file under the app's cache folder
 * when [dir] is set. The config holds nothing private, so a plain file is fine.
 */
internal class ConfigCache(dir: File?, cacheId: String) {
    private val file: File? = dir?.let { File(File(it, "tododdle-support"), "config-${sha256(cacheId).take(20)}.json") }

    @Volatile
    private var memory: Entry? = null

    class Entry(val etag: String?, val config: SupportConfig, val body: String)

    @Synchronized
    fun get(): Entry? {
        memory?.let { return it }
        val stored = file?.takeIf { it.isFile } ?: return null
        val entry = runCatching {
            val cached = SupportJson.decodeFromString(CachedConfig.serializer(), stored.readText())
            Entry(cached.etag, SupportJson.decodeFromString(SupportConfig.serializer(), cached.body), cached.body)
        }.getOrNull()
        if (entry == null) stored.delete()
        memory = entry
        return entry
    }

    @Synchronized
    fun put(entry: Entry) {
        memory = entry
        val target = file ?: return
        runCatching {
            target.parentFile?.mkdirs()
            val temp = File(target.parentFile, target.name + ".tmp")
            temp.writeText(SupportJson.encodeToString(CachedConfig.serializer(), CachedConfig(entry.etag, entry.body)))
            if (!temp.renameTo(target)) {
                target.delete()
                temp.renameTo(target)
            }
        }
    }

    @Synchronized
    fun clear() {
        memory = null
        file?.delete()
    }

    private fun sha256(value: String): String =
        MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
}
