import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../client.dart';
import '../exception.dart';
import '../models.dart';
import '../validation.dart';
import 'screenshot.dart';

/// Wording the sheet uses that does not come from the project config.
/// Override it to translate the sheet.
class ReportSheetStrings {
  /// Creates strings. Every value has an English default.
  const ReportSheetStrings({
    this.typeLabel = 'Type',
    this.required = 'This is required.',
    this.requiredSemantics = 'required',
    this.chooseOption = 'Choose an option.',
    this.addScreenshot = 'Add screenshot',
    this.removeScreenshot = 'Remove screenshot',
    this.screenshotPreview = 'Screenshot preview',
    this.screenshotTooLarge = 'The screenshot is too large to send.',
    this.screenshotFailed = 'The screenshot could not be taken.',
    this.sending = 'Sending',
    this.sendFailed =
        'Your report was not sent. Check your connection and try again.',
    this.formChanged =
        'The form has changed. Check the highlighted fields and send again.',
    this.loading = 'Loading the report form',
    this.loadFailed = 'The report form could not be loaded.',
    this.retry = 'Try again',
    this.close = 'Close',
    this.queuedMessage =
        'You are offline. Your report will be sent when you are back online.',
  });

  /// Label of the report type picker.
  final String typeLabel;

  /// Error for an empty required field.
  final String required;

  /// Added to the spoken label of required fields.
  final String requiredSemantics;

  /// Error for a select field with no choice.
  final String chooseOption;

  /// The add-screenshot button.
  final String addScreenshot;

  /// The remove-screenshot button.
  final String removeScreenshot;

  /// Spoken label of the screenshot preview.
  final String screenshotPreview;

  /// Error when the screenshot is over the size limit.
  final String screenshotTooLarge;

  /// Error when the screenshot cannot be taken.
  final String screenshotFailed;

  /// Spoken label of the progress indicator.
  final String sending;

  /// Error when the report cannot be sent.
  final String sendFailed;

  /// Error when the form changed on the server.
  final String formChanged;

  /// Spoken label while the form loads.
  final String loading;

  /// Error when the form cannot be loaded.
  final String loadFailed;

  /// The retry button.
  final String retry;

  /// The close button.
  final String close;

  /// Shown on the thank-you screen when the report was queued.
  final String queuedMessage;
}

/// Shows a [ReportSheet] in a modal bottom sheet. Completes with the receipt
/// when a report was sent or queued, or null when the person closed the sheet
/// without sending.
///
/// For a screenshot, either pass [screenshot] bytes you already have, or pass
/// [screenshotBoundaryKey] (the key of a [RepaintBoundary] around your app) and
/// the sheet shows an "Add screenshot" button that captures it only when the
/// person taps it.
Future<ReportReceipt?> showTododdleReportSheet(
  BuildContext context, {
  required TododdleSupport client,
  SupportConfig? config,
  Uint8List? screenshot,
  GlobalKey? screenshotBoundaryKey,
  Future<Uint8List?> Function()? captureScreenshot,
  ReportType? initialType,
  ReportContext? reportContext,
  Reporter? reporter,
  ReportSheetStrings strings = const ReportSheetStrings(),
}) {
  return showModalBottomSheet<ReportReceipt>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: ReportSheet(
        client: client,
        config: config,
        screenshot: screenshot,
        screenshotBoundaryKey: screenshotBoundaryKey,
        captureScreenshot: captureScreenshot,
        initialType: initialType,
        reportContext: reportContext,
        reporter: reporter,
        strings: strings,
        onClose: (receipt) => Navigator.of(sheetContext).pop(receipt),
      ),
    ),
  );
}

/// A Material report form rendered from the project's config.
///
/// It loads the config with [TododdleSupport.config] unless [config] is
/// given, themes itself from `config.theme`, validates required fields, sends
/// the report and shows the project's thank-you wording.
///
/// The sheet never captures the screen by itself. A screenshot is either
/// passed in as [screenshot], or captured when the person taps "Add
/// screenshot" (with [captureScreenshot] or [screenshotBoundaryKey]). The
/// person sees a preview and can remove it before sending.
class ReportSheet extends StatefulWidget {
  /// Creates a report sheet.
  const ReportSheet({
    super.key,
    required this.client,
    this.config,
    this.screenshot,
    this.screenshotBoundaryKey,
    this.captureScreenshot,
    this.initialType,
    this.reportContext,
    this.reporter,
    this.strings = const ReportSheetStrings(),
    this.onSubmitted,
    this.onClose,
  });

  /// The client that loads the config and sends the report.
  final TododdleSupport client;

  /// A config to use instead of loading one.
  final SupportConfig? config;

  /// A screenshot the app already has, shown as a removable preview.
  final Uint8List? screenshot;

  /// The key of a [RepaintBoundary] to capture when the person taps "Add
  /// screenshot".
  final GlobalKey? screenshotBoundaryKey;

  /// A custom capture to run when the person taps "Add screenshot". Takes
  /// priority over [screenshotBoundaryKey].
  final Future<Uint8List?> Function()? captureScreenshot;

  /// The report type selected first. Defaults to the config's first type.
  final ReportType? initialType;

  /// App context sent with the report, for example the screen name.
  final ReportContext? reportContext;

  /// Optional, unverified reporter details.
  final Reporter? reporter;

  /// Wording that does not come from the config.
  final ReportSheetStrings strings;

  /// Called when a report is sent or queued.
  final ValueChanged<ReportReceipt>? onSubmitted;

  /// Called when the person closes the sheet, with the receipt if a report
  /// was sent. Defaults to `Navigator.maybePop`.
  final void Function(ReportReceipt? receipt)? onClose;

  @override
  State<ReportSheet> createState() => _ReportSheetState();
}

enum _Phase { loading, loadFailed, form, done }

class _ReportSheetState extends State<ReportSheet> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _text = <String, TextEditingController>{};
  final _select = <String, String?>{};

  _Phase _phase = _Phase.loading;
  SupportConfig? _config;
  ReportType? _type;
  Uint8List? _screenshot;
  bool _submitting = false;
  bool _capturing = false;
  String? _error;
  String? _screenshotError;
  Map<String, String> _serverErrors = const {};
  ReportReceipt? _receipt;

  // Reused while the content is unchanged, so a second tap after a failure
  // keeps the same idempotency key.
  Report? _lastReport;
  String? _lastSignature;

  @override
  void initState() {
    super.initState();
    _screenshot = widget.screenshot;
    final config = widget.config;
    if (config != null) {
      _apply(config);
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _phase = _Phase.loading);
    try {
      final config = await widget.client.config();
      if (!mounted) return;
      setState(() => _apply(config));
    } on Object {
      if (!mounted) return;
      setState(() => _phase = _Phase.loadFailed);
    }
  }

  void _apply(SupportConfig config) {
    _config = config;
    final types = config.form.types.map((t) => t.value).toList();
    if (_type == null || !types.contains(_type)) {
      final initial = widget.initialType;
      _type = initial != null && types.contains(initial)
          ? initial
          : (types.isEmpty ? null : types.first);
    }
    for (final field in config.form.fields) {
      if (field.type == FieldType.select) {
        final current = _select[field.key];
        _select[field.key] = field.options.contains(current) ? current : null;
      } else {
        _text.putIfAbsent(field.key, TextEditingController.new);
      }
    }
    _phase = _Phase.form;
  }

  bool get _canCapture =>
      widget.captureScreenshot != null || widget.screenshotBoundaryKey != null;

  Future<void> _addScreenshot() async {
    final rules = _config!.form.attachments;
    setState(() {
      _capturing = true;
      _screenshotError = null;
    });
    Uint8List? bytes;
    try {
      final capture = widget.captureScreenshot;
      bytes = capture != null
          ? await capture()
          : await captureRepaintBoundary(widget.screenshotBoundaryKey!);
    } on Object {
      bytes = null;
    }
    if (!mounted) return;
    setState(() {
      _capturing = false;
      if (bytes == null || bytes.isEmpty) {
        _screenshotError = widget.strings.screenshotFailed;
      } else if (bytes.length > rules.maxBytes) {
        _screenshotError = widget.strings.screenshotTooLarge;
      } else {
        _screenshot = bytes;
      }
    });
  }

  Report _buildReport() {
    final config = _config!;
    final form = config.form;
    final fields = <String, String>{};
    for (final field in form.fields) {
      final value = field.type == FieldType.select
          ? _select[field.key]
          : _text[field.key]?.text.trim();
      if (value != null && value.isNotEmpty) fields[field.key] = value;
    }
    final screenshot = _screenshot;
    final attachments = screenshot != null && form.attachments.allowsScreenshot
        ? [
            ReportAttachment(
              fileName: 'screenshot.png',
              contentType: 'image/png',
              bytes: screenshot,
            ),
          ]
        : const <ReportAttachment>[];
    final title = form.title.enabled ? _title.text.trim() : '';
    final description = _description.text.trim();

    final signature = jsonEncode({
      'v': form.version,
      't': _type?.value,
      'title': title,
      'd': description,
      'f': fields,
      's': screenshot == null ? null : base64Encode(screenshot),
    });
    final last = _lastReport;
    if (last != null && signature == _lastSignature) return last;

    final report = Report(
      type: _type ?? form.types.first.value,
      formVersion: form.version,
      title: title.isEmpty ? null : title,
      description: description.isEmpty ? null : description,
      fields: fields,
      context: widget.reportContext,
      reporter: widget.reporter,
      attachments: attachments,
    );
    _lastReport = report;
    _lastSignature = signature;
    return report;
  }

  Future<void> _submit() async {
    setState(() {
      _error = null;
      _serverErrors = const {};
    });
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final report = _buildReport();
    setState(() => _submitting = true);
    try {
      final receipt = await widget.client.report(report);
      if (!mounted) return;
      widget.onSubmitted?.call(receipt);
      setState(() {
        _submitting = false;
        _receipt = receipt;
        _phase = _Phase.done;
      });
    } on TododdleSupportException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _serverErrors = e.fields;
        _error = e.code == TododdleErrorCodes.fieldsChanged
            ? widget.strings.formChanged
            : (e.fields.isEmpty ? widget.strings.sendFailed : null);
      });
      if (e.code == TododdleErrorCodes.fieldsChanged) {
        try {
          final config = await widget.client.config();
          if (mounted) setState(() => _apply(config));
        } on Object {
          // Keep the old form; the error is already shown.
        }
      }
      _formKey.currentState?.validate();
    } on Object {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = widget.strings.sendFailed;
      });
    }
  }

  void _close() {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose(_receipt);
    } else {
      Navigator.of(context).maybePop(_receipt);
    }
  }

  ThemeData _theme(BuildContext context, SupportTheme? theme) {
    final base = Theme.of(context);
    if (theme == null) return base;
    final radius = BorderRadius.circular(
      theme.corners == SupportCorners.square ? 0 : 12,
    );
    final shape = RoundedRectangleBorder(borderRadius: radius);
    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: Color(theme.accent),
        onPrimary: Color(theme.onAccent),
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        border: OutlineInputBorder(borderRadius: radius),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: Color(theme.accent),
          foregroundColor: Color(theme.onAccent),
          shape: shape,
          minimumSize: const Size.fromHeight(48),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(shape: shape),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: _theme(context, _config?.theme),
      child: Builder(
        builder: (context) => Material(
          type: MaterialType.transparency,
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: switch (_phase) {
                _Phase.loading => _buildLoading(),
                _Phase.loadFailed => _buildLoadFailed(context),
                _Phase.form => _buildForm(context),
                _Phase.done => _buildDone(context),
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoading() => Padding(
    padding: const EdgeInsets.all(32),
    child: Center(
      child: CircularProgressIndicator(semanticsLabel: widget.strings.loading),
    ),
  );

  Widget _buildLoadFailed(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      _header(context, null),
      const SizedBox(height: 16),
      Text(widget.strings.loadFailed, textAlign: TextAlign.center),
      const SizedBox(height: 16),
      OutlinedButton(onPressed: _load, child: Text(widget.strings.retry)),
    ],
  );

  Widget _header(BuildContext context, String? title) => Row(
    children: [
      Expanded(
        child: title == null
            ? const SizedBox.shrink()
            : Semantics(
                header: true,
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
      ),
      IconButton(
        onPressed: _submitting ? null : _close,
        icon: const Icon(Icons.close),
        tooltip: widget.strings.close,
      ),
    ],
  );

  Widget _label(String text, bool required) => Text(
    required ? '$text *' : text,
    semanticsLabel: required
        ? '$text, ${widget.strings.requiredSemantics}'
        : text,
  );

  String? _requiredText(String? value, bool required, String key) {
    final server = _serverErrors[key];
    if (server != null) return server;
    if (required && (value == null || value.trim().isEmpty)) {
      return widget.strings.required;
    }
    return null;
  }

  void _clearServerError(String key) {
    if (_serverErrors.containsKey(key)) {
      setState(() => _serverErrors = Map.of(_serverErrors)..remove(key));
    }
  }

  Widget _buildForm(BuildContext context) {
    final config = _config!;
    final form = config.form;
    final wording = config.wording;
    final strings = widget.strings;
    final gap = const SizedBox(height: 16);
    final textTheme = Theme.of(context).textTheme;

    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context, wording.dialogTitle),
          if (wording.intro != null && wording.intro!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(wording.intro!, style: textTheme.bodyMedium),
          ],
          gap,
          if (form.types.length > 1) ...[
            DropdownButtonFormField<ReportType>(
              key: const ValueKey('tododdle-type'),
              initialValue: _type,
              decoration: InputDecoration(
                label: _label(strings.typeLabel, true),
              ),
              items: [
                for (final t in form.types)
                  DropdownMenuItem(value: t.value, child: Text(t.label)),
              ],
              onChanged: _submitting
                  ? null
                  : (value) => setState(() => _type = value),
              validator: (value) =>
                  _serverErrors[ReportFieldKeys.type] ??
                  (value == null ? strings.chooseOption : null),
            ),
            gap,
          ],
          if (form.title.enabled) ...[
            TextFormField(
              key: const ValueKey('tododdle-title'),
              controller: _title,
              enabled: !_submitting,
              maxLength: form.title.maxLength,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                label: _label(form.title.label, form.title.required),
                counterText: '',
              ),
              onChanged: (_) => _clearServerError(ReportFieldKeys.title),
              validator: (value) => _requiredText(
                value,
                form.title.required,
                ReportFieldKeys.title,
              ),
            ),
            gap,
          ],
          TextFormField(
            key: const ValueKey('tododdle-description'),
            controller: _description,
            enabled: !_submitting,
            maxLength: form.description.maxLength,
            minLines: 3,
            maxLines: 8,
            keyboardType: TextInputType.multiline,
            decoration: InputDecoration(
              label: _label(form.description.label, form.description.required),
              hintText: form.description.placeholder,
              alignLabelWithHint: true,
              counterText: '',
            ),
            onChanged: (_) => _clearServerError(ReportFieldKeys.description),
            validator: (value) => _requiredText(
              value,
              form.description.required,
              ReportFieldKeys.description,
            ),
          ),
          for (final field in form.fields) ...[gap, _buildField(field)],
          if (form.attachments.allowsScreenshot &&
              (_screenshot != null || _canCapture)) ...[
            gap,
            _buildScreenshot(context),
          ],
          if (_error != null) ...[
            gap,
            Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                style: textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            key: const ValueKey('tododdle-submit'),
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      semanticsLabel: strings.sending,
                      color: Color(config.theme.onAccent),
                    ),
                  )
                : Text(wording.submitLabel),
          ),
        ],
      ),
    );
  }

  Widget _buildField(FieldDefinition field) {
    if (field.type == FieldType.select) {
      return DropdownButtonFormField<String>(
        key: ValueKey('tododdle-field-${field.key}'),
        initialValue: _select[field.key],
        isExpanded: true,
        decoration: InputDecoration(label: _label(field.label, field.required)),
        items: [
          for (final option in field.options)
            DropdownMenuItem(value: option, child: Text(option)),
        ],
        onChanged: _submitting
            ? null
            : (value) {
                setState(() => _select[field.key] = value);
                _clearServerError(field.key);
              },
        validator: (value) =>
            _serverErrors[field.key] ??
            (field.required && value == null
                ? widget.strings.chooseOption
                : null),
      );
    }
    final long = field.type == FieldType.longText;
    return TextFormField(
      key: ValueKey('tododdle-field-${field.key}'),
      controller: _text[field.key],
      enabled: !_submitting,
      maxLength: field.effectiveMaxLength,
      minLines: long ? 3 : 1,
      maxLines: long ? 8 : 1,
      keyboardType: long ? TextInputType.multiline : TextInputType.text,
      decoration: InputDecoration(
        label: _label(field.label, field.required),
        alignLabelWithHint: long,
        counterText: '',
      ),
      onChanged: (_) => _clearServerError(field.key),
      validator: (value) => _requiredText(value, field.required, field.key),
    );
  }

  Widget _buildScreenshot(BuildContext context) {
    final strings = widget.strings;
    final screenshot = _screenshot;
    final error =
        _serverErrors[ReportFieldKeys.attachments] ?? _screenshotError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (screenshot != null)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                label: strings.screenshotPreview,
                image: true,
                child: ExcludeSemantics(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(
                      screenshot,
                      key: const ValueKey('tododdle-screenshot-preview'),
                      height: 140,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: TextButton.icon(
                  key: const ValueKey('tododdle-remove-screenshot'),
                  onPressed: _submitting
                      ? null
                      : () => setState(() {
                          _screenshot = null;
                          _clearServerError(ReportFieldKeys.attachments);
                        }),
                  icon: const Icon(Icons.delete_outline),
                  label: Text(strings.removeScreenshot),
                ),
              ),
            ],
          )
        else
          OutlinedButton.icon(
            key: const ValueKey('tododdle-add-screenshot'),
            onPressed: _submitting || _capturing ? null : _addScreenshot,
            icon: const Icon(Icons.screenshot_outlined),
            label: Text(strings.addScreenshot),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              error,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildDone(BuildContext context) {
    final wording = _config!.wording;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Icon(
          Icons.check_circle_outline,
          size: 48,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 12),
        Semantics(
          header: true,
          liveRegion: true,
          child: Text(
            wording.thankYouTitle,
            textAlign: TextAlign.center,
            style: textTheme.titleLarge,
          ),
        ),
        const SizedBox(height: 8),
        Text(wording.thankYouMessage, textAlign: TextAlign.center),
        if (_receipt?.queued ?? false) ...[
          const SizedBox(height: 8),
          Text(widget.strings.queuedMessage, textAlign: TextAlign.center),
        ],
        const SizedBox(height: 24),
        FilledButton(
          key: const ValueKey('tododdle-close'),
          onPressed: _close,
          child: Text(widget.strings.close),
        ),
      ],
    );
  }
}
