# TododdleSupport for Swift

In-app issue reporting into a ToDoddle Support project, for iOS 16 and later. Reports go one way:
each one becomes a Support ticket, and the reporter gets no email or replies.

- No third-party dependencies. Swift 6 strict concurrency.
- A headless client (`TododdleSupport`) and a SwiftUI form (`ReportSheet`).
- Nothing is collected automatically except the app version and build, OS name and version,
  device model and locale. Screenshots are attached only when the person taps "Add screenshot",
  and they see a preview they can remove.

## Install

Add the package with Swift Package Manager from `https://github.com/krffl/tododdle-support`, using
a version tag (for example "Up to Next Major Version" from `1.0.0`).

In Xcode: File > Add Package Dependencies, paste the URL, and add the `TododdleSupport` library.

In `Package.swift`:

```swift
.package(url: "https://github.com/krffl/tododdle-support", from: "1.0.0"),
// …
.target(name: "MyApp", dependencies: [
    .product(name: "TododdleSupport", package: "tododdle-support"),
]),
```

You need the project's public SDK key (`tdsk_pub_…`) from ToDoddle. It can only read the report
form and send reports, so it is safe to ship in the app. A test key (`tdsk_test_…`) works the same
way and marks its tickets as test reports.

## The report sheet

```swift
import SwiftUI
import TododdleSupport

let support = TododdleSupport(configuration: .init(key: "tdsk_pub_…"))

struct SettingsView: View {
    @State private var showReport = false

    var body: some View {
        Button("Report a problem") { showReport = true }
            .tododdleReportSheet(isPresented: $showReport, client: support)
    }
}
```

Or set the client once with `.tododdleSupport(support)` high in the view tree and leave out
`client:`. You can also present `ReportSheet(client:)` yourself in any sheet or navigation stack.

The sheet loads the form from ToDoddle: the report types, title, description, custom fields,
wording, thank-you message and theme colours. It checks the fields before sending and shows the
server's field messages next to each field. It supports Dynamic Type and VoiceOver.

Optional parameters:

| Parameter | What it does |
|---|---|
| `offeredScreenshot` | An image your app captured before it showed the sheet. It is attached only if the person taps "Add screenshot". Make it with `ScreenshotAttachment.make(from: pngData)`. |
| `allowsPhotoPicker` | Lets the person choose an image with the system photo picker. On by default. Needs no permission prompt. |
| `context` | App context such as `ReportContext(screen: "Checkout", extra: ["plan": "pro"])`. Never put URL query strings or personal data here. |
| `reporter` | Optional, unverified details: `Reporter(name:email:customerReference:)`. ToDoddle never emails the reporter. |
| `strings` | The SDK's own wording (buttons, errors). Replace it to localise. |
| `onFinish` | Called with the `ReportReceipt`, or `nil` if the person cancelled. |

## Headless use

```swift
let support = TododdleSupport(configuration: .init(
    key: "tdsk_pub_…",
    offlineQueue: true            // optional; see below
))

let config = try await support.config()           // cached with ETag
let report = Report(
    type: .problem,
    title: "Favourites vanish",
    description: "They disappear after I reopen the app.",
    fields: ["area": "Home"],
    context: ReportContext(screen: "Favourites"),
    attachments: [ReportAttachment(fileName: "log.txt", contentType: "text/plain", data: logData)]
)

let problems = support.validate(report, against: config)   // [fieldKey: message]
do {
    let receipt = try await support.report(report, using: config)
    print(receipt.reportId ?? "queued")
} catch let error as TododdleSupportError {
    // error.code, error.httpStatus, error.message, error.fields
}
```

`report(_:using:)` checks the report against the config, declares the attachments, uploads each
file to its upload URL, then submits. It makes one idempotency key per report and reuses it on
every retry, so a retry never creates a second ticket.

### Configuration

| Option | Default | |
|---|---|---|
| `key` | | The public SDK key. |
| `baseURL` | `https://app.tododdle.com/api/support/sdk/v1` | |
| `appId` | `Bundle.main.bundleIdentifier` | Sent as `X-Tododdle-App-Id`. If the key lists allowed app IDs, others are refused. |
| `urlSession` | `.shared` | |
| `configCache` | `.memoryAndDisk` | `.memoryAndDisk` keeps the last good config in the app's caches folder, so the form opens offline. `.memory` keeps it for the client's lifetime only. |
| `offlineQueue` | `false` | See below. |
| `collectsDeviceContext` | `true` | Adds app version, build, OS, device model and locale. |

### Config caching

`config()` sends `If-None-Match` with the last `ETag` and uses the cached copy on `304`. While the
server's `Cache-Control: max-age` lasts, it makes no request. If the server cannot be reached, it
returns the last good config. `config(forceRefresh: true)` always asks the server.

### Retries

The SDK follows the shared retry policy in `contract/cases/cases.json`:

- It retries only network errors and HTTP 408, 429, 500, 502, 503 and 504.
- It waits for `Retry-After` when the server sends it, and otherwise for 1 s, then 2 s.
- It makes at most 3 attempts per request.
- It never retries 400, 401, 403, 404, 409, 410, 413 or 422.

A `Retry-After` longer than 60 seconds is not waited for inside the call. The error comes back
with `retryAfter` set (or the report goes to the offline queue).

### Errors

Every failure is a `TododdleSupportError` with `code`, `httpStatus`, `message`, `fields`,
`requestId` and `retryAfter`. Server codes are kept as sent, including codes added after this SDK
was released, so handle unknown codes by `httpStatus`. The SDK adds `NETWORK_ERROR`,
`INVALID_RESPONSE` and `HTTP_ERROR` (an error status with no readable body). Local validation
failures use `INVALID_FIELDS` with no `httpStatus`, and nothing is sent.

`message` is plain English for logs. Show your own wording to people.

### Offline queue

With `offlineQueue: true`, a report that fails with a network error, or a retryable status after
all attempts, is saved in the app's Application Support folder (excluded from backups) and
`report` returns a receipt with status `.queued`. Send the queue with `flushQueue()`, for example
when the app becomes active:

```swift
.onChange(of: scenePhase) { phase in
    if phase == .active { Task { await support.flushQueue() } }
}
```

Queued reports keep their idempotency key, so a report that did reach the server is never sent
twice. The queue holds up to 10 reports and drops reports older than 7 days. Reports the server
refuses for good are removed and listed in the flush result's `dropped`.

## Example app

`examples/ios/ExampleApp.swift` is a one-file SwiftUI app. See `examples/ios/README.md`.

## Development

```sh
swift test                            # from the repository root
scripts/sync-swift-cases.sh           # after contract/cases/cases.json changes
```

The conformance tests replay every case in `contract/cases/cases.json` through a `URLProtocol`
stub. The test resources hold a copy of that file; a test fails if the copy differs, and
`scripts/sync-swift-cases.sh` updates it.

### Releases

The SDK version is the root `VERSION` file. `TododdleSupport.sdkVersion` (sent as
`X-Tododdle-Sdk: swift/<version>`) is generated from it. To release:

1. Set `VERSION` (for example `1.0.0`).
2. Run `scripts/sync-swift-version.sh`. A test fails if `SDKVersion.swift` and `VERSION` differ.
3. Commit, then tag the commit with the version (for example `1.0.0`). Swift Package Manager
   installs from the tag.
