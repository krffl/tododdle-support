// Example app for the ToDoddle Support Flutter SDK.
//
// Run it with your project's public SDK key:
//
//   flutter create --platforms=android,ios .   # once, to add platform folders
//   flutter run --dart-define=TODODDLE_KEY=tdsk_test_...
import 'package:flutter/material.dart';
import 'package:tododdle_support/tododdle_support.dart';

const _key = String.fromEnvironment('TODODDLE_KEY');
const _baseUrl = String.fromEnvironment(
  'TODODDLE_BASE_URL',
  defaultValue: TododdleSupport.defaultBaseUrl,
);

/// Wraps the whole app so the sheet can capture it when the person taps
/// "Add screenshot". Nothing is captured before that tap.
final _screenshotKey = GlobalKey();

final _support = TododdleSupport(
  key: _key,
  baseUrl: _baseUrl,
  appId: 'com.tododdle.support.example',
  // Keep reports that cannot be sent and send them later.
  queueStore: MemoryReportQueueStore(),
);

void main() {
  runApp(RepaintBoundary(key: _screenshotKey, child: const ExampleApp()));
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ToDoddle Support example',
      theme: ThemeData(colorSchemeSeed: Colors.teal),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _status = '';

  @override
  void initState() {
    super.initState();
    // Send anything queued while offline.
    _support.flushQueue();
  }

  Future<void> _openSheet() async {
    final receipt = await showTododdleReportSheet(
      context,
      client: _support,
      screenshotBoundaryKey: _screenshotKey,
      reportContext: const ReportContext(screen: 'Home'),
    );
    if (!mounted || receipt == null) return;
    setState(() {
      _status = receipt.queued
          ? 'Report queued until you are online.'
          : 'Report sent: ${receipt.reportId}';
    });
  }

  Future<void> _sendHeadless() async {
    try {
      final receipt = await _support.report(
        Report(
          type: ReportType.feedback,
          description: 'Sent from the example app without the sheet.',
          context: const ReportContext(screen: 'Home'),
        ),
      );
      setState(() => _status = 'Headless report: ${receipt.reportId}');
    } on TododdleSupportException catch (e) {
      setState(() => _status = 'Not sent: ${e.code}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ToDoddle Support')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_key.isEmpty)
                const Text(
                  'Run with --dart-define=TODODDLE_KEY=tdsk_test_... to send '
                  'real reports.',
                  textAlign: TextAlign.center,
                ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _openSheet,
                child: const Text('Report a problem'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _sendHeadless,
                child: const Text('Send a headless report'),
              ),
              const SizedBox(height: 16),
              Text(_status, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
