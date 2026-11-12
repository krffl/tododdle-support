import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tododdle_support/tododdle_support.dart';

final Map<String, Object?> _shared =
    (jsonDecode(File('../contract/cases/cases.json').readAsStringSync()) as Map)
        .cast<String, Object?>();
final String _configJson = jsonEncode(_shared['config']);
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

class _Server {
  final requests = <http.Request>[];

  TododdleSupport client() => TododdleSupport(
    key: 'tdsk_pub_TESTKEY0000000000000000000000000',
    baseUrl: 'https://mock.tododdle.test',
    contextProvider: null,
    delay: (_) async {},
    httpClient: MockClient((request) async {
      requests.add(request);
      if (request.url.path == '/config') {
        return http.Response(_configJson, 200, headers: {'etag': '"cfg-3"'});
      }
      if (request.url.path == '/reports') {
        final body = jsonDecode(request.body) as Map;
        if (body['attachments'] != null) {
          return http.Response(
            jsonEncode({
              'reportId': 'rpt_AAAAAAAAAAAAAAAA0002',
              'status': 'awaiting_uploads',
              'submitToken': 'st_0123456789abcdef0123456789abcdef',
              'expiresAt': '2099-01-01T00:00:00Z',
              'uploads': [
                {
                  'uploadUrl': 'https://mock.tododdle.test/upload/1',
                  'headers': {'Content-Type': 'image/png'},
                  'expiresAt': '2099-01-01T00:00:00Z',
                },
              ],
            }),
            201,
          );
        }
        return http.Response(
          jsonEncode({
            'reportId': 'rpt_AAAAAAAAAAAAAAAA0001',
            'status': 'received',
          }),
          201,
        );
      }
      if (request.url.path == '/upload/1') return http.Response('', 200);
      if (request.url.path.endsWith('/submit')) {
        return http.Response(
          jsonEncode({
            'reportId': 'rpt_AAAAAAAAAAAAAAAA0002',
            'status': 'received',
          }),
          200,
        );
      }
      return http.Response('', 404);
    }),
  );

  List<Map<String, Object?>> get reportBodies => requests
      .where((r) => r.url.path == '/reports')
      .map((r) => (jsonDecode(r.body) as Map).cast<String, Object?>())
      .toList();
}

Future<void> _pump(WidgetTester tester, Widget sheet) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: sheet)));
  await tester.pumpAndSettle();
}

Future<void> _chooseArea(WidgetTester tester, String option) async {
  await tester.tap(find.byKey(const ValueKey('tododdle-field-area')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const ValueKey('tododdle-submit')));
  await tester.tap(find.byKey(const ValueKey('tododdle-submit')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the form from the config', (tester) async {
    final server = _Server();
    await _pump(tester, ReportSheet(client: server.client()));

    expect(server.requests.single.url.path, '/config');
    expect(find.text('Tell us what happened'), findsOneWidget);
    expect(
      find.text('Your report goes straight to the Mosslight team.'),
      findsOneWidget,
    );
    expect(find.text('Report a problem'), findsOneWidget);
    expect(find.text('Summary'), findsOneWidget);
    expect(find.text('What happened? *'), findsOneWidget);
    expect(
      find.text('Tell us what you expected and what you saw.'),
      findsOneWidget,
    );
    expect(find.text('Where in the app? *'), findsOneWidget);
    expect(find.text('Steps to reproduce'), findsOneWidget);
    expect(find.text('Send report'), findsOneWidget);
    // No capture source and no screenshot: no screenshot control.
    expect(find.text('Add screenshot'), findsNothing);
  });

  testWidgets('applies the config theme', (tester) async {
    await _pump(tester, ReportSheet(client: _Server().client()));
    final theme = Theme.of(
      tester.element(find.byKey(const ValueKey('tododdle-submit'))),
    );
    expect(theme.colorScheme.primary, const Color(0xFF2F6D4F));
    expect(theme.colorScheme.onPrimary, const Color(0xFFFFFFFF));
    final background = theme.filledButtonTheme.style?.backgroundColor?.resolve(
      <WidgetState>{},
    );
    expect(background, const Color(0xFF2F6D4F));
  });

  testWidgets('required fields block sending', (tester) async {
    final server = _Server();
    await _pump(tester, ReportSheet(client: server.client()));

    await _submit(tester);

    expect(find.text('This is required.'), findsOneWidget);
    expect(find.text('Choose an option.'), findsOneWidget);
    expect(server.reportBodies, isEmpty);
  });

  testWidgets('submits and shows the thank-you state', (tester) async {
    final server = _Server();
    ReportReceipt? submitted;
    ReportReceipt? closedWith;
    var closed = false;
    await _pump(
      tester,
      ReportSheet(
        client: server.client(),
        reportContext: const ReportContext(screen: 'Favourites'),
        onSubmitted: (r) => submitted = r,
        onClose: (r) {
          closed = true;
          closedWith = r;
        },
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('tododdle-description')),
      'Favourites vanish.',
    );
    await _chooseArea(tester, 'Settings');
    await _submit(tester);

    final body = server.reportBodies.single;
    expect(body['type'], 'problem');
    expect(body['formVersion'], 3);
    expect(body['description'], 'Favourites vanish.');
    expect(body['fields'], {'area': 'Settings'});
    expect(body['context'], {'screen': 'Favourites'});
    expect(body.containsKey('attachments'), isFalse);

    expect(find.text('Thanks!'), findsOneWidget);
    expect(find.text('We read every report.'), findsOneWidget);
    expect(submitted?.reportId, 'rpt_AAAAAAAAAAAAAAAA0001');
    expect(find.text('Reference: rpt_AAAAAAAAAAAAAAAA0001'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tododdle-close')));
    expect(closed, isTrue);
    expect(closedWith?.reportId, 'rpt_AAAAAAAAAAAAAAAA0001');
  });

  testWidgets('shows the queued message and no reference when offline', (
    tester,
  ) async {
    final client = TododdleSupport(
      key: 'tdsk_pub_TESTKEY0000000000000000000000000',
      baseUrl: 'https://mock.tododdle.test',
      contextProvider: null,
      queueStore: MemoryReportQueueStore(),
      retryPolicy: const RetryPolicy(
        maxAttempts: 1,
        backoff: [],
        retryStatuses: {},
      ),
      httpClient: MockClient((request) async {
        if (request.url.path == '/config') {
          return http.Response(_configJson, 200);
        }
        throw http.ClientException('offline', request.url);
      }),
    );
    await _pump(tester, ReportSheet(client: client));
    await tester.enterText(
      find.byKey(const ValueKey('tododdle-description')),
      'Favourites vanish.',
    );
    await _chooseArea(tester, 'Home');
    await _submit(tester);

    expect(find.text('Thanks!'), findsOneWidget);
    expect(
      find.text(
        'You are offline. Your report will be sent when you are back online.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('tododdle-reference')), findsNothing);
  });

  testWidgets('shows server field errors', (tester) async {
    final client = TododdleSupport(
      key: 'tdsk_pub_TESTKEY0000000000000000000000000',
      baseUrl: 'https://mock.tododdle.test',
      contextProvider: null,
      httpClient: MockClient((request) async {
        if (request.url.path == '/config') {
          return http.Response(_configJson, 200);
        }
        return http.Response(
          jsonEncode({
            'error': {
              'code': 'INVALID_FIELDS',
              'message': 'Check the highlighted fields.',
              'fields': {'steps': 'Tell us the steps.'},
            },
          }),
          422,
        );
      }),
    );
    await _pump(tester, ReportSheet(client: client));
    await tester.enterText(
      find.byKey(const ValueKey('tododdle-description')),
      'x',
    );
    await _chooseArea(tester, 'Home');
    await _submit(tester);

    expect(find.text('Tell us the steps.'), findsOneWidget);
    expect(find.text('Thanks!'), findsNothing);
  });

  testWidgets('captures a screenshot only on tap, previews and removes it', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final server = _Server();
    var captures = 0;
    await _pump(
      tester,
      ReportSheet(
        client: server.client(),
        captureScreenshot: () async {
          captures++;
          return _png;
        },
      ),
    );

    expect(captures, 0);
    expect(
      find.byKey(const ValueKey('tododdle-screenshot-preview')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('tododdle-add-screenshot')));
    await tester.pumpAndSettle();
    expect(captures, 1);
    expect(
      find.byKey(const ValueKey('tododdle-screenshot-preview')),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Screenshot preview'), findsOneWidget);
    expect(find.text('Remove screenshot'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tododdle-remove-screenshot')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('tododdle-screenshot-preview')),
      findsNothing,
    );
    expect(find.text('Add screenshot'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('sends a screenshot the host passed in', (tester) async {
    final server = _Server();
    await _pump(tester, ReportSheet(client: server.client(), screenshot: _png));
    expect(
      find.byKey(const ValueKey('tododdle-screenshot-preview')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('tododdle-description')),
      'With a picture.',
    );
    await _chooseArea(tester, 'Home');
    await _submit(tester);

    final body = server.reportBodies.single;
    expect(body['attachments'], [
      {
        'fileName': 'screenshot.png',
        'contentType': 'image/png',
        'size': _png.length,
      },
    ]);
    final upload = server.requests.firstWhere((r) => r.method == 'PUT');
    expect(upload.bodyBytes, _png);
    expect(find.text('Thanks!'), findsOneWidget);
  });

  testWidgets('required fields have spoken labels', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, ReportSheet(client: _Server().client()));
    expect(
      find.bySemanticsLabel(RegExp(r'What happened\?, required')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'Where in the app\?, required')),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel(RegExp(r'^Summary')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'Summary, required')), findsNothing);
    handle.dispose();
  });

  testWidgets('showTododdleReportSheet returns the receipt', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = _Server();
    ReportReceipt? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showTododdleReportSheet(
                  context,
                  client: server.client(),
                );
              },
              child: const Text('Report'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Report'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('tododdle-description')),
      'x',
    );
    await _chooseArea(tester, 'Other');
    await _submit(tester);
    await tester.tap(find.byKey(const ValueKey('tododdle-close')));
    await tester.pumpAndSettle();
    expect(result?.reportId, 'rpt_AAAAAAAAAAAAAAAA0001');
    expect(find.text('Thanks!'), findsNothing);
  });
}
