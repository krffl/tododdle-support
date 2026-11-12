package com.tododdle.support.offline

import com.tododdle.support.Attachment
import com.tododdle.support.Configuration
import com.tododdle.support.Report
import com.tododdle.support.ReportContext
import com.tododdle.support.ReportType
import com.tododdle.support.Reporter
import okhttp3.OkHttpClient
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class QueueStoreTest {
    @get:Rule
    val temp = TemporaryFolder()

    @Test
    fun savedReportComesBackWithTheSameIdempotencyKey() {
        val store = QueueStore(temp.root)
        val report = Report(
            type = ReportType.PROBLEM,
            description = "Crashed",
            title = "Crash",
            fields = mapOf("area" to "Home"),
            context = ReportContext(screen = "Home", extra = mapOf("plan" to "pro")),
            reporter = Reporter(name = "Alex"),
            attachments = listOf(Attachment("a.png", "image/png", byteArrayOf(1, 2, 3))),
            formVersion = 3,
        )
        val configuration = Configuration(
            key = "tdsk_pub_x",
            baseUrl = "https://example.test/v1",
            collectContext = false,
            cacheConfigOnDisk = false,
            maxRetryAfterSeconds = 5,
        )

        val id = store.save(configuration, report)
        assertEquals(listOf(id), store.ids())

        val (loadedConfiguration, loaded) = store.load(id)!!
        assertEquals("tdsk_pub_x", loadedConfiguration.key)
        assertEquals("https://example.test/v1", loadedConfiguration.baseUrl)
        assertEquals(false, loadedConfiguration.collectContext)
        assertEquals(false, loadedConfiguration.cacheConfigOnDisk)
        assertEquals(5L, loadedConfiguration.maxRetryAfterSeconds)
        assertEquals(report.idempotencyKey, loaded.idempotencyKey)
        assertEquals(ReportType.PROBLEM, loaded.type)
        assertEquals(mapOf("area" to "Home"), loaded.fields)
        assertEquals(report.context, loaded.context)
        assertEquals(report.reporter, loaded.reporter)
        assertEquals(3, loaded.formVersion)
        assertArrayEquals(byteArrayOf(1, 2, 3), loaded.attachments.single().bytes)

        store.delete(id)
        assertEquals(emptyList<String>(), store.ids())
        assertNull(store.load(id))
    }

    @Test
    fun missingAttachmentFileDropsTheReport() {
        val store = QueueStore(temp.root)
        val report = Report(
            type = ReportType.PROBLEM,
            attachments = listOf(Attachment("a.txt", "text/plain", byteArrayOf(1))),
        )
        val id = store.save(Configuration(key = "tdsk_pub_x"), report)
        File(File(temp.root, id), "attachment-0").delete()
        assertNull(store.load(id))
    }

    @After
    fun resetFactory() {
        SupportQueue.httpClientFactory = null
    }

    private var clock = 1_000_000_000_000L

    private fun store(maxBytes: Long = SupportQueue.MAX_QUEUED_BYTES) =
        QueueStore(temp.root, maxBytes = maxBytes, now = { clock })

    private fun report(bytes: Int = 0) = Report(
        type = ReportType.PROBLEM,
        description = "x",
        attachments = if (bytes > 0) listOf(Attachment("a.txt", "text/plain", ByteArray(bytes))) else emptyList(),
    )

    private val configuration = Configuration(key = "tdsk_pub_x")

    @Test
    fun capsTheQueueAtTenReportsDroppingTheOldest() {
        val store = store()
        val ids = (1..12).map {
            clock += 1000
            store.save(configuration, report())
        }
        assertEquals(SupportQueue.MAX_QUEUED_REPORTS, store.ids().size)
        assertEquals(ids.drop(2).toSet(), store.ids().toSet())
    }

    @Test
    fun dropsReportsOlderThanSevenDays() {
        val store = store()
        val old = store.save(configuration, report())
        clock += SupportQueue.MAX_QUEUED_AGE_MILLIS - 1
        assertNotNull("Still inside the window", store.load(old))
        clock += 2
        assertNull("Expired reports are not sent", store.load(old))
        val fresh = store.save(configuration, report())
        assertEquals(listOf(fresh), store.ids())
    }

    @Test
    fun keepsTheQueueUnderTheByteBudgetDroppingTheOldest() {
        val store = store(maxBytes = 3_000)
        val first = store.save(configuration, report(bytes = 1_000))
        clock += 1000
        val second = store.save(configuration, report(bytes = 1_000))
        clock += 1000
        val third = store.save(configuration, report(bytes = 1_000))
        val remaining = store.ids().toSet()
        assertFalse(first in remaining)
        assertTrue(second in remaining)
        assertTrue(third in remaining)
    }

    @Test
    fun theNewestReportIsKeptEvenWhenItAloneIsOverBudget() {
        val store = store(maxBytes = 100)
        store.save(configuration, report(bytes = 10))
        clock += 1000
        val big = store.save(configuration, report(bytes = 500))
        assertEquals(listOf(big), store.ids())
    }

    @Test
    fun defaultCapsMatchTheOtherSdks() {
        assertEquals(10, SupportQueue.MAX_QUEUED_REPORTS)
        assertEquals(7L * 24 * 60 * 60 * 1000, SupportQueue.MAX_QUEUED_AGE_MILLIS)
        assertEquals(20L * 1024 * 1024, SupportQueue.MAX_QUEUED_BYTES)
    }

    @Test
    fun workerUsesTheAppsHttpClientFactory() {
        val stored = Configuration(key = "tdsk_pub_x", cacheConfigOnDisk = false, maxRetryAfterSeconds = 5)
        assertNull(SupportQueue.workerConfiguration(stored).httpClient)

        val client = OkHttpClient()
        SupportQueue.httpClientFactory = { client }
        val configuration = SupportQueue.workerConfiguration(stored)
        assertSame(client, configuration.httpClient)
        assertEquals(false, configuration.cacheConfigOnDisk)
        assertEquals(5L, configuration.maxRetryAfterSeconds)
    }
}
