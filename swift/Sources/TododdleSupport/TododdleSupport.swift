import Foundation

/// The headless ToDoddle Support client. Reports go one way into a ToDoddle Support project.
///
/// ```swift
/// let support = TododdleSupport(configuration: .init(key: "tdsk_pub_…"))
/// let config = try await support.config()
/// let receipt = try await support.report(Report(type: .problem, description: "It crashed."))
/// ```
///
/// The public key can only read the form and send reports, so it is safe to ship in an app.
public actor TododdleSupport {
    /// The production API.
    public static let defaultBaseURL = URL(string: "https://app.tododdle.com/api/support/sdk/v1")!

    public struct Configuration: Sendable {
        /// Where the config is cached between launches.
        public enum ConfigCache: Sendable, Equatable {
            /// Memory only. The dialog cannot open offline after a relaunch.
            case memory
            /// Memory and a small file in the app's caches directory, so the dialog opens offline.
            case memoryAndDisk
        }

        /// The project's public SDK key, `tdsk_pub_…` (or `tdsk_test_…`). Requests with any other
        /// key fail with ``TododdleSupportError/Code/invalidKey`` and nothing is sent.
        public var key: String
        /// Must be HTTPS. Plain HTTP is allowed only for a loopback host (`127.0.0.1`, `::1`,
        /// `localhost`), for local test servers. Requests with any other base URL fail with
        /// ``TododdleSupportError/Code/invalidConfiguration`` and nothing is sent.
        public var baseURL: URL
        /// Sent as `X-Tododdle-App-Id`. Defaults to the bundle identifier. `nil` sends no header.
        public var appId: String?
        public var urlSession: URLSession
        public var configCache: ConfigCache
        /// When on, a report that fails because the device is offline (or the server is briefly
        /// unavailable) is saved in the app's Application Support folder and returned as
        /// ``ReportReceipt/Status/queued``. Send it later with ``TododdleSupport/flushQueue()``.
        public var offlineQueue: Bool
        /// When on, the SDK adds the app version, build, OS, device model and locale to each report.
        public var collectsDeviceContext: Bool

        public init(
            key: String,
            baseURL: URL = TododdleSupport.defaultBaseURL,
            appId: String? = Bundle.main.bundleIdentifier,
            urlSession: URLSession = .shared,
            configCache: ConfigCache = .memoryAndDisk,
            offlineQueue: Bool = false,
            collectsDeviceContext: Bool = true
        ) {
            self.key = key
            self.baseURL = baseURL
            self.appId = appId
            self.urlSession = urlSession
            self.configCache = configCache
            self.offlineQueue = offlineQueue
            self.collectsDeviceContext = collectsDeviceContext
        }
    }

    /// The outcome of ``flushQueue()``.
    public struct QueueFlushResult: Sendable, Equatable {
        /// Reports ToDoddle now has.
        public var sent: [ReportReceipt]
        /// Reports the server refused for good. They were removed from the queue.
        public var dropped: [TododdleSupportError]
        /// Reports still waiting, because the device is still offline.
        public var remaining: Int
    }

    /// The most reports the offline queue holds. A report beyond this fails with its network error.
    public static let maxQueuedReports = 10
    /// Queued reports older than this are dropped on the next flush.
    public static let maxQueuedAge: TimeInterval = 7 * 24 * 60 * 60

    public nonisolated let configuration: Configuration
    private let transport: Transport
    private let configStore: FileStore?
    private let queueStore: FileStore?
    private let automaticContext: @Sendable () -> ReportContext
    private let now: @Sendable () -> Date

    private var cached: CachedConfig?
    private var loadedDiskCache = false
    private var isFlushing = false

    private static let configFileName = "config.json"

    public init(configuration: Configuration) {
        self.init(configuration: configuration, sleep: { try await Task.sleep(for: $0) })
    }

    /// Shortcut for `init(configuration: .init(key: key))`.
    public init(key: String) {
        self.init(configuration: Configuration(key: key))
    }

    init(
        configuration: Configuration,
        sleep: @escaping SleepFunction,
        configDirectory: URL? = nil,
        queueDirectory: URL? = nil,
        automaticContext: @escaping @Sendable () -> ReportContext = { DeviceContext.automatic() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.transport = Transport(session: configuration.urlSession, policy: .standard, sleep: sleep)
        let scope = FileStore.scope(key: configuration.key, baseURL: configuration.baseURL)
        if configuration.configCache == .memoryAndDisk,
           let directory = configDirectory ?? FileStore.cachesDirectory(scope: scope) {
            configStore = FileStore(directory: directory)
        } else {
            configStore = nil
        }
        if configuration.offlineQueue, let directory = queueDirectory ?? FileStore.applicationSupportDirectory(scope: scope) {
            queueStore = FileStore(directory: directory)
        } else {
            queueStore = nil
        }
        self.automaticContext = automaticContext
        self.now = now
    }

    // MARK: Config

    /// The last config this client loaded (from the server or the disk cache), without a request.
    public var cachedConfig: SupportConfig? {
        loadDiskCacheIfNeeded()
        return cached?.config
    }

    /// Reads the report form. Sends `If-None-Match` when it has a cached copy, and uses the cache
    /// while the server's `max-age` lasts. If the server cannot be reached, it returns the last
    /// good config when it has one.
    public func config() async throws -> SupportConfig {
        try await config(forceRefresh: false)
    }

    /// Like ``config()``, but always asks the server (still with `If-None-Match`).
    public func config(forceRefresh: Bool) async throws -> SupportConfig {
        loadDiskCacheIfNeeded()
        if !forceRefresh, let cached, cached.isFresh(at: now()) {
            return cached.config
        }

        var request = try apiRequest(path: "config", method: "GET")
        if let etag = cached?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as TododdleSupportError {
            if error.isTransient, let fallback = cached?.config { return fallback }
            throw error
        }

        let maxAge = CachedConfig.maxAge(fromCacheControl: response.value(forHTTPHeaderField: "Cache-Control"))
        if response.statusCode == 304 {
            guard var current = cached else {
                throw TododdleSupportError.invalidResponse("The server sent 304 but no config is cached.", status: 304)
            }
            current.fetchedAt = now()
            current.maxAge = maxAge ?? current.maxAge
            if let etag = response.value(forHTTPHeaderField: "ETag") { current.etag = etag }
            store(current)
            return current.config
        }

        let config: SupportConfig
        do {
            config = try JSONDecoder().decode(SupportConfig.self, from: data)
        } catch {
            throw TododdleSupportError.invalidResponse("The config could not be read: \(error)", status: response.statusCode)
        }
        store(CachedConfig(config: config, etag: response.value(forHTTPHeaderField: "ETag"), fetchedAt: now(), maxAge: maxAge))
        return config
    }

    private func store(_ value: CachedConfig) {
        cached = value
        try? configStore?.write(value, name: Self.configFileName)
    }

    private func loadDiskCacheIfNeeded() {
        guard !loadedDiskCache else { return }
        loadedDiskCache = true
        if cached == nil, let stored = configStore?.read(CachedConfig.self, name: Self.configFileName) {
            cached = stored
        }
    }

    // MARK: Reports

    /// Checks a report against a config without sending it. See ``ReportValidator``.
    public nonisolated func validate(_ report: Report, against config: SupportConfig) -> [String: String] {
        ReportValidator.validate(report, against: config)
    }

    /// Sends a report: validates it, declares its attachments, uploads each file, then submits.
    ///
    /// One idempotency key is made for the report and reused on every retry, so a retry never
    /// creates a second ticket.
    ///
    /// - Parameter config: The config the form was built from. When `nil`, the client uses
    ///   ``config()``.
    /// - Throws: ``TododdleSupportError``. Local validation failures use ``TododdleSupportError/Code/invalidFields``
    ///   with no `httpStatus`, and nothing is sent.
    public func report(_ report: Report, using config: SupportConfig? = nil) async throws -> ReportReceipt {
        let resolved: SupportConfig
        if let config {
            resolved = config
        } else {
            resolved = try await self.config()
        }

        let fieldErrors = ReportValidator.validate(report, against: resolved)
        if !fieldErrors.isEmpty {
            throw TododdleSupportError(code: .invalidFields, message: "Check the highlighted fields.", fields: fieldErrors)
        }

        try checkConfiguration()
        let request = makeRequest(report, config: resolved)
        do {
            return try await send(request, attachments: report.attachments)
        } catch let error as TododdleSupportError {
            if error.isTransient, let queued = try? enqueue(request, attachments: report.attachments) {
                return queued
            }
            throw error
        }
    }

    private func makeRequest(_ report: Report, config: SupportConfig) -> ReportRequest {
        var fields: [String: String] = [:]
        for definition in config.form.fields {
            if let value = report.fields[definition.key]?.trimmedOrNil {
                fields[definition.key] = value
            }
        }
        let titleEnabled = config.form.title?.enabled ?? false
        let context = DeviceContext.merge(
            automatic: configuration.collectsDeviceContext ? automaticContext() : nil,
            app: report.context
        )
        return ReportRequest(
            idempotencyKey: Self.makeIdempotencyKey(),
            type: report.type,
            formVersion: config.form.version,
            title: titleEnabled ? report.title?.trimmedOrNil : nil,
            description: report.description?.trimmedOrNil,
            fields: fields.isEmpty ? nil : fields,
            context: context,
            reporter: Self.clean(report.reporter),
            attachments: report.attachments.isEmpty ? nil : report.attachments.map {
                .init(fileName: $0.fileName, contentType: $0.contentType, size: $0.data.count)
            }
        )
    }

    private static func clean(_ reporter: Reporter?) -> Reporter? {
        guard let reporter else { return nil }
        let cleaned = Reporter(
            name: reporter.name?.trimmedOrNil?.truncated(to: 100),
            email: reporter.email?.trimmedOrNil?.truncated(to: 254),
            customerReference: reporter.customerReference?.trimmedOrNil?.truncated(to: 100)
        )
        return cleaned == Reporter() ? nil : cleaned
    }

    /// 32 hex characters: a UUID without dashes.
    static func makeIdempotencyKey() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Runs the whole report flow for one request body. Every retry inside reuses the same body.
    private func send(_ body: ReportRequest, attachments: [ReportAttachment]) async throws -> ReportReceipt {
        var request = try apiRequest(path: "reports", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, http) = try await transport.send(request)
        let created = try Self.decodeReport(data, status: http.statusCode)

        if created.status == ReportResponse.received {
            return ReportReceipt(reportId: created.reportId, status: .received, idempotencyKey: body.idempotencyKey)
        }
        guard created.status == ReportResponse.awaitingUploads,
              let submitToken = created.submitToken,
              let uploads = created.uploads,
              uploads.count == attachments.count else {
            throw TododdleSupportError.invalidResponse("The report response did not match the declared attachments.", status: http.statusCode)
        }

        for (upload, attachment) in zip(uploads, attachments) {
            try await self.upload(attachment, to: upload)
        }

        var submit = try apiRequest(path: "reports/\(created.reportId)/submit", method: "POST")
        submit.setValue("application/json", forHTTPHeaderField: "Content-Type")
        submit.httpBody = try JSONEncoder().encode(SubmitRequest(submitToken: submitToken))
        let (submitData, submitHTTP) = try await transport.send(submit)
        let submitted = try Self.decodeReport(submitData, status: submitHTTP.statusCode)
        return ReportReceipt(reportId: submitted.reportId, status: .received, idempotencyKey: body.idempotencyKey)
    }

    /// `PUT`s the raw bytes with the returned headers, minus the ones a server must not set
    /// (see ``isForbiddenUploadHeader(_:)``). The SDK key is not sent to the upload host.
    private func upload(_ attachment: ReportAttachment, to upload: ReportResponse.Upload) async throws {
        guard let url = URL(string: upload.uploadUrl), Self.isAllowedURL(url) else {
            throw TododdleSupportError.invalidResponse("The upload URL is not a valid HTTPS URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (name, value) in upload.headers where !Self.isForbiddenUploadHeader(name) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = attachment.data
        _ = try await transport.send(request)
    }

    private static func decodeReport(_ data: Data, status: Int) throws -> ReportResponse {
        let response: ReportResponse
        do {
            response = try JSONDecoder().decode(ReportResponse.self, from: data)
        } catch {
            throw TododdleSupportError.invalidResponse("The report response could not be read.", status: status)
        }
        guard response.reportId.range(of: "^rpt_[A-Za-z0-9]{1,64}$", options: .regularExpression) != nil else {
            throw TododdleSupportError.invalidResponse("The report ID has an unexpected form.", status: status)
        }
        return response
    }

    /// True for HTTPS URLs with a host, and for plain HTTP only when the host is loopback.
    static func isAllowedURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && ["127.0.0.1", "::1", "[::1]", "localhost"].contains(host)
    }

    /// Upload headers the SDK never sends, even when the server lists them.
    static func isForbiddenUploadHeader(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.hasPrefix("proxy-") ||
            ["host", "authorization", "cookie", "connection", "transfer-encoding", "content-length"].contains(lowered)
    }

    /// Refuses a key without the public or test prefix, and a base URL that is not HTTPS (or loopback HTTP).
    private func checkConfiguration() throws {
        let key = configuration.key
        guard key.hasPrefix("tdsk_pub_") || key.hasPrefix("tdsk_test_") else {
            throw TododdleSupportError(code: .invalidKey, message: "The SDK key must start with tdsk_pub_ or tdsk_test_.")
        }
        guard Self.isAllowedURL(configuration.baseURL) else {
            throw TododdleSupportError(
                code: .invalidConfiguration,
                message: "The base URL must use HTTPS. Plain HTTP is allowed only for 127.0.0.1, ::1 or localhost."
            )
        }
    }

    private func apiRequest(path: String, method: String) throws -> URLRequest {
        try checkConfiguration()
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue(configuration.key, forHTTPHeaderField: "X-Tododdle-Key")
        request.setValue("swift/\(Self.sdkVersion)", forHTTPHeaderField: "X-Tododdle-Sdk")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let appId = configuration.appId, !appId.isEmpty {
            request.setValue(String(appId.prefix(200)), forHTTPHeaderField: "X-Tododdle-App-Id")
        }
        // The SDK does its own ETag handling for config, so URLSession's cache must stay out of it.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    // MARK: Offline queue

    /// The number of reports waiting in the offline queue.
    public func queuedReportCount() -> Int {
        queueStore?.names().count ?? 0
    }

    private func enqueue(_ request: ReportRequest, attachments: [ReportAttachment]) throws -> ReportReceipt? {
        guard let queueStore, queueStore.names().count < Self.maxQueuedReports else { return nil }
        let millis = Int64(now().timeIntervalSince1970 * 1000)
        let name = String(format: "%015lld-", millis) + request.idempotencyKey + ".json"
        try queueStore.write(QueuedReport(request: request, attachments: attachments, queuedAt: now()), name: name)
        return ReportReceipt(reportId: nil, status: .queued, idempotencyKey: request.idempotencyKey)
    }

    /// Sends the reports in the offline queue, oldest first, each with its original idempotency key.
    ///
    /// It stops at the first report that still cannot reach the server. Reports the server refuses
    /// for good are dropped and listed in ``QueueFlushResult/dropped``. Call it when the app becomes
    /// active or the network comes back. Calls made while a flush runs return straight away.
    @discardableResult
    public func flushQueue() async -> QueueFlushResult {
        guard let queueStore, !isFlushing else {
            return QueueFlushResult(sent: [], dropped: [], remaining: queuedReportCount())
        }
        isFlushing = true
        defer { isFlushing = false }

        var sent: [ReportReceipt] = []
        var dropped: [TododdleSupportError] = []
        for name in queueStore.names() {
            guard var item = queueStore.read(QueuedReport.self, name: name) else {
                queueStore.remove(name: name)
                continue
            }
            if now().timeIntervalSince(item.queuedAt) > Self.maxQueuedAge {
                queueStore.remove(name: name)
                dropped.append(TododdleSupportError(code: .reportExpired, message: "The queued report was too old to send."))
                continue
            }
            do {
                sent.append(try await send(item.request, attachments: item.attachments))
                queueStore.remove(name: name)
            } catch let error as TododdleSupportError where error.isTransient {
                break
            } catch let error as TododdleSupportError where error.code == .reportExpired {
                // The upload window closed. Start a new report with a new key on the next flush.
                item.request.idempotencyKey = Self.makeIdempotencyKey()
                try? queueStore.write(item, name: name)
            } catch let error as TododdleSupportError {
                queueStore.remove(name: name)
                dropped.append(error)
            } catch {
                break // Cancelled.
            }
        }
        return QueueFlushResult(sent: sent, dropped: dropped, remaining: queuedReportCount())
    }
}
