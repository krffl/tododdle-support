package com.tododdle.support.internal

import okhttp3.HttpUrl

/** Hosts where plain HTTP is allowed, so local test servers still work. */
private val LOOPBACK_HOSTS = setOf("127.0.0.1", "::1", "localhost")

/** True for `https`, or `http` to a loopback host (127.0.0.1, ::1, localhost). */
internal fun HttpUrl.isSecureOrLoopback(): Boolean =
    scheme == "https" || (scheme == "http" && host.lowercase() in LOOPBACK_HOSTS)

/**
 * Upload headers the SDK never sends, even when the server lists them. They could leak
 * credentials to the storage host or break the request framing.
 */
private val FORBIDDEN_UPLOAD_HEADERS = setOf("host", "authorization", "cookie", "connection", "transfer-encoding", "content-length")

internal fun isForbiddenUploadHeader(name: String): Boolean {
    val lower = name.lowercase()
    return lower in FORBIDDEN_UPLOAD_HEADERS || lower.startsWith("proxy-")
}

/** The screen or route name without its query string or fragment. */
internal fun stripQueryAndFragment(screen: String): String = screen.substringBefore('?').substringBefore('#')
