package com.tododdle.support.compose

import android.graphics.Bitmap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuAnchorType
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.error
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.tododdle.support.Attachment
import com.tododdle.support.ErrorCode
import com.tododdle.support.FieldDefinition
import com.tododdle.support.FieldType
import com.tododdle.support.Report
import com.tododdle.support.ReportContext
import com.tododdle.support.ReportReceipt
import com.tododdle.support.ReportType
import com.tododdle.support.ReportValidator
import com.tododdle.support.Reporter
import com.tododdle.support.SupportConfig
import com.tododdle.support.TododdleSupport
import com.tododdle.support.TododdleSupportException
import kotlinx.coroutines.launch

/**
 * A modal bottom sheet that shows the project's report form from `GET /config`, themed with the
 * project's accent colour and corner style.
 *
 * Nothing is collected automatically beyond the core library's app and device context. A
 * screenshot is attached only when the host passes [screenshot] or the person picks one with the
 * photo picker; it is always shown as a preview with a remove button.
 *
 * @param support The headless client.
 * @param onDismissRequest Called when the person closes the sheet. Remove the sheet from composition.
 * @param screenshot An optional screenshot or image the host app supplies.
 * @param allowScreenshotPicker Show "Add screenshot", which opens the system photo picker.
 * @param context Extra context for the report, such as the current screen name.
 * @param reporter Optional, unverified reporter details from the host app.
 * @param strings The sheet's own wording. The form wording comes from the config.
 * @param onReported Called once the report is received.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
public fun ReportSheet(
    support: TododdleSupport,
    onDismissRequest: () -> Unit,
    modifier: Modifier = Modifier,
    screenshot: ScreenshotSource? = null,
    allowScreenshotPicker: Boolean = true,
    context: ReportContext? = null,
    reporter: Reporter? = null,
    strings: ReportSheetStrings = ReportSheetStrings(),
    onReported: (ReportReceipt) -> Unit = {},
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismissRequest,
        sheetState = sheetState,
        modifier = modifier,
    ) {
        ReportSheetContent(
            support = support,
            onClose = onDismissRequest,
            screenshot = screenshot,
            allowScreenshotPicker = allowScreenshotPicker,
            reportContext = context,
            reporter = reporter,
            strings = strings,
            onReported = onReported,
        )
    }
}

/**
 * The sheet's own wording, in English by default. Pass translated strings to localise it.
 * `reference` must contain `%s`, which is replaced with the report ID.
 */
public data class ReportSheetStrings(
    val loading: String = "Loading the report form…",
    val loadFailed: String = "The report form could not be loaded. Check your connection and try again.",
    val unavailable: String = "Reporting is not available right now.",
    val tryAgain: String = "Try again",
    val close: String = "Close",
    val reportType: String = "Report type",
    val required: String = "Required",
    val chooseOption: String = "Choose an option",
    val addScreenshot: String = "Add screenshot",
    val removeScreenshot: String = "Remove screenshot",
    val screenshotPreview: String = "Screenshot preview",
    val screenshotFailed: String = "That image could not be attached.",
    val sending: String = "Sending your report",
    val sendFailed: String = "Your report could not be sent. Check your connection and try again.",
    val fixFields: String = "Check the highlighted fields.",
    val reference: String = "Reference: %s",
    val done: String = "Done",
)

private sealed class ConfigState {
    data object Loading : ConfigState()
    data class Loaded(val config: SupportConfig) : ConfigState()
    data class Failed(val error: TododdleSupportException) : ConfigState()
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ReportSheetContent(
    support: TododdleSupport,
    onClose: () -> Unit,
    screenshot: ScreenshotSource?,
    allowScreenshotPicker: Boolean,
    reportContext: ReportContext?,
    reporter: Reporter?,
    strings: ReportSheetStrings,
    onReported: (ReportReceipt) -> Unit,
) {
    val scope = rememberCoroutineScope()
    var configState by remember { mutableStateOf<ConfigState>(ConfigState.Loading) }
    var reloadCount by remember { mutableStateOf(0) }

    LaunchedEffect(support, reloadCount) {
        configState = ConfigState.Loading
        configState = try {
            ConfigState.Loaded(support.config())
        } catch (e: TododdleSupportException) {
            ConfigState.Failed(e)
        }
    }

    val column = Modifier
        .fillMaxWidth()
        .verticalScroll(rememberScrollState())
        .imePadding()
        .navigationBarsPadding()
        .padding(horizontal = 24.dp, vertical = 8.dp)

    when (val state = configState) {
        ConfigState.Loading -> Column(column, horizontalAlignment = Alignment.CenterHorizontally) {
            CircularProgressIndicator(Modifier.semantics { contentDescription = strings.loading })
            Spacer(Modifier.size(24.dp))
        }
        is ConfigState.Failed -> Column(column, verticalArrangement = Arrangement.spacedBy(16.dp)) {
            val unavailable = state.error.httpStatus == 401 || state.error.httpStatus == 403
            Text(
                if (unavailable) strings.unavailable else strings.loadFailed,
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (!unavailable) Button(onClick = { reloadCount++ }) { Text(strings.tryAgain) }
                TextButton(onClick = onClose) { Text(strings.close) }
            }
        }
        is ConfigState.Loaded -> ReportForm(
            config = state.config,
            modifier = column,
            support = support,
            onClose = onClose,
            screenshot = screenshot,
            allowScreenshotPicker = allowScreenshotPicker,
            reportContext = reportContext,
            reporter = reporter,
            strings = strings,
            onReported = onReported,
            onFieldsChanged = { reloadCount++ },
            scope = scope,
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ReportForm(
    config: SupportConfig,
    modifier: Modifier,
    support: TododdleSupport,
    onClose: () -> Unit,
    screenshot: ScreenshotSource?,
    allowScreenshotPicker: Boolean,
    reportContext: ReportContext?,
    reporter: Reporter?,
    strings: ReportSheetStrings,
    onReported: (ReportReceipt) -> Unit,
    onFieldsChanged: () -> Unit,
    scope: kotlinx.coroutines.CoroutineScope,
) {
    val androidContext = LocalContext.current
    val form = config.form
    val accent = parseColor(config.theme.accent) ?: MaterialTheme.colorScheme.primary
    val onAccent = parseColor(config.theme.onAccent) ?: MaterialTheme.colorScheme.onPrimary
    val shape: Shape = if (config.theme.isSquare) RoundedCornerShape(0.dp) else RoundedCornerShape(12.dp)

    var type by remember(form.version) { mutableStateOf(form.types.firstOrNull()?.value ?: ReportType.PROBLEM) }
    var title by remember { mutableStateOf("") }
    var description by remember { mutableStateOf("") }
    val fieldValues = remember { mutableStateMapOf<String, String>() }
    val errors = remember { mutableStateMapOf<String, String>() }
    var attachment by remember { mutableStateOf<Attachment?>(null) }
    var preview by remember { mutableStateOf<Bitmap?>(null) }
    var screenshotError by remember { mutableStateOf(false) }
    var sending by remember { mutableStateOf(false) }
    var sendError by remember { mutableStateOf<String?>(null) }
    var receipt by remember { mutableStateOf<ReportReceipt?>(null) }
    // Reuse the idempotency key while the content is unchanged, so "Try again" never duplicates.
    var lastSent by remember { mutableStateOf<Pair<List<Any?>, String>?>(null) }

    val canAttach = ScreenshotEncoder.canAttachImages(form.attachments)

    suspend fun attach(source: ScreenshotSource) {
        val encoded = ScreenshotEncoder.encode(androidContext, source, form.attachments)
        attachment = encoded
        preview = encoded?.let { ScreenshotEncoder.preview(it) }
            ?: (source as? ScreenshotSource.FromBitmap)?.bitmap?.takeIf { encoded != null }
        screenshotError = encoded == null
        errors.remove("attachments")
    }

    LaunchedEffect(screenshot, canAttach) {
        if (screenshot != null && canAttach) attach(screenshot)
    }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) scope.launch { attach(ScreenshotSource.FromUri(uri)) }
    }

    receipt?.let { done ->
        Column(modifier, verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(
                config.wording.thankYouTitle,
                style = MaterialTheme.typography.headlineSmall,
                modifier = Modifier.semantics { heading(); liveRegion = LiveRegionMode.Polite },
            )
            Text(config.wording.thankYouMessage)
            Text(strings.reference.format(done.reportId), style = MaterialTheme.typography.bodySmall)
            Button(
                onClick = onClose,
                shape = shape,
                colors = ButtonDefaults.buttonColors(containerColor = accent, contentColor = onAccent),
                modifier = Modifier.fillMaxWidth(),
            ) { Text(strings.done) }
        }
        return
    }

    fun send() {
        val report = buildReport(
            type = type,
            title = title.takeIf { form.title?.enabled == true },
            description = description,
            fields = fieldValues.toMap(),
            attachment = attachment,
            context = reportContext,
            reporter = reporter,
            formVersion = form.version,
            previous = lastSent,
        )
        val localErrors = ReportValidator.validate(report.first, config)
        errors.clear()
        errors.putAll(localErrors)
        sendError = null
        if (localErrors.isNotEmpty()) {
            sendError = strings.fixFields
            return
        }
        lastSent = report.second to report.first.idempotencyKey
        sending = true
        scope.launch {
            try {
                val result = support.report(report.first)
                receipt = result
                onReported(result)
            } catch (e: TododdleSupportException) {
                when (e.code) {
                    ErrorCode.INVALID_FIELDS -> {
                        errors.putAll(e.fields)
                        sendError = strings.fixFields
                    }
                    ErrorCode.FIELDS_CHANGED -> {
                        errors.putAll(e.fields)
                        sendError = strings.fixFields
                        onFieldsChanged()
                    }
                    ErrorCode.KEY_REVOKED, ErrorCode.INVALID_KEY, ErrorCode.APP_NOT_ALLOWED,
                    ErrorCode.SUPPORT_UNAVAILABLE -> sendError = strings.unavailable
                    else -> sendError = strings.sendFailed
                }
            } finally {
                sending = false
            }
        }
    }

    Column(modifier, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(
            config.wording.dialogTitle,
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.semantics { heading() },
        )
        config.wording.intro?.takeIf { it.isNotBlank() }?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }

        if (form.types.size > 1) {
            Text(strings.reportType, style = MaterialTheme.typography.labelLarge)
            Column(Modifier.selectableGroup()) {
                form.types.forEach { option ->
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .heightIn(min = 48.dp)
                            .selectable(selected = type == option.value, onClick = { type = option.value }, role = Role.RadioButton),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(selected = type == option.value, onClick = null)
                        Spacer(Modifier.size(8.dp))
                        Text(option.label)
                    }
                }
            }
            errors["type"]?.let { ErrorText(it) }
        }

        form.title?.takeIf { it.enabled }?.let { spec ->
            FormTextField(
                value = title,
                onValueChange = { title = it.take(spec.maxLength); errors.remove("title") },
                label = spec.label,
                required = spec.required,
                error = errors["title"],
                singleLine = true,
                strings = strings,
            )
        }

        val descriptionSpec = form.description
        FormTextField(
            value = description,
            onValueChange = { description = it.take(descriptionSpec?.maxLength ?: 10_000); errors.remove("description") },
            label = descriptionSpec?.label ?: "Description",
            placeholder = descriptionSpec?.placeholder,
            required = descriptionSpec?.required ?: false,
            error = errors["description"],
            singleLine = false,
            strings = strings,
        )

        form.fields.forEach { field ->
            CustomField(
                field = field,
                value = fieldValues[field.key].orEmpty(),
                onValueChange = { fieldValues[field.key] = it; errors.remove(field.key) },
                error = errors[field.key],
                strings = strings,
            )
        }

        if (canAttach) {
            val current = attachment
            val currentPreview = preview
            if (current != null) {
                if (currentPreview != null) {
                    Image(
                        bitmap = currentPreview.asImageBitmap(),
                        contentDescription = strings.screenshotPreview,
                        contentScale = ContentScale.Fit,
                        modifier = Modifier.fillMaxWidth().heightIn(max = 240.dp),
                    )
                }
                OutlinedButton(onClick = { attachment = null; preview = null }, shape = shape) {
                    Text(strings.removeScreenshot)
                }
            } else if (allowScreenshotPicker) {
                OutlinedButton(
                    onClick = { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
                    shape = shape,
                ) { Text(strings.addScreenshot) }
            }
            if (screenshotError) ErrorText(strings.screenshotFailed)
            errors["attachments"]?.let { ErrorText(it) }
        }

        sendError?.let { ErrorText(it) }

        Button(
            onClick = { send() },
            enabled = !sending,
            shape = shape,
            colors = ButtonDefaults.buttonColors(containerColor = accent, contentColor = onAccent),
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
        ) {
            if (sending) {
                CircularProgressIndicator(
                    color = onAccent,
                    strokeWidth = 2.dp,
                    modifier = Modifier.size(20.dp).semantics { contentDescription = strings.sending },
                )
            } else {
                Text(config.wording.submitLabel)
            }
        }
        TextButton(onClick = onClose, modifier = Modifier.align(Alignment.CenterHorizontally)) {
            Text(strings.close)
        }
    }
}

@Composable
private fun FormTextField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    required: Boolean,
    error: String?,
    singleLine: Boolean,
    strings: ReportSheetStrings,
    placeholder: String? = null,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(if (required) "$label *" else label) },
        placeholder = placeholder?.let { { Text(it) } },
        isError = error != null,
        supportingText = error?.let { { Text(it) } },
        singleLine = singleLine,
        minLines = if (singleLine) 1 else 3,
        modifier = Modifier
            .fillMaxWidth()
            .semantics {
                if (required) stateDescription = strings.required
                if (error != null) error(error)
            },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CustomField(
    field: FieldDefinition,
    value: String,
    onValueChange: (String) -> Unit,
    error: String?,
    strings: ReportSheetStrings,
) {
    if (field.type == FieldType.SELECT && field.options.isNotEmpty()) {
        var expanded by remember { mutableStateOf(false) }
        ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = { expanded = it }) {
            OutlinedTextField(
                value = value,
                onValueChange = {},
                readOnly = true,
                label = { Text(if (field.required) "${field.label} *" else field.label) },
                placeholder = { Text(strings.chooseOption) },
                trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
                isError = error != null,
                supportingText = error?.let { { Text(it) } },
                modifier = Modifier
                    .fillMaxWidth()
                    .menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable)
                    .semantics {
                        if (field.required) stateDescription = strings.required
                        if (error != null) error(error)
                    },
            )
            ExposedDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                field.options.forEach { option ->
                    DropdownMenuItem(
                        text = { Text(option) },
                        onClick = {
                            onValueChange(option)
                            expanded = false
                        },
                    )
                }
            }
        }
    } else {
        // SHORT_TEXT is one line; LONG_TEXT and any newer type get a multi-line box.
        FormTextField(
            value = value,
            onValueChange = { onValueChange(it.take(field.effectiveMaxLength)) },
            label = field.label,
            required = field.required,
            error = error,
            singleLine = field.type == FieldType.SHORT_TEXT,
            strings = strings,
        )
    }
}

@Composable
private fun ErrorText(message: String) {
    Text(
        message,
        color = MaterialTheme.colorScheme.error,
        style = MaterialTheme.typography.bodySmall,
        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
    )
}

/**
 * Builds the report. The second value is a fingerprint of the content: when it matches the last
 * attempt, the last idempotency key is reused.
 */
internal fun buildReport(
    type: ReportType,
    title: String?,
    description: String,
    fields: Map<String, String>,
    attachment: Attachment?,
    context: ReportContext?,
    reporter: Reporter?,
    formVersion: Int,
    previous: Pair<List<Any?>, String>?,
): Pair<Report, List<Any?>> {
    val cleanFields = fields.mapValues { it.value.trim() }.filterValues { it.isNotEmpty() }
    val fingerprint = listOf(
        type.value, title?.trim(), description.trim(), cleanFields,
        attachment?.fileName, attachment?.contentType, attachment?.bytes?.contentHashCode(), formVersion,
    )
    val key = previous?.takeIf { it.first == fingerprint }?.second ?: Report.newIdempotencyKey()
    val report = Report(
        type = type,
        title = title?.trim()?.ifEmpty { null },
        description = description.trim().ifEmpty { null },
        fields = cleanFields,
        context = context,
        reporter = reporter,
        attachments = listOfNotNull(attachment),
        formVersion = formVersion,
        idempotencyKey = key,
    )
    return report to fingerprint
}

/** Parses `#rrggbb`. */
internal fun parseColor(hex: String): Color? {
    if (!Regex("^#[0-9a-fA-F]{6}$").matches(hex)) return null
    return Color(0xFF000000 or hex.substring(1).toLong(16))
}
