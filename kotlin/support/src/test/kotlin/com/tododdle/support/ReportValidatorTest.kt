package com.tododdle.support

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ReportValidatorTest {
    private val config = SupportConfig(
        project = ProjectInfo("Mosslight"),
        form = Form(
            version = 3,
            types = listOf(ReportTypeOption(ReportType.PROBLEM, "Problem"), ReportTypeOption(ReportType.FEEDBACK, "Feedback")),
            title = TitleSpec(enabled = true, required = true, label = "Summary"),
            description = DescriptionSpec(required = true, label = "What happened?"),
            fields = listOf(
                FieldDefinition("area", "Area", FieldType.SELECT, required = true, options = listOf("Home", "Settings")),
                FieldDefinition("code", "Code", FieldType.SHORT_TEXT, required = false),
            ),
            attachments = AttachmentRules(enabled = true, maxCount = 1, maxBytes = 10, contentTypes = listOf("image/png")),
        ),
        wording = Wording("Report", null, "Send", "Thanks", "We read every report."),
        theme = Theme("#2f6d4f", "#ffffff", "rounded"),
    )

    private fun valid() = Report(
        type = ReportType.PROBLEM,
        title = "Broken",
        description = "It broke",
        fields = mapOf("area" to "Home"),
    )

    @Test
    fun validReportPasses() {
        assertEquals(emptyMap<String, String>(), ReportValidator.validate(valid(), config))
    }

    @Test
    fun requiredValuesAndOptionsAreChecked() {
        val report = Report(type = ReportType.QUESTION, title = " ", description = "", fields = mapOf("area" to "Elsewhere"))
        val errors = ReportValidator.validate(report, config)
        assertEquals(setOf("type", "title", "description", "area"), errors.keys)
    }

    @Test
    fun lengthsFollowTheFieldType() {
        val report = Report(
            type = ReportType.PROBLEM, title = "t", description = "d",
            fields = mapOf("area" to "Home", "code" to "x".repeat(Limits.SHORT_TEXT_MAX_LENGTH + 1)),
        )
        assertEquals(setOf("code"), ReportValidator.validate(report, config).keys)
    }

    @Test
    fun attachmentRulesAreChecked() {
        fun withFiles(vararg files: Attachment) = Report(
            type = ReportType.PROBLEM, title = "t", description = "d", fields = mapOf("area" to "Home"), attachments = files.toList(),
        )
        val png = Attachment("a.png", "image/png", ByteArray(5))
        assertTrue(ReportValidator.validate(withFiles(png), config).isEmpty())
        assertEquals(setOf("attachments"), ReportValidator.validate(withFiles(png, png), config).keys)
        assertEquals(setOf("attachments"), ReportValidator.validate(withFiles(Attachment("a.png", "image/png", ByteArray(11))), config).keys)
        assertEquals(setOf("attachments"), ReportValidator.validate(withFiles(Attachment("a.pdf", "application/pdf", ByteArray(5))), config).keys)
        assertEquals(setOf("attachments"), ReportValidator.validate(withFiles(Attachment("a.png", "image/png", ByteArray(0))), config).keys)
    }

    @Test
    fun contractLimitsApplyWithoutAConfig() {
        val report = Report(
            type = ReportType.PROBLEM,
            description = "x".repeat(Limits.DESCRIPTION_MAX_LENGTH + 1),
            idempotencyKey = "short",
        )
        assertEquals(setOf("idempotencyKey", "description"), ReportValidator.validate(report).keys)
    }

    @Test
    fun newIdempotencyKeysMatchTheContract() {
        val key = Report.newIdempotencyKey()
        assertTrue(Regex("^[A-Za-z0-9_-]{16,64}$").matches(key))
    }
}
