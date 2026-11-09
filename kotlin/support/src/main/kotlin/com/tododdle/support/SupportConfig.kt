package com.tododdle.support

import kotlinx.serialization.Serializable

/**
 * The report form, wording and branding from `GET /config`.
 *
 * Unknown response fields are ignored. Enum-like values ([ReportType], [FieldType] and
 * [Theme.corners]) are plain strings so new values from the server do not break decoding.
 */
@Serializable
public data class SupportConfig(
    val project: ProjectInfo,
    val form: Form,
    val wording: Wording,
    val theme: Theme,
)

@Serializable
public data class ProjectInfo(
    /** Display name for the dialog title. */
    val name: String,
    val logoUrl: String? = null,
)

@Serializable
public data class Form(
    /** Increases whenever the project changes the form. Sent back as `formVersion`. */
    val version: Int,
    /** Report types the project offers, in order. Always at least one. */
    val types: List<ReportTypeOption>,
    val title: TitleSpec? = null,
    val description: DescriptionSpec? = null,
    val fields: List<FieldDefinition> = emptyList(),
    val attachments: AttachmentRules,
)

@Serializable
public data class ReportTypeOption(
    val value: ReportType,
    val label: String,
)

@Serializable
public data class TitleSpec(
    val enabled: Boolean,
    val required: Boolean,
    val label: String,
    val maxLength: Int = Limits.TITLE_MAX_LENGTH,
)

@Serializable
public data class DescriptionSpec(
    val required: Boolean,
    val label: String,
    val placeholder: String? = null,
    val maxLength: Int = Limits.DESCRIPTION_MAX_LENGTH,
)

@Serializable
public data class FieldDefinition(
    /** Stable key; never reused for a different meaning. */
    val key: String,
    val label: String,
    val type: FieldType,
    val required: Boolean,
    /** For [FieldType.SELECT] only. */
    val options: List<String> = emptyList(),
    val maxLength: Int? = null,
) {
    /** The maximum length the server accepts for this field. */
    public val effectiveMaxLength: Int
        get() = maxLength ?: when (type) {
            FieldType.SHORT_TEXT -> Limits.SHORT_TEXT_MAX_LENGTH
            else -> Limits.LONG_TEXT_MAX_LENGTH
        }
}

@Serializable
public data class AttachmentRules(
    val enabled: Boolean,
    val maxCount: Int,
    /** Per file. 10 MB in v1. */
    val maxBytes: Long,
    val contentTypes: List<String>,
)

@Serializable
public data class Wording(
    val dialogTitle: String,
    val intro: String? = null,
    val submitLabel: String,
    val thankYouTitle: String,
    val thankYouMessage: String,
)

@Serializable
public data class Theme(
    /** `#rrggbb`. */
    val accent: String,
    /** `#rrggbb`, readable on [accent]. */
    val onAccent: String,
    /** `rounded` or `square`. */
    val corners: String,
    /** A font id from the portal list. The SDK uses the app font. */
    val headingFont: String? = null,
) {
    public val isSquare: Boolean get() = corners == "square"
}

/** A report type. Known values are constants; the server may add new ones. */
@Serializable
@JvmInline
public value class ReportType(public val value: String) {
    override fun toString(): String = value

    public companion object {
        public val PROBLEM: ReportType = ReportType("problem")
        public val FEEDBACK: ReportType = ReportType("feedback")
        public val QUESTION: ReportType = ReportType("question")
    }
}

/** A custom field type. Known values are constants; the server may add new ones. */
@Serializable
@JvmInline
public value class FieldType(public val value: String) {
    override fun toString(): String = value

    public companion object {
        public val SHORT_TEXT: FieldType = FieldType("SHORT_TEXT")
        public val LONG_TEXT: FieldType = FieldType("LONG_TEXT")
        public val SELECT: FieldType = FieldType("SELECT")
    }
}

/** Fixed v1 limits from the contract. */
public object Limits {
    public const val TITLE_MAX_LENGTH: Int = 160
    public const val DESCRIPTION_MAX_LENGTH: Int = 10_000
    public const val SHORT_TEXT_MAX_LENGTH: Int = 300
    public const val LONG_TEXT_MAX_LENGTH: Int = 5_000
    public const val MAX_FIELDS: Int = 20
    public const val MAX_ATTACHMENTS: Int = 5
    public const val MAX_ATTACHMENT_BYTES: Long = 10L * 1024 * 1024
    public const val FILE_NAME_MAX_LENGTH: Int = 255
    public const val EXTRA_MAX_ENTRIES: Int = 20
    public const val EXTRA_VALUE_MAX_LENGTH: Int = 500

    /** Attachment content types the v1 contract allows. */
    public val CONTENT_TYPES: List<String> = listOf(
        "image/png", "image/jpeg", "image/webp", "image/gif", "application/pdf", "text/plain",
    )
}
