import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'exception.dart';
import 'json.dart';

/// A report type. The contract defines [problem], [feedback] and [question];
/// new values may be added in v1, so any string is kept as sent.
final class ReportType {
  /// Wraps a type value.
  const ReportType(this.value);

  /// Something is broken.
  static const problem = ReportType('problem');

  /// An idea or opinion.
  static const feedback = ReportType('feedback');

  /// A question.
  static const question = ReportType('question');

  /// The wire value.
  final String value;

  @override
  bool operator ==(Object other) => other is ReportType && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// The report form, wording and branding from `GET /config`.
class SupportConfig {
  /// Creates a config.
  const SupportConfig({
    required this.project,
    required this.form,
    required this.wording,
    required this.theme,
  });

  /// Reads a config from its JSON. Unknown fields are ignored.
  factory SupportConfig.fromJson(Map<String, Object?> json) => SupportConfig(
    project: SupportProject._fromJson(asMap(json['project'], 'project')),
    form: ReportForm._fromJson(asMap(json['form'], 'form')),
    wording: SupportWording._fromJson(asMap(json['wording'], 'wording')),
    theme: SupportTheme._fromJson(asMap(json['theme'], 'theme')),
  );

  /// The project shown in the dialog.
  final SupportProject project;

  /// The form to render.
  final ReportForm form;

  /// The dialog's wording.
  final SupportWording wording;

  /// The dialog's colours and corners.
  final SupportTheme theme;
}

/// The project shown in the dialog.
class SupportProject {
  /// Creates a project.
  const SupportProject({required this.name, this.logoUrl});

  factory SupportProject._fromJson(JsonMap json) => SupportProject(
    name: asString(json['name'], 'project.name'),
    logoUrl: asStringOrNull(json['logoUrl'], 'project.logoUrl'),
  );

  /// Display name for the dialog title.
  final String name;

  /// An optional logo URL.
  final String? logoUrl;
}

/// One report type the project offers.
class ReportTypeOption {
  /// Creates an option.
  const ReportTypeOption({required this.value, required this.label});

  /// The type.
  final ReportType value;

  /// Its label.
  final String label;
}

/// The title field settings.
class TitleSettings {
  /// Creates title settings.
  const TitleSettings({
    required this.enabled,
    required this.required,
    required this.label,
    this.maxLength = maxTitleLength,
  });

  /// Whether the form shows a title.
  final bool enabled;

  /// Whether a title is required (only when [enabled]).
  final bool required;

  /// The label.
  final String label;

  /// The longest title.
  final int maxLength;
}

/// The description field settings.
class DescriptionSettings {
  /// Creates description settings.
  const DescriptionSettings({
    required this.required,
    required this.label,
    this.placeholder,
    this.maxLength = maxDescriptionLength,
  });

  /// Whether a description is required.
  final bool required;

  /// The label.
  final String label;

  /// Hint text.
  final String? placeholder;

  /// The longest description.
  final int maxLength;
}

/// A custom field type. [unknown] covers types added after this SDK; the
/// sheet renders those as short text.
enum FieldType {
  /// One line of text.
  shortText,

  /// Several lines of text.
  longText,

  /// One of [FieldDefinition.options].
  select,

  /// A type this SDK does not know.
  unknown,
}

/// A custom field on the form.
class FieldDefinition {
  /// Creates a field.
  const FieldDefinition({
    required this.key,
    required this.label,
    required this.type,
    required this.required,
    this.options = const [],
    this.maxLength,
  });

  factory FieldDefinition._fromJson(JsonMap json) {
    final type = asString(json['type'], 'field.type');
    return FieldDefinition(
      key: asString(json['key'], 'field.key'),
      label: asString(json['label'], 'field.label'),
      type: switch (type) {
        'SHORT_TEXT' => FieldType.shortText,
        'LONG_TEXT' => FieldType.longText,
        'SELECT' => FieldType.select,
        _ => FieldType.unknown,
      },
      required: asBool(json['required'], 'field.required'),
      options: json['options'] == null
          ? const []
          : asList(
              json['options'],
              'field.options',
            ).map((o) => asString(o, 'field.options[]')).toList(),
      maxLength: asIntOrNull(json['maxLength'], 'field.maxLength'),
    );
  }

  /// The stable key. Values are sent under this key.
  final String key;

  /// The label.
  final String label;

  /// The type.
  final FieldType type;

  /// Whether a value is required.
  final bool required;

  /// The options for [FieldType.select].
  final List<String> options;

  /// The longest value. When null the contract defaults apply (300 for
  /// short text, 5000 otherwise).
  final int? maxLength;

  /// The longest value, with the contract defaults applied.
  int get effectiveMaxLength =>
      maxLength ??
      (type == FieldType.shortText ? maxShortTextLength : maxLongTextLength);
}

/// The attachment rules.
class AttachmentRules {
  /// Creates attachment rules.
  const AttachmentRules({
    required this.enabled,
    required this.maxCount,
    required this.maxBytes,
    required this.contentTypes,
  });

  /// Whether attachments are allowed.
  final bool enabled;

  /// The most attachments per report.
  final int maxCount;

  /// The largest file, in bytes.
  final int maxBytes;

  /// Allowed content types.
  final List<String> contentTypes;

  /// Whether a screenshot (PNG) can be attached.
  bool get allowsScreenshot =>
      enabled && maxCount > 0 && contentTypes.contains('image/png');
}

/// The report form.
class ReportForm {
  /// Creates a form.
  const ReportForm({
    required this.version,
    required this.types,
    required this.title,
    required this.description,
    required this.fields,
    required this.attachments,
  });

  factory ReportForm._fromJson(JsonMap json) {
    final title = asMapOrNull(json['title'], 'form.title');
    final description = asMapOrNull(json['description'], 'form.description');
    final attachments = asMap(json['attachments'], 'form.attachments');
    return ReportForm(
      version: asInt(json['version'], 'form.version'),
      types: asList(json['types'], 'form.types').map((t) {
        final m = asMap(t, 'form.types[]');
        return ReportTypeOption(
          value: ReportType(asString(m['value'], 'type.value')),
          label: asString(m['label'], 'type.label'),
        );
      }).toList(),
      title: title == null
          ? const TitleSettings(enabled: false, required: false, label: '')
          : TitleSettings(
              enabled: asBool(title['enabled'], 'title.enabled'),
              required: asBool(title['required'], 'title.required'),
              label: asString(title['label'], 'title.label'),
              maxLength:
                  asIntOrNull(title['maxLength'], 'title.maxLength') ??
                  maxTitleLength,
            ),
      description: description == null
          ? const DescriptionSettings(required: false, label: 'Description')
          : DescriptionSettings(
              required: asBool(description['required'], 'description.required'),
              label: asString(description['label'], 'description.label'),
              placeholder: asStringOrNull(
                description['placeholder'],
                'description.placeholder',
              ),
              maxLength:
                  asIntOrNull(
                    description['maxLength'],
                    'description.maxLength',
                  ) ??
                  maxDescriptionLength,
            ),
      fields: asList(json['fields'], 'form.fields')
          .map((f) => FieldDefinition._fromJson(asMap(f, 'form.fields[]')))
          .toList(),
      attachments: AttachmentRules(
        enabled: asBool(attachments['enabled'], 'attachments.enabled'),
        maxCount: asInt(attachments['maxCount'], 'attachments.maxCount'),
        maxBytes: asInt(attachments['maxBytes'], 'attachments.maxBytes'),
        contentTypes: asList(
          attachments['contentTypes'],
          'attachments.contentTypes',
        ).map((c) => asString(c, 'attachments.contentTypes[]')).toList(),
      ),
    );
  }

  /// Increases whenever the project changes the form. Sent back as
  /// `formVersion`.
  final int version;

  /// Report types, in order. Always at least one.
  final List<ReportTypeOption> types;

  /// The title field.
  final TitleSettings title;

  /// The description field.
  final DescriptionSettings description;

  /// Custom fields, in order.
  final List<FieldDefinition> fields;

  /// Attachment rules.
  final AttachmentRules attachments;
}

/// The dialog's wording.
class SupportWording {
  /// Creates wording.
  const SupportWording({
    required this.dialogTitle,
    required this.submitLabel,
    required this.thankYouTitle,
    required this.thankYouMessage,
    this.intro,
  });

  factory SupportWording._fromJson(JsonMap json) => SupportWording(
    dialogTitle: asString(json['dialogTitle'], 'wording.dialogTitle'),
    intro: asStringOrNull(json['intro'], 'wording.intro'),
    submitLabel: asString(json['submitLabel'], 'wording.submitLabel'),
    thankYouTitle: asString(json['thankYouTitle'], 'wording.thankYouTitle'),
    thankYouMessage: asString(
      json['thankYouMessage'],
      'wording.thankYouMessage',
    ),
  );

  /// The dialog title.
  final String dialogTitle;

  /// Optional text under the title.
  final String? intro;

  /// The submit button label.
  final String submitLabel;

  /// The thank-you title.
  final String thankYouTitle;

  /// The thank-you message. It never promises a reply.
  final String thankYouMessage;
}

/// Corner style.
enum SupportCorners {
  /// Rounded corners.
  rounded,

  /// Square corners.
  square,
}

/// The dialog's colours and corners.
class SupportTheme {
  /// Creates a theme.
  const SupportTheme({
    required this.accent,
    required this.onAccent,
    required this.corners,
    this.headingFont,
  });

  factory SupportTheme._fromJson(JsonMap json) => SupportTheme(
    accent: _parseHex(asString(json['accent'], 'theme.accent')),
    onAccent: _parseHex(asString(json['onAccent'], 'theme.onAccent')),
    corners: json['corners'] == 'square'
        ? SupportCorners.square
        : SupportCorners.rounded,
    headingFont: asStringOrNull(json['headingFont'], 'theme.headingFont'),
  );

  /// The accent colour as `0xAARRGGBB`.
  final int accent;

  /// The colour for text on [accent], as `0xAARRGGBB`.
  final int onAccent;

  /// Corner style.
  final SupportCorners corners;

  /// A portal font ID. The Flutter sheet ignores it and uses the app font.
  final String? headingFont;

  static int _parseHex(String value) {
    final match = RegExp(r'^#([0-9a-fA-F]{6})$').firstMatch(value);
    if (match == null) {
      throw TododdleSupportException.invalidResponse('bad colour $value');
    }
    return 0xFF000000 | int.parse(match.group(1)!, radix: 16);
  }
}

/// Facts about the app and device, sent with a report. All optional. The SDK
/// fills [platform], [appVersion], [build], [osName], [osVersion],
/// [deviceModel] and [locale] when they are not set. It never fills [screen]
/// or [extra].
class ReportContext {
  /// Creates a context.
  const ReportContext({
    this.platform,
    this.appVersion,
    this.build,
    this.osName,
    this.osVersion,
    this.deviceModel,
    this.locale,
    this.screen,
    this.extra = const {},
  });

  /// One of `web`, `ios`, `android`, `flutter`, `react-native`.
  final String? platform;

  /// The app version, for example `2.4.0`.
  final String? appVersion;

  /// The build number.
  final String? build;

  /// The operating system name.
  final String? osName;

  /// The operating system version.
  final String? osVersion;

  /// The device model.
  final String? deviceModel;

  /// A BCP 47 locale such as `en-GB`.
  final String? locale;

  /// The screen or route name. Anything from the first `?` or `#` on is
  /// never sent, so query strings and fragments cannot leak tokens.
  final String? screen;

  /// App-defined key/value context, shown on the ticket as is.
  final Map<String, String> extra;

  /// This context with empty values filled from [fallback].
  ReportContext mergedWith(ReportContext fallback) => ReportContext(
    platform: platform ?? fallback.platform,
    appVersion: appVersion ?? fallback.appVersion,
    build: build ?? fallback.build,
    osName: osName ?? fallback.osName,
    osVersion: osVersion ?? fallback.osVersion,
    deviceModel: deviceModel ?? fallback.deviceModel,
    locale: locale ?? fallback.locale,
    screen: screen ?? fallback.screen,
    extra: {...fallback.extra, ...extra},
  );

  /// Whether nothing is set.
  bool get isEmpty => toJson().isEmpty;

  /// The wire JSON. Empty values are left out.
  Map<String, Object?> toJson() => {
    'platform': ?platform,
    'appVersion': ?appVersion,
    'build': ?build,
    'osName': ?osName,
    'osVersion': ?osVersion,
    'deviceModel': ?deviceModel,
    'locale': ?locale,
    'screen': ?_screenWithoutQuery(screen),
    if (extra.isNotEmpty) 'extra': extra,
  };

  /// Reads a context from its wire JSON.
  factory ReportContext.fromJson(Map<String, Object?> json) => ReportContext(
    platform: asStringOrNull(json['platform'], 'context.platform'),
    appVersion: asStringOrNull(json['appVersion'], 'context.appVersion'),
    build: asStringOrNull(json['build'], 'context.build'),
    osName: asStringOrNull(json['osName'], 'context.osName'),
    osVersion: asStringOrNull(json['osVersion'], 'context.osVersion'),
    deviceModel: asStringOrNull(json['deviceModel'], 'context.deviceModel'),
    locale: asStringOrNull(json['locale'], 'context.locale'),
    screen: asStringOrNull(json['screen'], 'context.screen'),
    extra: json['extra'] == null
        ? const {}
        : asStringMap(json['extra'], 'context.extra'),
  );
}

/// [screen] cut at the first `?` or `#`, or null when nothing is left.
String? _screenWithoutQuery(String? screen) {
  if (screen == null) return null;
  final end = screen.indexOf(RegExp('[?#]'));
  final path = end < 0 ? screen : screen.substring(0, end);
  return path.isEmpty ? null : path;
}

/// Optional, unverified details about the person reporting. ToDoddle never
/// emails this address.
class Reporter {
  /// Creates a reporter.
  const Reporter({this.name, this.email, this.customerReference});

  /// Reads a reporter from its wire JSON.
  factory Reporter.fromJson(Map<String, Object?> json) => Reporter(
    name: asStringOrNull(json['name'], 'reporter.name'),
    email: asStringOrNull(json['email'], 'reporter.email'),
    customerReference: asStringOrNull(
      json['customerReference'],
      'reporter.customerReference',
    ),
  );

  /// A display name.
  final String? name;

  /// An email address.
  final String? email;

  /// The app's own user or account ID.
  final String? customerReference;

  /// The wire JSON.
  Map<String, Object?> toJson() => {
    'name': ?name,
    'email': ?email,
    'customerReference': ?customerReference,
  };
}

/// A file chosen and previewed by the person reporting.
class ReportAttachment {
  /// Creates an attachment.
  const ReportAttachment({
    required this.fileName,
    required this.contentType,
    required this.bytes,
  });

  /// The file name, 1 to 255 characters.
  final String fileName;

  /// One of the config's allowed content types.
  final String contentType;

  /// The raw bytes.
  final Uint8List bytes;

  /// The size in bytes.
  int get size => bytes.length;

  /// The declaration sent with the report (no bytes).
  Map<String, Object?> toDeclarationJson() => {
    'fileName': fileName,
    'contentType': contentType,
    'size': size,
  };
}

/// A report to send.
///
/// Each report gets one [idempotencyKey] when it is created. The SDK reuses it
/// on every retry, so sending the same [Report] object again never creates a
/// second ticket.
class Report {
  /// Creates a report. Leave [idempotencyKey] null to generate one.
  Report({
    required this.type,
    this.formVersion,
    this.title,
    this.description,
    this.fields = const {},
    this.context,
    this.reporter,
    this.attachments = const [],
    String? idempotencyKey,
  }) : idempotencyKey = idempotencyKey ?? newIdempotencyKey();

  /// The report type.
  final ReportType type;

  /// The form version the person filled in. When null the SDK uses the
  /// current config's version.
  final int? formVersion;

  /// An optional title.
  final String? title;

  /// The description.
  final String? description;

  /// Values by field key: text, or one of the options for a select field.
  final Map<String, String> fields;

  /// App context. Empty values are filled from the device unless the client
  /// turns that off.
  final ReportContext? context;

  /// Optional, unverified reporter details.
  final Reporter? reporter;

  /// Files chosen and previewed by the person.
  final List<ReportAttachment> attachments;

  /// Sent as `idempotencyKey`. 16 to 64 letters, digits, `_` or `-`.
  final String idempotencyKey;

  /// The `POST /reports` body.
  Map<String, Object?> toRequestJson({
    required int formVersion,
    ReportContext? context,
  }) {
    final ctx = context ?? this.context;
    final reporterJson = reporter?.toJson();
    return {
      'idempotencyKey': idempotencyKey,
      'type': type.value,
      'formVersion': formVersion,
      'title': ?_nonEmpty(title),
      'description': ?_nonEmpty(description),
      if (fields.isNotEmpty) 'fields': fields,
      if (ctx != null && !ctx.isEmpty) 'context': ctx.toJson(),
      if (reporterJson != null && reporterJson.isNotEmpty)
        'reporter': reporterJson,
      if (attachments.isNotEmpty)
        'attachments': attachments.map((a) => a.toDeclarationJson()).toList(),
    };
  }

  /// A JSON form that keeps everything, including attachment bytes, so a
  /// queued report can be sent later with the same idempotency key.
  Map<String, Object?> toQueueJson() => {
    'idempotencyKey': idempotencyKey,
    'type': type.value,
    'formVersion': ?formVersion,
    'title': ?title,
    'description': ?description,
    'fields': fields,
    'context': ?context?.toJson(),
    'reporter': ?reporter?.toJson(),
    'attachments': attachments
        .map(
          (a) => {
            'fileName': a.fileName,
            'contentType': a.contentType,
            'bytesBase64': base64Encode(a.bytes),
          },
        )
        .toList(),
  };

  /// Reads a report written by [toQueueJson].
  factory Report.fromQueueJson(Map<String, Object?> json) => Report(
    idempotencyKey: asString(json['idempotencyKey'], 'idempotencyKey'),
    type: ReportType(asString(json['type'], 'type')),
    formVersion: asIntOrNull(json['formVersion'], 'formVersion'),
    title: asStringOrNull(json['title'], 'title'),
    description: asStringOrNull(json['description'], 'description'),
    fields: json['fields'] == null
        ? const {}
        : asStringMap(json['fields'], 'fields'),
    context: json['context'] == null
        ? null
        : ReportContext.fromJson(asMap(json['context'], 'context')),
    reporter: json['reporter'] == null
        ? null
        : Reporter.fromJson(asMap(json['reporter'], 'reporter')),
    attachments: json['attachments'] == null
        ? const []
        : asList(json['attachments'], 'attachments').map((a) {
            final m = asMap(a, 'attachments[]');
            return ReportAttachment(
              fileName: asString(m['fileName'], 'fileName'),
              contentType: asString(m['contentType'], 'contentType'),
              bytes: base64Decode(asString(m['bytesBase64'], 'bytesBase64')),
            );
          }).toList(),
  );

  static String? _nonEmpty(String? value) =>
      value == null || value.trim().isEmpty ? null : value;
}

/// The result of [Report] sending.
class ReportReceipt {
  /// Creates a receipt.
  const ReportReceipt({required this.reportId, this.queued = false});

  /// A queued receipt: the report could not be sent now and waits in the
  /// offline queue.
  const ReportReceipt.queued() : reportId = null, queued = true;

  /// The report ID, safe to show as a reference. Null when [queued].
  final String? reportId;

  /// Whether the report waits in the offline queue instead of being sent.
  final bool queued;
}

/// Generates an idempotency key: 32 random hex characters.
String newIdempotencyKey() {
  final random = Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// Contract limits.
const int maxTitleLength = 160;

/// Contract limit for descriptions.
const int maxDescriptionLength = 10000;

/// Contract default for short text fields.
const int maxShortTextLength = 300;

/// Contract default for long text fields.
const int maxLongTextLength = 5000;

/// Contract limit for attachments per report.
const int maxAttachments = 5;

/// Contract limit for one attachment, in bytes.
const int maxAttachmentBytes = 10485760;

/// Contract limit for custom field values per report.
const int maxFieldValues = 20;

/// Contract limit for `context.extra` entries.
const int maxContextExtra = 20;
