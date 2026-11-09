package com.tododdle.support.compose

import androidx.compose.ui.graphics.Color
import com.tododdle.support.ReportType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ReportSheetLogicTest {
    @Test
    fun parsesThemeColours() {
        assertEquals(Color(0xFF2F6D4F), parseColor("#2f6d4f"))
        assertNull(parseColor("2f6d4f"))
        assertNull(parseColor("#fff"))
    }

    @Test
    fun sameContentReusesTheIdempotencyKey() {
        fun build(description: String, previous: Pair<List<Any?>, String>?) = buildReport(
            type = ReportType.PROBLEM, title = null, description = description, fields = mapOf("area" to "Home", "steps" to " "),
            attachment = null, context = null, reporter = null, formVersion = 3, previous = previous,
        )
        val (first, fingerprint) = build("It broke", null)
        assertEquals(mapOf("area" to "Home"), first.fields)
        val (retry, _) = build("It broke ", fingerprint to first.idempotencyKey)
        assertEquals(first.idempotencyKey, retry.idempotencyKey)
        val (edited, _) = build("It broke badly", fingerprint to first.idempotencyKey)
        assertNotEquals(first.idempotencyKey, edited.idempotencyKey)
    }

    @Test
    fun sampleSizeKeepsTheLongSideWithinTheLimit() {
        assertEquals(1, ScreenshotEncoder.sampleSize(1000, 800, 1024))
        assertEquals(4, ScreenshotEncoder.sampleSize(4000, 3000, 1024))
    }
}
