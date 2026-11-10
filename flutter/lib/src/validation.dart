import 'exception.dart';
import 'models.dart';

/// Field keys used for the built-in parts of a report in
/// [TododdleSupportException.fields].
abstract final class ReportFieldKeys {
  /// The report type.
  static const type = 'type';

  /// The title.
  static const title = 'title';

  /// The description.
  static const description = 'description';

  /// The attachments.
  static const attachments = 'attachments';

  /// The context.
  static const context = 'context';

  /// The custom field values as a whole.
  static const fields = 'fields';

  /// The idempotency key.
  static const idempotencyKey = 'idempotencyKey';
}

/// Checks [report] against the contract limits and, when given, the project's
/// [config]. Returns a message per field key; an empty map means the report
/// is valid.
///
/// The messages are plain English. The report sheet shows its own wording.
Map<String, String> validateReport(Report report, {SupportConfig? config}) {
  final errors = <String, String>{};
  void add(String key, String message) =>
      errors.putIfAbsent(key, () => message);

  final title = report.title?.trim() ?? '';
  final description = report.description?.trim() ?? '';

  // Contract limits (always).
  if ((report.title?.length ?? 0) > maxTitleLength) {
    add(ReportFieldKeys.title, 'Use at most $maxTitleLength characters.');
  }
  if ((report.description?.length ?? 0) > maxDescriptionLength) {
    add(
      ReportFieldKeys.description,
      'Use at most $maxDescriptionLength characters.',
    );
  }
  if (report.fields.length > maxFieldValues) {
    add(ReportFieldKeys.fields, 'Send at most $maxFieldValues fields.');
  }
  for (final entry in report.fields.entries) {
    if (entry.value.length > maxLongTextLength) {
      add(entry.key, 'Use at most $maxLongTextLength characters.');
    }
  }
  if (report.attachments.length > maxAttachments) {
    add(ReportFieldKeys.attachments, 'Attach at most $maxAttachments files.');
  }
  for (final a in report.attachments) {
    if (a.size < 1 || a.size > maxAttachmentBytes) {
      add(ReportFieldKeys.attachments, '${a.fileName} is empty or too large.');
    }
    if (a.fileName.isEmpty || a.fileName.length > 255) {
      add(ReportFieldKeys.attachments, 'A file name is empty or too long.');
    }
  }
  if (!RegExp(r'^[A-Za-z0-9_-]{16,64}$').hasMatch(report.idempotencyKey)) {
    add(ReportFieldKeys.idempotencyKey, 'The idempotency key is not valid.');
  }
  final extra = report.context?.extra ?? const {};
  if (extra.length > maxContextExtra ||
      extra.values.any((v) => v.length > 500)) {
    add(ReportFieldKeys.context, 'Context extra is too large.');
  }

  if (config == null) return errors;

  // The project's form.
  final form = config.form;
  if (!form.types.any((t) => t.value == report.type)) {
    add(ReportFieldKeys.type, 'Choose a report type.');
  }
  if (form.title.enabled) {
    if (form.title.required && title.isEmpty) {
      add(ReportFieldKeys.title, 'This field is required.');
    } else if ((report.title?.length ?? 0) > form.title.maxLength) {
      add(
        ReportFieldKeys.title,
        'Use at most ${form.title.maxLength} characters.',
      );
    }
  }
  if (form.description.required && description.isEmpty) {
    add(ReportFieldKeys.description, 'This field is required.');
  } else if ((report.description?.length ?? 0) > form.description.maxLength) {
    add(
      ReportFieldKeys.description,
      'Use at most ${form.description.maxLength} characters.',
    );
  }
  for (final field in form.fields) {
    final value = report.fields[field.key]?.trim() ?? '';
    if (value.isEmpty) {
      if (field.required) {
        add(
          field.key,
          field.type == FieldType.select
              ? 'Choose an option.'
              : 'This field is required.',
        );
      }
      continue;
    }
    if (field.type == FieldType.select && !field.options.contains(value)) {
      add(field.key, 'Choose one of the options.');
    } else if (value.length > field.effectiveMaxLength) {
      add(field.key, 'Use at most ${field.effectiveMaxLength} characters.');
    }
  }
  final rules = form.attachments;
  if (report.attachments.isNotEmpty) {
    if (!rules.enabled) {
      add(ReportFieldKeys.attachments, 'Attachments are not accepted.');
    } else if (report.attachments.length > rules.maxCount) {
      add(
        ReportFieldKeys.attachments,
        'Attach at most ${rules.maxCount} files.',
      );
    }
    for (final a in report.attachments) {
      if (!rules.contentTypes.contains(a.contentType)) {
        add(
          ReportFieldKeys.attachments,
          '${a.fileName} is not an allowed type.',
        );
      } else if (a.size > rules.maxBytes) {
        add(ReportFieldKeys.attachments, '${a.fileName} is too large.');
      }
    }
  }
  return errors;
}

/// Throws an [TododdleErrorCodes.invalidFields] exception when
/// [validateReport] finds problems.
void ensureValidReport(Report report, {SupportConfig? config}) {
  final errors = validateReport(report, config: config);
  if (errors.isEmpty) return;
  throw TododdleSupportException(
    code: TododdleErrorCodes.invalidFields,
    message: 'Check the highlighted fields.',
    fields: errors,
  );
}
