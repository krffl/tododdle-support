package com.tododdle.support

import com.tododdle.support.internal.Environment
import java.io.File
import java.util.Collections

/** A fixed environment so tests never touch Android APIs. */
internal class FakeEnvironment(
    override val appId: String? = "com.example.app",
    override val cacheDir: File? = null,
) : Environment {
    override fun automaticContext(): ReportContext = ReportContext(
        platform = "android",
        appVersion = "9.9.9",
        build = "999",
        osName = "Android",
        osVersion = "15",
        deviceModel = "Pixel Test",
        locale = "en-GB",
    )
}

/** Records the delays the SDK asks for instead of waiting, so retry tests run instantly. */
internal class RecordingSleeper {
    val delays: MutableList<Long> = Collections.synchronizedList(mutableListOf())
    val total: Long get() = delays.sum()
    val sleep: suspend (Long) -> Unit = { delays += it }
}

internal fun newSupport(
    baseUrl: String,
    sleeper: RecordingSleeper = RecordingSleeper(),
    environment: Environment = FakeEnvironment(),
    key: String = "tdsk_pub_TESTKEY0000000000000000000000000",
    maxRetryAfterSeconds: Long = 60,
): TododdleSupport = TododdleSupport(
    Configuration(key = key, baseUrl = baseUrl, maxRetryAfterSeconds = maxRetryAfterSeconds),
    environment,
    sleeper.sleep,
)
