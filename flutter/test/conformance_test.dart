// Runs the shared conformance cases in ../contract/cases/cases.json against a
// MockClient that replays each case's exchanges in order.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tododdle_support/tododdle_support.dart';

const _baseUrl = 'https://mock.tododdle.test';

typedef Json = Map<String, Object?>;

Json _map(Object? value) => (value as Map).cast<String, Object?>();

final Json _cases = _map(
  jsonDecode(File('../contract/cases/cases.json').readAsStringSync()),
);

/// Replaces `$config` with the shared config and `{{baseUrl}}` with the mock
/// origin, anywhere in [value].
Object? _substitute(Object? value) {
  if (value == r'$config') return _cases['config'];
  if (value is String) return value.replaceAll('{{baseUrl}}', _baseUrl);
  if (value is List) return value.map(_substitute).toList();
  if (value is Map) {
    return value.map((k, v) => MapEntry(k as String, _substitute(v)));
  }
  return value;
}

/// Reads a dotted path such as `fields.area` or `attachments.0.fileName`.
Object? _at(Object? json, String path) {
  Object? current = json;
  for (final part in path.split('.')) {
    if (current is Map) {
      current = current[part];
    } else if (current is List) {
      final index = int.tryParse(part);
      if (index == null || index >= current.length) return null;
      current = current[index];
    } else {
      return null;
    }
  }
  return current;
}

class _Replay {
  _Replay(this.testCase);

  final Json testCase;
  final requests = <http.Request>[];
  final failures = <String>[];

  List<Json> get exchanges =>
      (testCase['exchanges'] as List).map(_map).toList();

  Future<http.Response> handle(http.Request request) async {
    final index = requests.length;
    requests.add(request);
    if (index >= exchanges.length) {
      failures.add('unexpected request ${request.method} ${request.url.path}');
      return http.Response('', 599);
    }
    final exchange = exchanges[index];
    final expected = _map(exchange['request']);
    final label = '#$index ${expected['method']} ${expected['path']}';
    if (request.method != expected['method'] ||
        request.url.path != expected['path']) {
      failures.add('$label: got ${request.method} ${request.url.path} instead');
    }
    final must = expected['must'];
    if (must != null) _checkMust(label, _map(must), request, index);

    final response = _map(exchange['response']);
    final body = _substitute(response['body']);
    final headers =
        (response['headers'] as Map?)?.cast<String, String>() ??
        const <String, String>{};
    return http.Response(
      body == null ? '' : jsonEncode(body),
      response['status']! as int,
      headers: {
        if (body != null) 'content-type': 'application/json',
        ...headers.map((k, v) => MapEntry(k.toLowerCase(), v)),
      },
    );
  }

  void _checkMust(String label, Json must, http.Request request, int index) {
    for (final entry in must.entries) {
      switch (entry.key) {
        case 'headers':
          final headers = entry.value;
          if (headers is List) {
            for (final name in headers.cast<String>()) {
              if (!_hasHeader(request, name)) {
                failures.add('$label: missing header $name');
              }
            }
          } else {
            for (final h in _map(headers).entries) {
              final actual = _header(request, h.key);
              if (actual != h.value) {
                failures.add(
                  '$label: header ${h.key} is $actual, not ${h.value}',
                );
              }
            }
          }
        case 'body':
          final json = jsonDecode(request.body);
          final body = entry.value;
          if (body is List) {
            for (final path in body.cast<String>()) {
              if (_at(json, path) == null) {
                failures.add('$label: body is missing $path');
              }
            }
          } else {
            for (final b in _map(body).entries) {
              final actual = _at(json, b.key);
              if (actual != b.value) {
                failures.add(
                  '$label: body ${b.key} is $actual, not ${b.value}',
                );
              }
            }
          }
        case 'rawBodyBase64':
          final expected = entry.value == r'$attachment'
              ? _map(testCase['attachment'])['bytesBase64']
              : entry.value;
          if (base64Encode(request.bodyBytes) != expected) {
            failures.add('$label: raw body does not match');
          }
        case 'sameIdempotencyKeyAsPrevious':
          final previous = jsonDecode(requests[index - 1].body);
          final current = jsonDecode(request.body);
          if (_at(current, 'idempotencyKey') !=
                  _at(previous, 'idempotencyKey') ||
              _at(current, 'idempotencyKey') == null) {
            failures.add('$label: idempotency key changed');
          }
        default:
          failures.add('$label: unknown must rule ${entry.key}');
      }
    }
  }

  static String? _header(http.Request request, String name) {
    for (final e in request.headers.entries) {
      if (e.key.toLowerCase() == name.toLowerCase()) return e.value;
    }
    return null;
  }

  static bool _hasHeader(http.Request request, String name) =>
      _header(request, name)?.isNotEmpty ?? false;
}

/// The shared report. A case's `screen`, when set, replaces
/// `report.context.screen`.
Report _sharedReport(
  Json testCase, {
  List<ReportAttachment> attachments = const [],
}) {
  final shared = _map(_cases['report']);
  final context = {..._map(shared['context']), 'screen': ?testCase['screen']};
  final config = _map(_map(_cases['config'])['form']);
  return Report(
    type: ReportType(shared['type']! as String),
    formVersion: config['version']! as int,
    description: shared['description'] as String?,
    fields: _map(shared['fields']).cast<String, String>(),
    context: ReportContext.fromJson(context),
    reporter: Reporter.fromJson(_map(shared['reporter'])),
    attachments: attachments,
  );
}

void main() {
  final cases = (_cases['cases'] as List).map(_map).toList();
  final policy = _map(_cases['retryPolicy']);

  test('the shared retry policy matches RetryPolicy.standard', () {
    expect(RetryPolicy.standard.maxAttempts, policy['maxAttempts']);
    expect(
      RetryPolicy.standard.backoff.map((d) => d.inSeconds).toList(),
      policy['backoffSeconds'],
    );
    expect(
      RetryPolicy.standard.retryStatuses,
      (policy['retryStatuses']! as List).cast<int>().toSet(),
    );
  });

  test('there are 14 conformance cases', () {
    expect(cases, hasLength(14));
  });

  for (final testCase in cases) {
    test('conformance: ${testCase['name']}', () async {
      final replay = _Replay(testCase);
      final delays = <Duration>[];
      final client = TododdleSupport(
        key: _cases['key']! as String,
        baseUrl: _baseUrl,
        appId: 'com.example.mosslight',
        httpClient: MockClient(replay.handle),
        contextProvider: null,
        delay: (d) async => delays.add(d),
      );

      Object? result;
      Object? error;
      try {
        switch (testCase['operation']) {
          case 'getConfig':
            result = await client.config();
          case 'getConfigTwice':
            await client.config();
            result = await client.config();
          case 'report':
            result = await client.report(_sharedReport(testCase));
          case 'reportWithAttachment':
            final a = _map(testCase['attachment']);
            result = await client.report(
              _sharedReport(
                testCase,
                attachments: [
                  ReportAttachment(
                    fileName: a['fileName']! as String,
                    contentType: a['contentType']! as String,
                    bytes: base64Decode(a['bytesBase64']! as String),
                  ),
                ],
              ),
            );
          default:
            fail('Unknown operation ${testCase['operation']}');
        }
      } on TododdleSupportException catch (e) {
        error = e;
      }

      expect(replay.failures, isEmpty, reason: 'request rules');

      final expectBlock = _map(testCase['expect']);
      for (final entry in expectBlock.entries) {
        final value = entry.value;
        switch (entry.key) {
          case 'ok':
            if (value == true) {
              expect(error, isNull, reason: 'expected success');
              expect(
                replay.requests,
                hasLength((testCase['exchanges'] as List).length),
                reason: 'every exchange is used',
              );
            } else {
              expect(error, isA<TododdleSupportException>());
            }
          case 'formVersion':
            expect((result! as SupportConfig).form.version, value);
          case 'fieldKeys':
            expect(
              (result! as SupportConfig).form.fields.map((f) => f.key),
              value,
            );
          case 'reportId':
            final receipt = result! as ReportReceipt;
            expect(receipt.reportId, value);
            expect(receipt.queued, isFalse);
          case 'errorCode':
            expect((error! as TododdleSupportException).code, value);
          case 'fieldErrors':
            expect((error! as TododdleSupportException).fields, value);
          case 'httpStatus':
            expect((error! as TododdleSupportException).httpStatus, value);
          case 'requests':
            expect(replay.requests, hasLength(value! as int));
          case 'minDelayMs':
            final total = delays.fold<int>(0, (t, d) => t + d.inMilliseconds);
            expect(total, greaterThanOrEqualTo(value! as int));
          default:
            fail('Unknown expect key ${entry.key}');
        }
      }
    });
  }
}
