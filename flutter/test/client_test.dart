import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tododdle_support/tododdle_support.dart';

const _base = 'https://mock.tododdle.test';

final Map<String, Object?> _shared =
    (jsonDecode(File('../contract/cases/cases.json').readAsStringSync()) as Map)
        .cast<String, Object?>();
final String _configJson = jsonEncode(_shared['config']);

typedef Handler = Future<http.Response> Function(http.Request request);

class _Harness {
  _Harness(List<Handler> handlers) : _handlers = List.of(handlers);

  final List<Handler> _handlers;
  final requests = <http.Request>[];
  final delays = <Duration>[];

  TododdleSupport client({
    ConfigStore? configStore,
    ReportQueueStore? queueStore,
    ContextProvider? contextProvider,
  }) => TododdleSupport(
    key: 'tdsk_pub_TESTKEY0000000000000000000000000',
    baseUrl: _base,
    appId: 'com.example.app',
    httpClient: MockClient((request) {
      requests.add(request);
      if (_handlers.isEmpty) {
        fail('unexpected ${request.method} ${request.url}');
      }
      return _handlers.removeAt(0)(request);
    }),
    configStore: configStore,
    queueStore: queueStore,
    contextProvider: contextProvider,
    delay: (d) async => delays.add(d),
  );

  void expectAllUsed() => expect(_handlers, isEmpty);
}

Handler _respond(int status, [Object? body, Map<String, String>? headers]) =>
    (_) async => http.Response(
      body == null ? '' : (body is String ? body : jsonEncode(body)),
      status,
      headers: headers ?? const {},
    );

Handler _networkError() =>
    (request) async => throw http.ClientException('offline', request.url);

Handler get _received => _respond(201, {
  'reportId': 'rpt_AAAAAAAAAAAAAAAA0001',
  'status': 'received',
});

Report _report({String? description = 'It broke.', int? formVersion = 3}) =>
    Report(
      type: ReportType.problem,
      formVersion: formVersion,
      description: description,
      fields: const {'area': 'Home'},
    );

void main() {
  group('version', () {
    test('pubspec, VERSION and the SDK constant match', () {
      final repoVersion = File('../VERSION').readAsStringSync().trim();
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final match = RegExp(
        r'^version:\s*(\S+)\s*$',
        multiLine: true,
      ).firstMatch(pubspec);
      expect(match?.group(1), repoVersion);
      expect(tododdleSupportSdkVersion, repoVersion);
      expect(tododdleSupportSdkHeader, 'flutter/$repoVersion');
    });
  });

  group('headers', () {
    test('sends the key, SDK and app ID headers', () async {
      final h = _Harness([_respond(200, _configJson)]);
      await h.client().config();
      final headers = h.requests.single.headers;
      expect(headers['X-Tododdle-Key'], startsWith('tdsk_pub_'));
      expect(headers['X-Tododdle-Sdk'], 'flutter/$tododdleSupportSdkVersion');
      expect(headers['X-Tododdle-App-Id'], 'com.example.app');
    });

    test('uploads send only the returned headers', () async {
      final h = _Harness([
        _respond(201, {
          'reportId': 'rpt_AAAAAAAAAAAAAAAA0002',
          'status': 'awaiting_uploads',
          'submitToken': 'st_0123456789abcdef0123456789abcdef',
          'expiresAt': '2099-01-01T00:00:00Z',
          'uploads': [
            {
              'uploadUrl': 'https://uploads.test/u/1?sig=abc',
              'headers': {'Content-Type': 'image/png', 'x-amz-meta-a': 'b'},
              'expiresAt': '2099-01-01T00:00:00Z',
            },
          ],
        }),
        _respond(200),
        _respond(200, {
          'reportId': 'rpt_AAAAAAAAAAAAAAAA0002',
          'status': 'received',
        }),
      ]);
      final receipt = await h.client().report(
        Report(
          type: ReportType.problem,
          formVersion: 3,
          description: 'x',
          attachments: [
            ReportAttachment(
              fileName: 'a.png',
              contentType: 'image/png',
              bytes: Uint8List.fromList([1, 2, 3]),
            ),
          ],
        ),
      );
      expect(receipt.reportId, 'rpt_AAAAAAAAAAAAAAAA0002');
      final upload = h.requests[1];
      expect(upload.method, 'PUT');
      expect(upload.url.toString(), 'https://uploads.test/u/1?sig=abc');
      expect(upload.headers.keys.map((k) => k.toLowerCase()).toSet(), {
        'content-type',
        'x-amz-meta-a',
      });
      expect(upload.bodyBytes, [1, 2, 3]);
    });
  });

  group('retry policy', () {
    test('stops after 3 attempts with 1 s and 2 s back-off', () async {
      final h = _Harness([_respond(503), _respond(502), _respond(500)]);
      final error = await h
          .client()
          .report(_report())
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<TododdleSupportException>());
      final e = error! as TododdleSupportException;
      expect(e.code, TododdleErrorCodes.httpError);
      expect(e.httpStatus, 500);
      expect(h.requests, hasLength(3));
      expect(h.delays, [
        const Duration(seconds: 1),
        const Duration(seconds: 2),
      ]);
      final keys = h.requests
          .map((r) => (jsonDecode(r.body) as Map)['idempotencyKey'])
          .toSet();
      expect(keys, hasLength(1));
    });

    test('retries network errors and 408', () async {
      final h = _Harness([_networkError(), _respond(408), _received]);
      final receipt = await h.client().report(_report());
      expect(receipt.reportId, 'rpt_AAAAAAAAAAAAAAAA0001');
      expect(h.requests, hasLength(3));
    });

    test('does not retry 501, which is not in retryStatuses', () async {
      final h = _Harness([_respond(501)]);
      await expectLater(
        h.client().report(_report()),
        throwsA(isA<TododdleSupportException>()),
      );
      expect(h.requests, hasLength(1));
    });

    for (final status in [400, 401, 403, 404, 409, 410, 413, 422]) {
      test('never retries $status', () async {
        final h = _Harness([
          _respond(status, {
            'error': {'code': 'X', 'message': 'no'},
          }),
        ]);
        await expectLater(
          h.client().report(_report()),
          throwsA(
            isA<TododdleSupportException>().having(
              (e) => e.httpStatus,
              'httpStatus',
              status,
            ),
          ),
        );
        expect(h.requests, hasLength(1));
      });
    }

    test('honours Retry-After instead of the back-off', () async {
      final h = _Harness([
        _respond(429, null, {'retry-after': '3'}),
        _received,
      ]);
      await h.client().report(_report());
      expect(h.delays, [const Duration(seconds: 3)]);
    });

    test('gives up when Retry-After is over maxRetryAfter', () async {
      final h = _Harness([
        _respond(
          429,
          {
            'error': {'code': 'RATE_LIMITED', 'message': 'Slow down.'},
          },
          {'retry-after': '3600'},
        ),
      ]);
      await expectLater(
        h.client().report(_report()),
        throwsA(
          isA<TododdleSupportException>()
              .having((e) => e.code, 'code', 'RATE_LIMITED')
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(hours: 1),
              ),
        ),
      );
      expect(h.requests, hasLength(1));
      expect(h.delays, isEmpty);
    });

    test('a resent Report object keeps its idempotency key', () async {
      final h = _Harness([_respond(400), _received]);
      final client = h.client();
      final report = _report();
      await expectLater(client.report(report), throwsA(anything));
      await client.report(report);
      expect(
        (jsonDecode(h.requests[0].body) as Map)['idempotencyKey'],
        (jsonDecode(h.requests[1].body) as Map)['idempotencyKey'],
      );
      expect(report.idempotencyKey, matches(RegExp(r'^[A-Za-z0-9_-]{16,64}$')));
    });
  });

  group('config cache', () {
    test('returns the last good config when offline', () async {
      final store = MemoryConfigStore();
      await _Harness([
        _respond(200, _configJson, {'etag': '"cfg-3"'}),
      ]).client(configStore: store).config();

      final h = _Harness([_networkError(), _networkError(), _networkError()]);
      final config = await h.client(configStore: store).config();
      expect(config.form.version, 3);
      expect(h.requests.first.headers['If-None-Match'], '"cfg-3"');
    });

    test('does not hide a revoked key behind the cache', () async {
      final store = MemoryConfigStore();
      await store.write(CachedConfig(etag: '"cfg-3"', body: _configJson));
      final h = _Harness([
        _respond(401, {
          'error': {'code': 'KEY_REVOKED', 'message': 'Revoked.'},
        }),
      ]);
      await expectLater(
        h.client(configStore: store).config(),
        throwsA(
          isA<TododdleSupportException>().having(
            (e) => e.code,
            'code',
            'KEY_REVOKED',
          ),
        ),
      );
    });

    test('rejects a malformed config with INVALID_RESPONSE', () async {
      final h = _Harness([_respond(200, '{"project": 1}')]);
      await expectLater(
        h.client().config(),
        throwsA(
          isA<TododdleSupportException>().having(
            (e) => e.code,
            'code',
            TododdleErrorCodes.invalidResponse,
          ),
        ),
      );
    });
  });

  group('validation', () {
    test('checks required fields against the known config', () async {
      final h = _Harness([_respond(200, _configJson)]);
      final client = h.client();
      await client.config();
      await expectLater(
        client.report(
          Report(type: ReportType.problem, formVersion: 3, description: ' '),
        ),
        throwsA(
          isA<TododdleSupportException>()
              .having((e) => e.code, 'code', 'INVALID_FIELDS')
              .having((e) => e.httpStatus, 'httpStatus', isNull)
              .having((e) => e.fields.keys, 'fields', {'description', 'area'}),
        ),
      );
      expect(h.requests, hasLength(1));
    });

    test('rejects a select value that is not an option', () {
      final config = SupportConfig.fromJson(
        (jsonDecode(_configJson) as Map).cast<String, Object?>(),
      );
      final errors = validateReport(
        Report(
          type: ReportType.problem,
          description: 'x',
          fields: const {'area': 'Kitchen'},
        ),
        config: config,
      );
      expect(errors.keys, ['area']);
    });

    test('rejects attachments of a type the form does not allow', () {
      final json = (jsonDecode(_configJson) as Map).cast<String, Object?>();
      final config = SupportConfig.fromJson(json);
      final errors = validateReport(
        Report(
          type: ReportType.problem,
          description: 'x',
          fields: const {'area': 'Home'},
          attachments: [
            ReportAttachment(
              fileName: 'a.zip',
              contentType: 'application/zip',
              bytes: Uint8List(1),
            ),
          ],
        ),
        config: config,
      );
      expect(errors.keys, ['attachments']);
    });

    test('fetches the config when the report has no form version', () async {
      final h = _Harness([_respond(200, _configJson), _received]);
      await h.client().report(_report(formVersion: null));
      expect((jsonDecode(h.requests[1].body) as Map)['formVersion'], 3);
    });
  });

  group('context', () {
    test('fills empty values from the provider; app values win', () async {
      final h = _Harness([_received]);
      await h
          .client(
            contextProvider: () async => const ReportContext(
              platform: 'flutter',
              appVersion: '9.9.9',
              osName: 'iOS',
            ),
          )
          .report(
            Report(
              type: ReportType.problem,
              formVersion: 3,
              description: 'x',
              context: const ReportContext(appVersion: '2.4.0', screen: 'Home'),
            ),
          );
      final body = jsonDecode(h.requests.single.body) as Map;
      expect(body['context'], {
        'platform': 'flutter',
        'appVersion': '2.4.0',
        'osName': 'iOS',
        'screen': 'Home',
      });
    });

    test('a failing provider does not stop the report', () async {
      final h = _Harness([_received]);
      await h
          .client(contextProvider: () async => throw StateError('no'))
          .report(_report());
      expect((jsonDecode(h.requests.single.body) as Map)['context'], isNull);
    });
  });

  group('offline queue', () {
    test('queues when offline and flushes with the same key', () async {
      final queue = MemoryReportQueueStore();
      final offline = _Harness([
        _networkError(),
        _networkError(),
        _networkError(),
      ]);
      final report = Report(
        type: ReportType.problem,
        formVersion: 3,
        description: 'x',
        attachments: [
          ReportAttachment(
            fileName: 'n.txt',
            contentType: 'text/plain',
            bytes: Uint8List.fromList(utf8.encode('hi')),
          ),
        ],
      );
      final receipt = await offline.client(queueStore: queue).report(report);
      expect(receipt.queued, isTrue);
      expect(receipt.reportId, isNull);

      final online = _Harness([
        _respond(201, {
          'reportId': 'rpt_AAAAAAAAAAAAAAAA0009',
          'status': 'awaiting_uploads',
          'submitToken': 'st_0123456789abcdef0123456789abcdef',
          'expiresAt': '2099-01-01T00:00:00Z',
          'uploads': [
            {
              'uploadUrl': '$_base/upload/9',
              'headers': {'Content-Type': 'text/plain'},
              'expiresAt': '2099-01-01T00:00:00Z',
            },
          ],
        }),
        _respond(200),
        _respond(200, {
          'reportId': 'rpt_AAAAAAAAAAAAAAAA0009',
          'status': 'received',
        }),
      ]);
      final client = online.client(queueStore: queue);
      expect(await client.queuedCount(), 1);
      final result = await client.flushQueue();
      expect(result.sent.single.reportId, 'rpt_AAAAAAAAAAAAAAAA0009');
      expect(result.remaining, 0);
      expect(await client.queuedCount(), 0);
      expect(
        (jsonDecode(online.requests.first.body) as Map)['idempotencyKey'],
        report.idempotencyKey,
      );
      expect(utf8.decode(online.requests[1].bodyBytes), 'hi');
    });

    test('drops reports that fail for good and keeps the rest', () async {
      final queue = MemoryReportQueueStore();
      final offline = _Harness(List.filled(6, _networkError()));
      final client = offline.client(queueStore: queue);
      await client.report(_report());
      await client.report(_report());
      expect(await client.queuedCount(), 2);

      final h = _Harness([
        _respond(422, {
          'error': {'code': 'INVALID_FIELDS', 'message': 'Bad.'},
        }),
        _networkError(),
        _networkError(),
        _networkError(),
      ]);
      final result = await h.client(queueStore: queue).flushQueue();
      expect(result.dropped.single.code, 'INVALID_FIELDS');
      expect(result.sent, isEmpty);
      expect(result.remaining, 1);
      expect((await queue.read()), hasLength(1));
    });

    test('does not queue errors that are not transient', () async {
      final queue = MemoryReportQueueStore();
      final h = _Harness([
        _respond(403, {
          'error': {'code': 'SUPPORT_UNAVAILABLE', 'message': 'Off.'},
        }),
      ]);
      await expectLater(
        h.client(queueStore: queue).report(_report()),
        throwsA(isA<TododdleSupportException>()),
      );
      expect(await queue.read(), isEmpty);
    });

    test('queueIfOffline: false throws instead', () async {
      final queue = MemoryReportQueueStore();
      final h = _Harness(List.filled(3, _networkError()));
      await expectLater(
        h.client(queueStore: queue).report(_report(), queueIfOffline: false),
        throwsA(
          isA<TododdleSupportException>().having(
            (e) => e.code,
            'code',
            TododdleErrorCodes.networkError,
          ),
        ),
      );
      expect(await queue.read(), isEmpty);
    });

    test('keeps at most 10 reports and drops the oldest', () async {
      final queue = MemoryReportQueueStore();
      final h = _Harness(List.filled(36, _networkError()));
      final client = h.client(queueStore: queue);
      final reports = List.generate(12, (_) => _report());
      for (final report in reports) {
        expect((await client.report(report)).queued, isTrue);
      }
      expect(TododdleSupport.maxQueuedReports, 10);
      final keys = (await queue.read())
          .map((e) => (jsonDecode(e) as Map)['idempotencyKey'])
          .toList();
      expect(keys, reports.skip(2).map((r) => r.idempotencyKey).toList());
    });

    test('drops reports older than 7 days', () async {
      String entry(Report report, Duration age) => jsonEncode({
        ...report.toQueueJson(),
        'queuedAt': DateTime.now().toUtc().subtract(age).toIso8601String(),
      });
      final old = _report();
      final fresh = _report();
      final queue = MemoryReportQueueStore();
      await queue.write([
        entry(old, const Duration(days: 8)),
        entry(fresh, const Duration(days: 1)),
      ]);
      final h = _Harness([_received]);
      final result = await h.client(queueStore: queue).flushQueue();
      expect(result.sent, hasLength(1));
      expect(result.remaining, 0);
      expect(
        (jsonDecode(h.requests.single.body) as Map)['idempotencyKey'],
        fresh.idempotencyKey,
      );
    });

    Report bigReport(int bytes, {int files = 1}) => Report(
      type: ReportType.problem,
      formVersion: 3,
      description: 'x',
      attachments: [
        for (var i = 0; i < files; i++)
          ReportAttachment(
            fileName: 'log$i.txt',
            contentType: 'text/plain',
            bytes: Uint8List(bytes),
          ),
      ],
    );

    test('keeps the queue under 20 MB by dropping the oldest', () async {
      final queue = MemoryReportQueueStore();
      final h = _Harness(List.filled(6, _networkError()));
      final client = h.client(queueStore: queue);
      final first = bigReport(9 * 1024 * 1024);
      final second = bigReport(9 * 1024 * 1024);
      await client.report(first);
      await client.report(second);
      final entries = await queue.read();
      expect(entries, hasLength(1));
      expect(
        (jsonDecode(entries.single) as Map)['idempotencyKey'],
        second.idempotencyKey,
      );
    });

    test('does not queue a report bigger than the byte budget', () async {
      final queue = MemoryReportQueueStore();
      final h = _Harness(List.filled(3, _networkError()));
      await expectLater(
        h
            .client(queueStore: queue)
            .report(bigReport(8 * 1024 * 1024, files: 2)),
        throwsA(
          isA<TododdleSupportException>().having(
            (e) => e.code,
            'code',
            TododdleErrorCodes.networkError,
          ),
        ),
      );
      expect(await queue.read(), isEmpty);
    });
  });

  group('transport security', () {
    Handler awaitingUpload(String url, Map<String, String> headers) =>
        _respond(201, {
          'reportId': 'rpt_AAAAAAAAAAAAAAAA0002',
          'status': 'awaiting_uploads',
          'submitToken': 'st_0123456789abcdef0123456789abcdef',
          'expiresAt': '2099-01-01T00:00:00Z',
          'uploads': [
            {
              'uploadUrl': url,
              'headers': headers,
              'expiresAt': '2099-01-01T00:00:00Z',
            },
          ],
        });

    Report withAttachment() => Report(
      type: ReportType.problem,
      formVersion: 3,
      description: 'x',
      attachments: [
        ReportAttachment(
          fileName: 'a.png',
          contentType: 'image/png',
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
      ],
    );

    for (final url in [
      'http://uploads.example.com/u/1',
      'ftp://uploads.example.com/u/1',
      'https:///no-host',
      'not a url',
    ]) {
      test('refuses the upload URL $url', () async {
        final h = _Harness([awaitingUpload(url, const {})]);
        await expectLater(
          h.client().report(withAttachment()),
          throwsA(
            isA<TododdleSupportException>().having(
              (e) => e.code,
              'code',
              TododdleErrorCodes.invalidResponse,
            ),
          ),
        );
        expect(h.requests, hasLength(1));
      });
    }

    for (final url in [
      'http://127.0.0.1:9000/u/1',
      'http://localhost/u/1',
      'http://[::1]:9000/u/1',
    ]) {
      test('allows a plain-HTTP loopback upload URL $url', () async {
        final h = _Harness([
          awaitingUpload(url, const {'Content-Type': 'image/png'}),
          _respond(200),
          _respond(200, {
            'reportId': 'rpt_AAAAAAAAAAAAAAAA0002',
            'status': 'received',
          }),
        ]);
        final receipt = await h.client().report(withAttachment());
        expect(receipt.reportId, 'rpt_AAAAAAAAAAAAAAAA0002');
        expect(h.requests[1].url, Uri.parse(url));
      });
    }

    test('drops unsafe headers from the upload instructions', () async {
      final h = _Harness([
        awaitingUpload('https://uploads.test/u/1', const {
          'Content-Type': 'image/png',
          'Host': 'evil.test',
          'Authorization': 'Bearer leaked',
          'cookie': 'session=1',
          'Proxy-Authorization': 'Basic x',
          'Connection': 'close',
          'Transfer-Encoding': 'chunked',
          'Content-Length': '99',
          'x-amz-meta-a': 'b',
        }),
        _respond(200),
        _respond(200, {
          'reportId': 'rpt_AAAAAAAAAAAAAAAA0002',
          'status': 'received',
        }),
      ]);
      await h.client().report(withAttachment());
      final upload = h.requests[1];
      expect(upload.headers.keys.map((k) => k.toLowerCase()).toSet(), {
        'content-type',
        'x-amz-meta-a',
      });
    });

    test('never follows redirects', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final paths = <String>[];
      server.listen((request) {
        paths.add(request.uri.path);
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set('Location', '/elsewhere')
          ..close();
      });
      addTearDown(() => server.close(force: true));
      final client = TododdleSupport(
        key: 'tdsk_test_TESTKEY0000000000000000000000000',
        baseUrl: 'http://127.0.0.1:${server.port}/api',
        contextProvider: null,
      );
      addTearDown(client.close);
      await expectLater(
        client.config(),
        throwsA(
          isA<TododdleSupportException>()
              .having((e) => e.code, 'code', TododdleErrorCodes.httpError)
              .having((e) => e.httpStatus, 'httpStatus', 302),
        ),
      );
      expect(paths, ['/api/config']);
    });

    test('marks every request as not following redirects', () async {
      final h = _Harness([_received]);
      await h.client().report(_report());
      expect(h.requests.single.followRedirects, isFalse);
    });

    for (final url in [
      'http://app.tododdle.com/api/support/sdk/v1',
      'ftp://app.tododdle.com',
      'https://',
      'not a url',
    ]) {
      test('refuses the base URL $url', () {
        expect(
          () => TododdleSupport(
            key: 'tdsk_pub_TESTKEY0000000000000000000000000',
            baseUrl: url,
          ),
          throwsArgumentError,
        );
      });
    }

    for (final url in [
      'https://app.tododdle.com/api/support/sdk/v1',
      'http://127.0.0.1:8080',
      'http://localhost:3000/api',
      'http://[::1]:8080',
    ]) {
      test('accepts the base URL $url', () {
        TododdleSupport(
          key: 'tdsk_pub_TESTKEY0000000000000000000000000',
          baseUrl: url,
        ).close();
      });
    }

    for (final key in ['tdsk_live_abc', 'sk_test_abc', '', 'TDSK_PUB_ABC']) {
      test('refuses the key "$key"', () {
        expect(() => TododdleSupport(key: key), throwsArgumentError);
      });
    }

    test('accepts tdsk_pub_ and tdsk_test_ keys', () {
      TododdleSupport(key: 'tdsk_pub_abc').close();
      TododdleSupport(key: 'tdsk_test_abc').close();
    });
  });

  group('screen', () {
    for (final entry in {
      'Favourites': 'Favourites',
      'Favourites?tab=recent': 'Favourites',
      'Favourites#token=abc': 'Favourites',
      'Favourites#a?b=c': 'Favourites',
      '/orders/42?x=1#y': '/orders/42',
    }.entries) {
      test('sends "${entry.value}" for "${entry.key}"', () {
        expect(
          ReportContext(screen: entry.key).toJson()['screen'],
          entry.value,
        );
      });
    }

    test('leaves screen out when only a query string is left', () {
      expect(ReportContext(screen: '?x=1').toJson(), isNot(contains('screen')));
    });
  });
}
