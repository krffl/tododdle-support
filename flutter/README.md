# tododdle_support (Flutter)

One-way in-app issue reporting into a ToDoddle Support project. Each report becomes a Support
ticket in the project's intake lane. The person reporting gets no email, sign-in link or replies.

- A headless client: `TododdleSupport.config()` and `TododdleSupport.report()`.
- A Material report sheet rendered from your project's form config: `showTododdleReportSheet()`.
- Pure Dart. No platform channels of its own. Dependencies: `http`, `package_info_plus` and
  `device_info_plus`.

The HTTP contract is [`contract/openapi.yaml`](../contract/openapi.yaml).

## Install

The package is distributed from this Git repository. Pin a release tag:

```yaml
dependencies:
  tododdle_support:
    git:
      url: https://github.com/krffl/tododdle-support
      path: flutter
      ref: v1.0.0
```

Requires Flutter 3.35 or later (Dart 3.9).

## Keys

Create a public SDK key in your ToDoddle Support project settings. A public key (`tdsk_pub_…`)
can only read the report form and send reports, so it is safe to ship inside an app. Test keys
(`tdsk_test_…`) work the same way and mark their tickets as test reports.

If the key lists allowed app IDs, pass your bundle ID or package name as `appId`.

## Report sheet

```dart
import 'package:tododdle_support/tododdle_support.dart';

final support = TododdleSupport(
  key: 'tdsk_pub_…',
  appId: 'com.example.app',
);

// Optional: wrap the app so the sheet can offer "Add screenshot".
final screenshotKey = GlobalKey();
void main() => runApp(RepaintBoundary(key: screenshotKey, child: const MyApp()));

// Later, from a button:
final receipt = await showTododdleReportSheet(
  context,
  client: support,
  screenshotBoundaryKey: screenshotKey,
  reportContext: const ReportContext(screen: 'Favourites'),
);
```

The sheet loads `GET /config`, shows the project's report types, title, description and custom
fields, and uses the project's accent colour and corner style. It checks required fields before
sending, shows field errors from the server, and ends with the project's thank-you wording and
the report reference (`Reference: rpt_…`). A queued report shows the offline message instead.
`showTododdleReportSheet` completes with the `ReportReceipt`, or null if the person closed the
sheet without sending.

Screenshots are never taken automatically. Either:

- pass `screenshot:` bytes you already have (the person sees a preview and can remove it), or
- pass `screenshotBoundaryKey:` (or your own `captureScreenshot:` callback). The sheet then shows
  an "Add screenshot" button and captures the `RepaintBoundary` only when the person taps it.

To embed the form in your own route instead of a bottom sheet, use the `ReportSheet` widget.
Translate the sheet's own text with `ReportSheetStrings`; the form labels and wording come from
the project config.

## Headless

```dart
final config = await support.config(); // cached with ETag

final receipt = await support.report(
  Report(
    type: ReportType.problem,
    formVersion: config.form.version, // optional; fetched when left out
    title: 'Favourites vanish',
    description: 'Favourites vanish after reopening the app.',
    fields: {'area': 'Home'},
    context: const ReportContext(screen: 'Favourites', extra: {'plan': 'pro'}),
    reporter: const Reporter(customerReference: 'user-42'),
    attachments: [
      ReportAttachment(fileName: 'log.txt', contentType: 'text/plain', bytes: bytes),
    ],
  ),
);
print(receipt.reportId);
```

With attachments, `report()` declares them, uploads each file with an HTTP `PUT` to its
`uploadUrl` with exactly the returned headers, and then submits the report with its
`submitToken`.

### Errors

Failures throw `TododdleSupportException` with:

- `code`: a contract code such as `INVALID_FIELDS`, `KEY_REVOKED` or `RATE_LIMITED`, or an SDK
  code (`NETWORK_ERROR`, `HTTP_ERROR`, `INVALID_RESPONSE`, `UPLOAD_FAILED`). New server codes are
  kept as sent; handle unknown codes by `httpStatus`.
- `httpStatus`: null when no response came back, or for client-side validation.
- `message`: plain English, safe to log. Show your own wording to people.
- `fields`: a message per field key for `INVALID_FIELDS` and `FIELDS_CHANGED`. Built-in keys are
  `type`, `title`, `description` and `attachments`.

`report()` checks the report before sending: the contract limits always, and the project's form
(required fields, select options, lengths, attachment rules) when the config for the report's
form version is known. Problems throw `INVALID_FIELDS` with a null `httpStatus`. You can also
call `validateReport(report, config: config)` yourself. Client-side checks can also use the keys
`fields`, `context` and `idempotencyKey`.

### Retries

Every call follows the shared retry policy: at most 3 attempts; retry only network errors and
HTTP 408, 429, 500, 502, 503 and 504; wait for `Retry-After` when the server sends it, otherwise
1 s and then 2 s. Each `Report` gets one idempotency key when it is created, and every retry
(and every later send of the same `Report` object) reuses it, so a report never creates two
tickets. A `Retry-After` longer than `RetryPolicy.maxRetryAfter` (60 s) ends the call instead of
blocking; the exception has `retryAfter`.

### Config cache

`config()` keeps the last good config in memory and sends `If-None-Match` with its `ETag`. Pass a
`ConfigStore` to keep it between launches. When the server cannot be reached, `config()` returns
the last good config so the sheet still opens offline. Errors such as a revoked key are never
hidden by the cache.

### Offline queue

Pass a `ReportQueueStore` to turn on the offline queue. When a report cannot reach the server
after its retries, `report()` stores it and returns a receipt with `queued: true` (pass
`queueIfOffline: false` to throw instead). Call `flushQueue()` when the app starts or comes back
online; it sends queued reports in order with their original idempotency keys. `MemoryReportQueueStore`
keeps entries in memory only. For a persistent queue, implement `ReportQueueStore` with app-private
storage: entries hold what the person typed and their attachments.

### Context

The SDK fills only these context values, and only when you have not set them: platform
(`flutter`), app version and build (`package_info_plus`), OS name and version and device model
(`device_info_plus`), and locale. Nothing else is collected: no device name, identifiers,
location, logs or URLs. Set `screen` and `extra` yourself, without query strings or personal
data. Pass `contextProvider: null` to turn automatic context off.

## Example

[`example/`](example/) is a small app with the sheet and a headless report. Add platform
folders once, then run it with a test key:

```sh
cd flutter/example
flutter create --platforms=android,ios .
flutter run --dart-define=TODODDLE_KEY=tdsk_test_…
```

## Development

```sh
cd flutter
flutter analyze
flutter test
```

`test/conformance_test.dart` runs the shared cases in `contract/cases/cases.json` against a mock
HTTP client. The version in `pubspec.yaml` and `lib/src/version.dart` must match the repository's
`VERSION` file; a test checks this.
