package com.tododdle.support

import okhttp3.OkHttpClient

/**
 * Settings for [TododdleSupport].
 *
 * @property key The project's public SDK key (`tdsk_pub_…` or `tdsk_test_…`). It is safe to ship.
 * @property baseUrl The API base, including `/api/support/sdk/v1`.
 * @property appId Sent as `X-Tododdle-App-Id`. Defaults to the app's package name.
 * @property collectContext Add app version, build, Android version, device model and locale to
 *   each report. Nothing else is ever collected automatically.
 * @property cacheConfigOnDisk Keep the last good config in the app's cache folder, so the form
 *   still opens offline. The memory cache is always on.
 * @property maxRetryAfterSeconds The longest `Retry-After` the SDK waits for inside one call.
 *   A longer wait fails the call with [ErrorCode.RATE_LIMITED] and
 *   [TododdleSupportException.retryAfterSeconds] set, so the app or the offline queue can retry later.
 * @property httpClient Your own OkHttp client, for example to share its connection pool.
 */
public data class Configuration @JvmOverloads constructor(
    val key: String,
    val baseUrl: String = DEFAULT_BASE_URL,
    val appId: String? = null,
    val collectContext: Boolean = true,
    val cacheConfigOnDisk: Boolean = true,
    val maxRetryAfterSeconds: Long = 60,
    val httpClient: OkHttpClient? = null,
) {
    init {
        require(key.isNotBlank()) { "The SDK key is empty." }
        require(baseUrl.startsWith("https://") || baseUrl.startsWith("http://")) {
            "baseUrl must be an http(s) URL."
        }
    }

    override fun toString(): String =
        "Configuration(key=${key.take(12)}…, baseUrl=$baseUrl, appId=$appId)"

    public companion object {
        public const val DEFAULT_BASE_URL: String = "https://app.tododdle.com/api/support/sdk/v1"
    }
}
