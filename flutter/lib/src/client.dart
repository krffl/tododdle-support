import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'device_context.dart';
import 'exception.dart';
import 'json.dart';
import 'models.dart';
import 'retry.dart';
import 'stores.dart';
import 'validation.dart';
import 'version.dart';

/// The result of [TododdleSupport.flushQueue].
class QueueFlushResult {
  /// Creates a result.
  const QueueFlushResult({
    required this.sent,
    required this.dropped,
    required this.remaining,
  });

  /// Reports sent, in queue order.
  final List<ReportReceipt> sent;

  /// Reports removed because they can never be sent (for example a revoked
  /// key or invalid fields), with the error for each.
  final List<TododdleSupportException> dropped;

  /// Reports still waiting, because the server could not be reached.
  final int remaining;
}

/// A headless client for the ToDoddle Support SDK API.
///
/// ```dart
/// final support = TododdleSupport(key: 'tdsk_pub_…', appId: 'com.example.app');
/// final config = await support.config();
/// final receipt = await support.report(Report(
///   type: ReportType.problem,
///   description: 'Favourites vanish after reopening the app.',
/// ));
/// ```
class TododdleSupport {
  /// Creates a client.
  ///
  /// - [key]: the project's public SDK key (`tdsk_pub_…` or `tdsk_test_…`).
  /// - [appId]: the iOS bundle ID or Android package name, sent as
  ///   `X-Tododdle-App-Id` when the key lists allowed app IDs.
  /// - [configStore]: keeps the last good config between launches.
  /// - [queueStore]: turns on the offline queue. Reports that cannot reach the
  ///   server are kept there and sent by [flushQueue].
  /// - [contextProvider]: fills empty context values. The default reads the
  ///   app version, build, OS, device model and locale. Pass null to send only
  ///   the context the app sets.
  TododdleSupport({
    required this.key,
    this.baseUrl = defaultBaseUrl,
    this.appId,
    http.Client? httpClient,
    ConfigStore? configStore,
    this.queueStore,
    this.contextProvider = collectDeviceContext,
    this.retryPolicy = RetryPolicy.standard,
    DelayFunction delay = realDelay,
    this.timeout = const Duration(seconds: 30),
  }) : _http = httpClient ?? http.Client(),
       _ownsHttp = httpClient == null,
       _configStore = configStore,
       _delay = delay;

  /// The production API base URL.
  static const defaultBaseUrl = 'https://app.tododdle.com/api/support/sdk/v1';

  /// The public SDK key.
  final String key;

  /// The API base URL, without a trailing slash.
  final String baseUrl;

  /// The app ID sent as `X-Tododdle-App-Id`, if any.
  final String? appId;

  /// The offline queue, if turned on.
  final ReportQueueStore? queueStore;

  /// Fills empty context values, or null to turn that off.
  final ContextProvider? contextProvider;

  /// The retry policy.
  final RetryPolicy retryPolicy;

  /// The timeout for each HTTP attempt.
  final Duration timeout;

  final http.Client _http;
  final bool _ownsHttp;
  final ConfigStore? _configStore;
  final DelayFunction _delay;

  CachedConfig? _cached;
  SupportConfig? _config;
  Future<void>? _flushing;

  /// The last config read by [config], if any.
  SupportConfig? get cachedConfig => _config;

  /// Reads the report form, wording and branding.
  ///
  /// Sends `If-None-Match` with the last `ETag` and reuses the cached config
  /// on `304`. If the server cannot be reached (network error or a retryable
  /// status), the last good config is returned so the sheet still opens
  /// offline; without one, the error is thrown.
  Future<SupportConfig> config() async {
    final cached = await _loadCached();
    try {
      final response = await _send(
        'GET',
        _uri('/config'),
        headers: {'If-None-Match': ?cached?.etag},
        ok: (status) => status == 200 || status == 304,
      );
      if (response.statusCode == 304) {
        if (cached == null) {
          throw TododdleSupportException.invalidResponse(
            '304 without a cached config',
          );
        }
        return _config ??= _parseConfig(cached.body);
      }
      final body = response.body;
      final config = _parseConfig(body);
      final fresh = CachedConfig(etag: response.headers['etag'], body: body);
      _cached = fresh;
      _config = config;
      await _configStore?.write(fresh);
      return config;
    } on TododdleSupportException catch (e) {
      if (e.isTransient && cached != null) {
        return _config ??= _parseConfig(cached.body);
      }
      rethrow;
    }
  }

  /// Sends [report], uploading its attachments first if it has any.
  ///
  /// The report is checked against the contract limits and, when the config
  /// for its form version is known, against the form. Problems throw a
  /// [TododdleErrorCodes.invalidFields] exception with a message per field.
  ///
  /// Every attempt uses the report's [Report.idempotencyKey], so retries
  /// never create a second ticket. When the server cannot be reached and the
  /// offline queue is on, the report is queued and the receipt has
  /// `queued: true`. Pass `queueIfOffline: false` to throw instead.
  Future<ReportReceipt> report(
    Report report, {
    bool queueIfOffline = true,
  }) async {
    var formVersion = report.formVersion;
    SupportConfig? config;
    if (formVersion == null) {
      config = await this.config();
      formVersion = config.form.version;
    } else {
      final known = _config ?? await _loadConfigQuietly();
      if (known != null && known.form.version == formVersion) config = known;
    }
    ensureValidReport(report, config: config);

    var context = report.context ?? const ReportContext();
    final provider = contextProvider;
    if (provider != null) {
      try {
        context = context.mergedWith(await provider());
      } catch (_) {
        // Context is optional; send what the app set.
      }
    }

    final resolved = Report(
      idempotencyKey: report.idempotencyKey,
      type: report.type,
      formVersion: formVersion,
      title: report.title,
      description: report.description,
      fields: report.fields,
      context: context,
      reporter: report.reporter,
      attachments: report.attachments,
    );

    try {
      return await _sendReport(resolved);
    } on TododdleSupportException catch (e) {
      final store = queueStore;
      if (e.isTransient && queueIfOffline && store != null) {
        await _enqueue(store, resolved);
        return const ReportReceipt.queued();
      }
      rethrow;
    }
  }

  /// The number of reports waiting in the offline queue.
  Future<int> queuedCount() async => (await queueStore?.read())?.length ?? 0;

  /// Sends queued reports, oldest first, with their original idempotency
  /// keys. Stops at the first report that still cannot reach the server.
  /// Reports that fail for good are removed and listed in
  /// [QueueFlushResult.dropped].
  ///
  /// Call it when the app starts or comes back online. Calls made while a
  /// flush is running wait for it and then flush again.
  Future<QueueFlushResult> flushQueue() async {
    final store = queueStore;
    if (store == null) {
      return const QueueFlushResult(sent: [], dropped: [], remaining: 0);
    }
    while (_flushing != null) {
      await _flushing;
    }
    final done = Completer<void>();
    _flushing = done.future;
    try {
      final entries = await store.read();
      final sent = <ReportReceipt>[];
      final dropped = <TododdleSupportException>[];
      var index = 0;
      for (; index < entries.length; index++) {
        final Report report;
        try {
          report = Report.fromQueueJson(
            asMap(jsonDecode(entries[index]), 'queued report'),
          );
        } on Object {
          dropped.add(
            TododdleSupportException.invalidResponse(
              'unreadable queued report',
            ),
          );
          continue;
        }
        try {
          sent.add(await _sendReport(report));
        } on TododdleSupportException catch (e) {
          if (e.isTransient) break;
          dropped.add(e);
        }
      }
      final rest = entries.sublist(index);
      // Keep anything queued while this flush ran.
      final now = await store.read();
      final added = now.length > entries.length
          ? now.sublist(entries.length)
          : const <String>[];
      await store.write([...rest, ...added]);
      return QueueFlushResult(
        sent: sent,
        dropped: dropped,
        remaining: rest.length + added.length,
      );
    } finally {
      _flushing = null;
      done.complete();
    }
  }

  /// Closes the HTTP client if this object created it.
  void close() {
    if (_ownsHttp) _http.close();
  }

  // ---------------------------------------------------------------------------

  Future<ReportReceipt> _sendReport(Report report) async {
    final created = await _send(
      'POST',
      _uri('/reports'),
      json: report.toRequestJson(formVersion: report.formVersion!),
      ok: (status) => status == 200 || status == 201,
    );
    final response = _ReportResponse.parse(created.body);
    if (response.status == 'received') {
      return ReportReceipt(reportId: response.reportId);
    }
    if (response.status != 'awaiting_uploads') {
      throw TododdleSupportException.invalidResponse(
        'unknown report status ${response.status}',
      );
    }
    final submitToken = response.submitToken;
    if (submitToken == null ||
        response.uploads.length != report.attachments.length) {
      throw TododdleSupportException.invalidResponse(
        'uploads do not match the declared attachments',
      );
    }
    for (var i = 0; i < report.attachments.length; i++) {
      final upload = response.uploads[i];
      await _send(
        'PUT',
        Uri.parse(upload.uploadUrl),
        headers: upload.headers,
        bytes: report.attachments[i].bytes,
        sdkHeaders: false,
        ok: (status) => status >= 200 && status < 300,
        failureCode: TododdleErrorCodes.uploadFailed,
      );
    }
    final submitted = await _send(
      'POST',
      _uri('/reports/${Uri.encodeComponent(response.reportId)}/submit'),
      json: {'submitToken': submitToken},
      ok: (status) => status == 200,
    );
    final result = _ReportResponse.parse(submitted.body);
    if (result.status != 'received') {
      throw TododdleSupportException.invalidResponse(
        'submit returned status ${result.status}',
      );
    }
    return ReportReceipt(reportId: result.reportId);
  }

  Future<void> _enqueue(ReportQueueStore store, Report report) async {
    final entries = await store.read();
    await store.write([...entries, jsonEncode(report.toQueueJson())]);
  }

  Future<CachedConfig?> _loadCached() async {
    if (_cached != null) return _cached;
    try {
      _cached = await _configStore?.read();
    } catch (_) {
      _cached = null;
    }
    return _cached;
  }

  Future<SupportConfig?> _loadConfigQuietly() async {
    final cached = await _loadCached();
    if (cached == null) return null;
    try {
      return _config = _parseConfig(cached.body);
    } on TododdleSupportException {
      return null;
    }
  }

  SupportConfig _parseConfig(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw TododdleSupportException.invalidResponse('config is not JSON');
    }
    return SupportConfig.fromJson(asMap(decoded, 'config'));
  }

  Uri _uri(String path) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$base$path');
  }

  /// Sends one call with retries per [retryPolicy]. Returns the response when
  /// [ok] accepts its status; otherwise throws.
  Future<http.Response> _send(
    String method,
    Uri uri, {
    required bool Function(int status) ok,
    Map<String, String> headers = const {},
    Object? json,
    List<int>? bytes,
    bool sdkHeaders = true,
    String? failureCode,
  }) async {
    final body = json == null ? bytes : utf8.encode(jsonEncode(json));
    for (var attempt = 1; ; attempt++) {
      final request = http.Request(method, uri);
      if (sdkHeaders) {
        request.headers['X-Tododdle-Key'] = key;
        request.headers['X-Tododdle-Sdk'] = tododdleSupportSdkHeader;
        if (appId != null) request.headers['X-Tododdle-App-Id'] = appId!;
        request.headers['Accept'] = 'application/json';
      }
      if (json != null) request.headers['Content-Type'] = 'application/json';
      request.headers.addAll(headers);
      if (body != null) request.bodyBytes = body;

      TododdleSupportException error;
      Duration? retryAfter;
      try {
        final streamed = await _http.send(request).timeout(timeout);
        final response = await http.Response.fromStream(
          streamed,
        ).timeout(timeout);
        if (ok(response.statusCode)) return response;
        retryAfter = parseRetryAfter(response.headers['retry-after']);
        error = _errorFrom(response, retryAfter, failureCode);
      } on http.ClientException catch (e) {
        error = TododdleSupportException(
          code: TododdleErrorCodes.networkError,
          message: 'The request failed: ${e.message}',
        );
      } on TimeoutException {
        error = const TododdleSupportException(
          code: TododdleErrorCodes.networkError,
          message: 'The request timed out.',
        );
      }

      final retryable =
          error.code == TododdleErrorCodes.networkError ||
          retryPolicy.retryStatuses.contains(error.httpStatus);
      if (!retryable || attempt >= retryPolicy.maxAttempts) throw error;
      if (retryAfter != null && retryAfter > retryPolicy.maxRetryAfter) {
        throw error;
      }
      await _delay(retryAfter ?? retryPolicy.backoffFor(attempt - 1));
    }
  }

  TododdleSupportException _errorFrom(
    http.Response response,
    Duration? retryAfter,
    String? failureCode,
  ) {
    final status = response.statusCode;
    if (failureCode == null) {
      try {
        final error = asMap(
          asMap(jsonDecode(response.body), 'body')['error'],
          'error',
        );
        return TododdleSupportException(
          code: asString(error['code'], 'error.code'),
          message: asStringOrNull(error['message'], 'error.message') ?? '',
          httpStatus: status,
          fields: error['fields'] == null
              ? const {}
              : asStringMap(error['fields'], 'error.fields'),
          requestId: asStringOrNull(error['requestId'], 'error.requestId'),
          retryAfter: retryAfter,
        );
      } on Object {
        // No readable error body; fall back to the status.
      }
    }
    return TododdleSupportException(
      code: failureCode ?? TododdleErrorCodes.httpError,
      message: 'The server answered with HTTP $status.',
      httpStatus: status,
      retryAfter: retryAfter,
    );
  }
}

class _Upload {
  const _Upload(this.uploadUrl, this.headers);

  final String uploadUrl;
  final Map<String, String> headers;
}

class _ReportResponse {
  const _ReportResponse({
    required this.reportId,
    required this.status,
    this.submitToken,
    this.uploads = const [],
  });

  factory _ReportResponse.parse(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw TododdleSupportException.invalidResponse('report is not JSON');
    }
    final json = asMap(decoded, 'report');
    return _ReportResponse(
      reportId: asString(json['reportId'], 'reportId'),
      status: asString(json['status'], 'status'),
      submitToken: asStringOrNull(json['submitToken'], 'submitToken'),
      uploads: json['uploads'] == null
          ? const []
          : asList(json['uploads'], 'uploads').map((u) {
              final m = asMap(u, 'uploads[]');
              return _Upload(
                asString(m['uploadUrl'], 'uploadUrl'),
                m['headers'] == null
                    ? const {}
                    : asStringMap(m['headers'], 'headers'),
              );
            }).toList(),
    );
  }

  final String reportId;
  final String status;
  final String? submitToken;
  final List<_Upload> uploads;
}
