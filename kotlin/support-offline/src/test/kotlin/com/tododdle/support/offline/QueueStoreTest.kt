package com.tododdle.support.offline

import com.tododdle.support.Attachment
import com.tododdle.support.Configuration
import com.tododdle.support.Report
import com.tododdle.support.ReportContext
import com.tododdle.support.ReportType
import com.tododdle.support.Reporter
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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
        val configuration = Configuration(key = "tdsk_pub_x", baseUrl = "https://example.test/v1", collectContext = false)

        val id = store.save(configuration, report)
        assertEquals(listOf(id), store.ids())

        val (loadedConfiguration, loaded) = store.load(id)!!
        assertEquals("tdsk_pub_x", loadedConfiguration.key)
        assertEquals("https://example.test/v1", loadedConfiguration.baseUrl)
        assertEquals(false, loadedConfiguration.collectContext)
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
}
