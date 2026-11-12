# ToDoddle Support for Android (Kotlin)

One-way in-app issue reporting into a ToDoddle Support project. Each report becomes a Support
ticket. The person reporting gets no email and no replies.

| Artifact | What it is |
|---|---|
| `support` | Headless client: config, reports, attachments, retries. OkHttp, coroutines and kotlinx.serialization. |
| `support-compose` | Jetpack Compose `ReportSheet` (modal bottom sheet). Pulls in Compose Material 3. |
| `support-offline` | Optional offline queue with WorkManager. |

Requirements: minSdk 24, Java 17 toolchain.

## Install (JitPack)

Add JitPack to your repositories in `settings.gradle.kts`:

```kotlin
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven("https://jitpack.io")
    }
}
```

Then add the modules you need. `<tag>` is a Git tag of `krffl/tododdle-support`, for example `v1.0.0`.

```kotlin
dependencies {
    implementation("com.github.krffl.tododdle-support:support:<tag>")          // headless
    implementation("com.github.krffl.tododdle-support:support-compose:<tag>")  // sheet (includes support)
    implementation("com.github.krffl.tododdle-support:support-offline:<tag>")  // optional queue
}
```

`com.github.krffl:tododdle-support:<tag>` also works, but it pulls in every module, Compose and
WorkManager included. Prefer the module coordinates above.

## Headless use

```kotlin
val support = TododdleSupport(
    context,
    Configuration(key = "tdsk_pub_…"), // baseUrl defaults to https://app.tododdle.com/api/support/sdk/v1
)

// The form, wording and theme. Cached with its ETag in memory and in the app's cache folder,
// so it still loads offline.
val config = support.config()

val report = Report(
    type = ReportType.PROBLEM,
    title = "Favourites vanish",
    description = "Favourites vanish after reopening the app.",
    fields = mapOf("area" to "Home"),
    context = ReportContext(screen = "Favourites", extra = mapOf("plan" to "pro")),
    reporter = Reporter(customerReference = "user-42"), // optional and unverified
    attachments = listOf(Attachment("log.txt", "text/plain", bytes)), // only files the person chose
    formVersion = config.form.version,
)

try {
    val receipt = support.report(report)
    showThanks(receipt.reportId)
} catch (e: TododdleSupportException) {
    when {
        e.code == ErrorCode.INVALID_FIELDS -> showFieldErrors(e.fields)
        e.isRetryable -> offerRetry() // call support.report(report) again with the same Report
        else -> showError(e.code, e.httpStatus)
    }
}
```

What the client does:

- Sends `X-Tododdle-Key`, `X-Tododdle-Sdk: kotlin/<version>` and `X-Tododdle-App-Id` (your package
  name; override with `Configuration(appId = …)`).
- Checks the report before sending, against the contract limits and the cached form
  (`ReportValidator.validate(report, config)` gives you the same checks for your own UI).
- With attachments: declares them, uploads the raw bytes to each returned URL with exactly the
  returned headers (never the SDK key), then submits.
- Retries 408, 429, 500, 502, 503, 504 and network errors at most 3 times in total. It waits for
  `Retry-After` when the server sends it (up to `maxRetryAfterSeconds`, 60 by default), otherwise
  1 s then 2 s. Every attempt reuses `report.idempotencyKey`, so a retry never creates a second
  ticket. Other errors are not retried.
- Adds app version, build number, Android version, device model and locale to `context`. Values
  you set win. Turn it off with `Configuration(collectContext = false)`. Nothing else is collected.

`TododdleSupportException` has `code`, `httpStatus`, `message`, `fields`, `requestId` and
`retryAfterSeconds`. Unknown server codes are passed through; judge them by `httpStatus`. SDK codes:
`NETWORK_ERROR`, `SERVER_ERROR`, `INVALID_RESPONSE`, `UPLOAD_FAILED`, and `INVALID_FIELDS` with no
`httpStatus` for client-side validation.

`Attachments.fromUri(context, uri)` reads a file the person picked into an `Attachment`.

## Report sheet (Compose)

```kotlin
var showReport by remember { mutableStateOf(false) }

if (showReport) {
    ReportSheet(
        support = support,
        onDismissRequest = { showReport = false },
        context = ReportContext(screen = "Settings"),
        // Optional: a screenshot your app captured after the person asked for it.
        screenshot = capturedBitmap?.let { ScreenshotSource.FromBitmap(it) },
        onReported = { receipt -> Log.i("Support", "Sent ${receipt.reportId}") },
    )
}
```

- Renders the config: report types, title, description and up to 20 custom fields
  (short text, long text, select), with the project's accent colour and corner style.
- Screenshots: pass a `Bitmap` or `Uri` with `screenshot`, or let the person pick one with the
  system photo picker ("Add screenshot", turn off with `allowScreenshotPicker = false`). The
  sheet shows a preview with a remove button. It never captures the screen by itself. Images that
  are too large or in another format (HEIC, for example) are re-encoded to fit the form's rules.
- Labels, required markers, errors and the preview have accessible descriptions. Change the sheet's
  own wording with `strings = ReportSheetStrings(…)`.
- The idempotency key is reused while the content is unchanged, so "Send" after a failure never
  creates a duplicate.

A full activity is in [`examples/android/MainActivity.kt`](examples/android/MainActivity.kt).

### Security rules

- The key must start with `tdsk_pub_` or `tdsk_test_`. Any other key throws
  `IllegalArgumentException` when you create the `Configuration`.
- `baseUrl` must be HTTPS. Plain HTTP is allowed only for a loopback host (`127.0.0.1`, `::1`,
  `localhost`), for local test servers. To reach a dev server from the emulator, use
  `adb reverse` and `http://127.0.0.1:<port>`.
- The SDK never follows redirects, also with your own `httpClient` (it uses a copy with redirects
  turned off). A redirect fails the call with `INVALID_RESPONSE`.
- Upload URLs from the server must be HTTPS (plain HTTP only for a loopback host), or the call
  fails with `INVALID_RESPONSE`. The SDK never sends `Host`, `Authorization`, `Cookie`, `Proxy-*`,
  `Connection`, `Transfer-Encoding` or `Content-Length` from the server's upload headers.
- `ReportContext.screen` is sent without its query string or fragment (everything from the first
  `?` or `#` is dropped).

## Offline queue (optional)

```kotlin
try {
    support.report(report)
} catch (e: TododdleSupportException) {
    if (e.isRetryable) SupportQueue.enqueue(context, support.configuration, report)
}
```

`SupportQueue.enqueue` saves the report (and its attachments) in the app's no-backup folder and
sends it with WorkManager when the device is online, with the same idempotency key on every
attempt. Refused reports are dropped. The work is tagged `SupportQueue.WORK_TAG`; its output has
`reportId` or `errorCode`.

The queue is capped like the other SDKs: at most 10 reports (`SupportQueue.MAX_QUEUED_REPORTS`),
none older than 7 days (`MAX_QUEUED_AGE_MILLIS`), and at most 20 MB of report files in total
(`MAX_QUEUED_BYTES`). When a new report breaks a cap, the oldest reports are dropped first. The
newest report is always kept. Expired reports are dropped instead of sent.

The worker keeps the configuration's `key`, `baseUrl`, `appId`, `collectContext`,
`cacheConfigOnDisk` and `maxRetryAfterSeconds`. It cannot keep your `httpClient`, so if you use
your own client (for example for certificate pinning or a proxy), give the queue a factory in
`Application.onCreate`:

```kotlin
SupportQueue.httpClientFactory = { myOkHttpClient }
```

## Development

The Gradle build lives in this folder. Run from `kotlin/`:

```sh
./gradlew test            # unit tests and the shared conformance cases
./gradlew assembleRelease # build the AARs
```

`support/src/test/.../ConformanceTest.kt` replays every case in `../contract/cases/cases.json`
against a MockWebServer and checks each `request.must` rule and `expect` block. Retry waits are
recorded, not slept, so the suite is fast.

The SDK version comes from `/VERSION`. JitPack builds tags with `/jitpack.yml`, which runs
`./gradlew publishToMavenLocal` in this folder. Keep `/VERSION` equal to the tag (without the `v`)
when you release, because the `X-Tododdle-Sdk` header uses `/VERSION`.
