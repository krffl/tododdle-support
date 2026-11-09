package com.tododdle.support

/**
 * Client-side checks that mirror the server rules, so the form can show problems before sending.
 * The server still validates every report.
 *
 * Keys in the result: `type`, `title`, `description`, `attachments`, `idempotencyKey` or a
 * custom field key. Values are plain English messages.
 */
public object ReportValidator {
    private val idempotencyPattern = Regex("^[A-Za-z0-9_-]{16,64}$")

    /** Checks [report] against the fixed contract limits and, when given, the project's [config]. */
    @JvmStatic
    @JvmOverloads
    public fun validate(report: Report, config: SupportConfig? = null): Map<String, String> {
        val errors = linkedMapOf<String, String>()
        if (!idempotencyPattern.matches(report.idempotencyKey)) {
            errors["idempotencyKey"] = "The idempotency key must be 16 to 64 letters, digits, '-' or '_'."
        }
        checkLimits(report, errors)
        if (config != null) checkForm(report, config, errors)
        return errors
    }

    /** Throws [TododdleSupportException] with code [ErrorCode.INVALID_FIELDS] when [validate] finds problems. */
    @JvmStatic
    @JvmOverloads
    public fun requireValid(report: Report, config: SupportConfig? = null) {
        val errors = validate(report, config)
        if (errors.isNotEmpty()) {
            throw TododdleSupportException(
                code = ErrorCode.INVALID_FIELDS,
                httpStatus = null,
                message = "Check the highlighted fields.",
                fields = errors,
            )
        }
    }

    private fun checkLimits(report: Report, errors: MutableMap<String, String>) {
        report.title?.let {
            if (it.length > Limits.TITLE_MAX_LENGTH) errors["title"] = tooLong(Limits.TITLE_MAX_LENGTH)
        }
        report.description?.let {
            if (it.length > Limits.DESCRIPTION_MAX_LENGTH) errors["description"] = tooLong(Limits.DESCRIPTION_MAX_LENGTH)
        }
        if (report.fields.size > Limits.MAX_FIELDS) {
            errors["fields"] = "Send at most ${Limits.MAX_FIELDS} fields."
        }
        for ((key, value) in report.fields) {
            if (value.length > Limits.LONG_TEXT_MAX_LENGTH) errors[key] = tooLong(Limits.LONG_TEXT_MAX_LENGTH)
        }
        attachmentError(report.attachments, Limits.MAX_ATTACHMENTS, Limits.MAX_ATTACHMENT_BYTES, Limits.CONTENT_TYPES)
            ?.let { errors["attachments"] = it }
    }

    private fun checkForm(report: Report, config: SupportConfig, errors: MutableMap<String, String>) {
        val form = config.form
        if (form.types.none { it.value == report.type }) {
            errors["type"] = "Choose a report type."
        }
        form.title?.let { spec ->
            val title = report.title?.trim().orEmpty()
            if (spec.enabled && spec.required && title.isEmpty()) {
                errors["title"] = REQUIRED
            } else if (title.length > spec.maxLength) {
                errors["title"] = tooLong(spec.maxLength)
            }
        }
        form.description?.let { spec ->
            val description = report.description?.trim().orEmpty()
            if (spec.required && description.isEmpty()) {
                errors["description"] = REQUIRED
            } else if (description.length > spec.maxLength) {
                errors["description"] = tooLong(spec.maxLength)
            }
        }
        for (field in form.fields) {
            val value = report.fields[field.key]?.trim().orEmpty()
            when {
                value.isEmpty() && field.required ->
                    errors[field.key] = if (field.type == FieldType.SELECT) "Choose an option." else REQUIRED
                value.isEmpty() -> Unit
                field.type == FieldType.SELECT && value !in field.options ->
                    errors[field.key] = "Choose one of the options."
                value.length > field.effectiveMaxLength ->
                    errors[field.key] = tooLong(field.effectiveMaxLength)
            }
        }
        val rules = form.attachments
        if (report.attachments.isNotEmpty()) {
            val message = if (!rules.enabled) {
                "This form does not accept attachments."
            } else {
                attachmentError(report.attachments, rules.maxCount, rules.maxBytes, rules.contentTypes)
            }
            message?.let { errors["attachments"] = it }
        }
    }

    private fun attachmentError(
        attachments: List<Attachment>,
        maxCount: Int,
        maxBytes: Long,
        contentTypes: List<String>,
    ): String? {
        if (attachments.size > maxCount) return "Attach at most $maxCount files."
        for (attachment in attachments) {
            when {
                attachment.fileName.isBlank() || attachment.fileName.length > Limits.FILE_NAME_MAX_LENGTH ->
                    return "A file name is empty or too long."
                attachment.size < 1 -> return "${attachment.fileName} is empty."
                attachment.size > maxBytes -> return "${attachment.fileName} is larger than ${maxBytes / (1024 * 1024)} MB."
                attachment.contentType !in contentTypes -> return "${attachment.fileName} is not an allowed file type."
            }
        }
        return null
    }

    private fun tooLong(max: Int) = "Use $max characters or fewer."

    private const val REQUIRED = "This field is required."
}
