import Foundation
import XCTest
@testable import TododdleSupport

/// SDK behaviour beyond the shared cases: retries, caching, the offline queue, validation and context.
final class ClientBehaviourTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.server = nil
        super.tearDown()
    }

    private func exchange(_ method: String, _ path: String, status: Int, body: JSONValue? = nil, headers: [String: String] = [:], networkError: Bool = false) -> JSONValue {
        var response: [String: JSONValue] = ["status": .number(Double(status))]
        if let body { response["body"] = body }
        if !headers.isEmpty { response["headers"] = .object(headers.mapValues { .string($0) }) }
        if networkError { response["networkError"] = .bool(true) }
        return .object([
            "request": .object(["method": .string(method), "path": .string(path)]),
            "response": .object(response),
        ])
    }

    private let received: JSONValue = .object(["reportId": .string("rpt_AAAAAAAAAAAAAAAA0009"), "status": .string("received")])

    private func validReport() -> Report {
        Report(type: .problem, description: "It broke.", fields: ["area": "Home"])
    }

    // MARK: Harness

    func testMockServerCatchesABrokenRule() throws {
        let rule: JSONValue = .object([
            "request": .object([
                "method": .string("POST"), "path": .string("/reports"),
                "must": .object(["headers": .object(["X-Tododdle-Key": .string("other")])]),
            ]),
            "response": .object(["status": .number(201)]),
        ])
        let server = MockServer(exchanges: [rule])
        var request = URLRequest(url: URL(string: "\(MockServer.baseURL)/reports")!)
        request.httpMethod = "POST"
        request.setValue("tdsk_pub_x", forHTTPHeaderField: "X-Tododdle-Key")
        _ = server.handle(request, body: Data())
        XCTAssertEqual(server.allFailures.count, 1)
    }

    // MARK: Retries

    func testServerErrorsStopAfterThreeAttemptsWithBackoff() async throws {
        let server = MockServer(exchanges: Array(repeating: exchange("POST", "/reports", status: 503), count: 3))
        StubURLProtocol.server = server
        let sleeps = SleepRecorder()
        let client = Fixtures.client(sleep: sleeps.sleep)

        do {
            _ = try await client.report(validReport(), using: try Fixtures.config())
            XCTFail("Expected an error")
        } catch let error as TododdleSupportError {
            XCTAssertEqual(error.code, .httpError)
            XCTAssertEqual(error.httpStatus, 503)
        }
        XCTAssertEqual(server.requestCount, 3)
        XCTAssertEqual(sleeps.durations, [.seconds(1), .seconds(2)])
        let keys = server.recorded.compactMap { try? JSONValue.parse($0.body)["idempotencyKey"]?.string }
        XCTAssertEqual(Set(keys).count, 1, "Every attempt must reuse the same idempotency key")
    }

    func testNetworkErrorsAreRetried() async throws {
        let server = MockServer(exchanges: [
            exchange("POST", "/reports", status: 0, networkError: true),
            exchange("POST", "/reports", status: 201, body: received),
        ])
        StubURLProtocol.server = server
        let receipt = try await Fixtures.client().report(validReport(), using: try Fixtures.config())
        XCTAssertEqual(receipt.reportId, "rpt_AAAAAAAAAAAAAAAA0009")
        XCTAssertEqual(server.requestCount, 2)
    }

    func testVeryLongRetryAfterIsReturnedNotWaited() async throws {
        let server = MockServer(exchanges: [
            exchange("POST", "/reports", status: 429, body: .object(["error": .object(["code": .string("RATE_LIMITED"), "message": .string("Slow down.")])]), headers: ["Retry-After": "3600"]),
        ])
        StubURLProtocol.server = server
        let sleeps = SleepRecorder()
        do {
            _ = try await Fixtures.client(sleep: sleeps.sleep).report(validReport(), using: try Fixtures.config())
            XCTFail("Expected an error")
        } catch let error as TododdleSupportError {
            XCTAssertEqual(error.code, .rateLimited)
            XCTAssertEqual(error.retryAfter, 3600)
        }
        XCTAssertTrue(sleeps.durations.isEmpty)
    }

    func testNonRetryableStatusesAreNotRetried() async throws {
        for status in [400, 401, 403, 404, 409, 410, 413, 422] {
            let server = MockServer(exchanges: [exchange("POST", "/reports", status: status)])
            StubURLProtocol.server = server
            do {
                _ = try await Fixtures.client().report(validReport(), using: try Fixtures.config())
                XCTFail("Expected an error for \(status)")
            } catch let error as TododdleSupportError {
                XCTAssertEqual(error.httpStatus, status)
            }
            XCTAssertEqual(server.requestCount, 1, "HTTP \(status) must not be retried")
        }
    }

    // MARK: Validation

    func testLocalValidationSendsNothing() async throws {
        let server = MockServer(exchanges: [])
        StubURLProtocol.server = server
        do {
            _ = try await Fixtures.client().report(Report(type: .problem, fields: ["area": "Mars"]), using: try Fixtures.config())
            XCTFail("Expected an error")
        } catch let error as TododdleSupportError {
            XCTAssertEqual(error.code, .invalidFields)
            XCTAssertNil(error.httpStatus)
            XCTAssertEqual(Set(error.fields.keys), ["description", "area"])
        }
        XCTAssertEqual(server.requestCount, 0)
    }

    func testValidatorRules() throws {
        let config = try Fixtures.config()
        XCTAssertTrue(ReportValidator.validate(validReport(), against: config).isEmpty)

        var report = validReport()
        report.type = "bug"
        report.title = String(repeating: "a", count: 161)
        report.fields["steps"] = String(repeating: "b", count: 5_001)
        report.attachments = [ReportAttachment(fileName: "a.zip", contentType: "application/zip", data: Data([1]))]
        let errors = ReportValidator.validate(report, against: config)
        XCTAssertEqual(Set(errors.keys), ["type", "title", "steps", "attachments"])

        var noFiles = config
        noFiles.form.attachments.enabled = false
        var withFile = validReport()
        withFile.attachments = [ReportAttachment(fileName: "a.png", contentType: "image/png", data: Data([1]))]
        XCTAssertNotNil(ReportValidator.validate(withFile, against: noFiles)["attachments"])

        var tooMany = validReport()
        tooMany.attachments = Array(repeating: withFile.attachments[0], count: 6)
        XCTAssertNotNil(ReportValidator.validate(tooMany, against: config)["attachments"])
    }

    func testRequestBodyDropsUnknownFieldsAndDisabledTitle() async throws {
        let server = MockServer(exchanges: [exchange("POST", "/reports", status: 201, body: received)])
        StubURLProtocol.server = server
        var config = try Fixtures.config()
        config.form.title?.enabled = false
        var report = validReport()
        report.title = "Ignored"
        report.fields["unknown"] = "x"
        report.reporter = Reporter(name: "  ", email: nil)
        _ = try await Fixtures.client().report(report, using: config)

        let body = try JSONValue.parse(server.recorded[0].body)
        XCTAssertNil(body["title"])
        XCTAssertNil(body.at(path: "fields.unknown"))
        XCTAssertNil(body["reporter"])
        XCTAssertEqual(body["formVersion"]?.int, 3)
        XCTAssertNotNil(body["idempotencyKey"]?.string?.range(of: "^[A-Za-z0-9_-]{16,64}$", options: .regularExpression))
    }

    // MARK: Config cache

    func testConfigFallsBackToCacheWhenOffline() async throws {
        let config = try Fixtures.cases()["config"]!
        let offline = exchange("GET", "/config", status: 0, networkError: true)
        let server = MockServer(exchanges: [
            exchange("GET", "/config", status: 200, body: config, headers: ["ETag": "\"cfg-3\""]),
            offline, offline, offline,
        ])
        StubURLProtocol.server = server
        let client = Fixtures.client()
        _ = try await client.config()
        let again = try await client.config()
        XCTAssertEqual(again.form.version, 3)
        XCTAssertEqual(server.requestCount, 4)
    }

    func testFreshConfigIsServedWithoutARequest() async throws {
        let config = try Fixtures.cases()["config"]!
        let server = MockServer(exchanges: [
            exchange("GET", "/config", status: 200, body: config, headers: ["ETag": "\"cfg-3\"", "Cache-Control": "public, max-age=300"]),
        ])
        StubURLProtocol.server = server
        let client = Fixtures.client()
        _ = try await client.config()
        _ = try await client.config()
        XCTAssertEqual(server.requestCount, 1)
    }

    func testDiskCacheSurvivesANewClient() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Fixtures.cases()["config"]!
        let first = MockServer(exchanges: [exchange("GET", "/config", status: 200, body: config, headers: ["ETag": "\"cfg-3\""])])
        StubURLProtocol.server = first
        _ = try await Fixtures.client(configCache: .memoryAndDisk, configDirectory: directory).config()

        let revalidate: JSONValue = .object([
            "request": .object(["method": .string("GET"), "path": .string("/config"),
                                "must": .object(["headers": .object(["If-None-Match": .string("\"cfg-3\"")])])]),
            "response": .object(["status": .number(304)]),
        ])
        let second = MockServer(exchanges: [revalidate])
        StubURLProtocol.server = second
        let client = Fixtures.client(configCache: .memoryAndDisk, configDirectory: directory)
        let cachedBeforeRequest = await client.cachedConfig
        XCTAssertEqual(cachedBeforeRequest?.form.version, 3)
        let loaded = try await client.config()
        XCTAssertEqual(loaded.project.name, "Mosslight")
        XCTAssertTrue(second.allFailures.isEmpty, second.allFailures.joined(separator: "\n"))
    }

    // MARK: Offline queue

    func testOfflineReportIsQueuedAndFlushedWithTheSameKey() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let offline = exchange("POST", "/reports", status: 0, networkError: true)
        StubURLProtocol.server = MockServer(exchanges: [offline, offline, offline])
        let client = Fixtures.client(offlineQueue: true, queueDirectory: directory)

        let queued = try await client.report(validReport(), using: try Fixtures.config())
        XCTAssertEqual(queued.status, .queued)
        XCTAssertNil(queued.reportId)
        let countAfterQueueing = await client.queuedReportCount()
        XCTAssertEqual(countAfterQueueing, 1)

        let online = MockServer(exchanges: [exchange("POST", "/reports", status: 201, body: received)])
        StubURLProtocol.server = online
        let result = await client.flushQueue()
        XCTAssertEqual(result.sent.map(\.reportId), ["rpt_AAAAAAAAAAAAAAAA0009"])
        XCTAssertEqual(result.sent.first?.idempotencyKey, queued.idempotencyKey)
        XCTAssertEqual(result.remaining, 0)
        let sentKey = try JSONValue.parse(online.recorded[0].body)["idempotencyKey"]?.string
        XCTAssertEqual(sentKey, queued.idempotencyKey)
    }

    func testFlushDropsReportsTheServerRefuses() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let offline = exchange("POST", "/reports", status: 0, networkError: true)
        StubURLProtocol.server = MockServer(exchanges: [offline, offline, offline])
        let client = Fixtures.client(offlineQueue: true, queueDirectory: directory)
        _ = try await client.report(validReport(), using: try Fixtures.config())

        StubURLProtocol.server = MockServer(exchanges: [
            exchange("POST", "/reports", status: 401, body: .object(["error": .object(["code": .string("KEY_REVOKED"), "message": .string("Revoked.")])])),
        ])
        let result = await client.flushQueue()
        XCTAssertEqual(result.dropped.map(\.code), [.keyRevoked])
        XCTAssertEqual(result.remaining, 0)
    }

    func testWithoutTheQueueOfflineReportsThrow() async throws {
        let offline = exchange("POST", "/reports", status: 0, networkError: true)
        StubURLProtocol.server = MockServer(exchanges: [offline, offline, offline])
        do {
            _ = try await Fixtures.client().report(validReport(), using: try Fixtures.config())
            XCTFail("Expected an error")
        } catch let error as TododdleSupportError {
            XCTAssertEqual(error.code, .networkError)
            XCTAssertNil(error.httpStatus)
        }
    }

    // MARK: Configuration, redirects and uploads

    func testKeysWithoutAPublicOrTestPrefixSendNothing() async throws {
        let server = MockServer(exchanges: [])
        StubURLProtocol.server = server
        for key in ["", "tdsk_secret_0000", "sk_live_0000", "TDSK_PUB_0000"] {
            let client = Fixtures.client(key: key)
            do {
                _ = try await client.config()
                XCTFail("Expected an error for \(key)")
            } catch let error as TododdleSupportError {
                XCTAssertEqual(error.code, .invalidKey)
                XCTAssertNil(error.httpStatus)
            }
            do {
                _ = try await client.report(validReport(), using: try Fixtures.config())
                XCTFail("Expected an error for \(key)")
            } catch let error as TododdleSupportError {
                XCTAssertEqual(error.code, .invalidKey)
            }
        }
        XCTAssertEqual(server.requestCount, 0)
    }

    func testTestKeysAreAccepted() async throws {
        let server = MockServer(exchanges: [exchange("POST", "/reports", status: 201, body: received)])
        StubURLProtocol.server = server
        let receipt = try await Fixtures.client(key: "tdsk_test_TESTKEY0000000000000000000000000")
            .report(validReport(), using: try Fixtures.config())
        XCTAssertEqual(receipt.reportId, "rpt_AAAAAAAAAAAAAAAA0009")
    }

    func testPlainHTTPBaseURLIsRefusedUnlessLoopback() async throws {
        let server = MockServer(exchanges: [])
        StubURLProtocol.server = server
        for base in ["http://app.tododdle.com/api/support/sdk/v1", "http://10.0.0.2", "ftp://127.0.0.1", "file:///tmp"] {
            do {
                _ = try await Fixtures.client(baseURL: URL(string: base)!).config()
                XCTFail("Expected an error for \(base)")
            } catch let error as TododdleSupportError {
                XCTAssertEqual(error.code, .invalidConfiguration, base)
            }
        }
        XCTAssertEqual(server.requestCount, 0)

        for allowed in ["https://app.tododdle.com/api/support/sdk/v1", "http://127.0.0.1:8080", "http://localhost", "http://[::1]:9000"] {
            XCTAssertTrue(TododdleSupport.isAllowedURL(URL(string: allowed)!), allowed)
        }
        for refused in ["http://example.com", "http://127.0.0.2", "http://localhost.example.com", "https:///no-host"] {
            XCTAssertFalse(TododdleSupport.isAllowedURL(URL(string: refused)!), refused)
        }
    }

    func testRedirectsAreNotFollowed() async throws {
        let server = MockServer(exchanges: [
            exchange("POST", "/reports", status: 302, headers: ["Location": "\(MockServer.baseURL)/elsewhere"]),
        ])
        StubURLProtocol.server = server
        do {
            _ = try await Fixtures.client().report(validReport(), using: try Fixtures.config())
            XCTFail("Expected an error")
        } catch let error as TododdleSupportError {
            XCTAssertEqual(error.code, .invalidResponse)
            XCTAssertEqual(error.httpStatus, 302)
        }
        XCTAssertEqual(server.requestCount, 1, "The redirect must not be followed")
        XCTAssertTrue(server.allFailures.isEmpty, server.allFailures.joined(separator: "\n"))
    }

    private func awaitingUploads(uploadUrl: String, headers: [String: String]) -> JSONValue {
        .object([
            "reportId": .string("rpt_AAAAAAAAAAAAAAAA0009"),
            "status": .string("awaiting_uploads"),
            "submitToken": .string("st_0123456789abcdef0123456789abcdef"),
            "expiresAt": .string("2099-01-01T00:00:00Z"),
            "uploads": .array([.object([
                "uploadUrl": .string(uploadUrl),
                "headers": .object(headers.mapValues { .string($0) }),
                "expiresAt": .string("2099-01-01T00:00:00Z"),
            ])]),
        ])
    }

    private func reportWithAttachment() -> Report {
        var report = validReport()
        report.attachments = [ReportAttachment(fileName: "note.txt", contentType: "text/plain", data: Data("hello".utf8))]
        return report
    }

    func testUploadDropsHeadersTheServerMustNotSet() async throws {
        let server = MockServer(exchanges: [
            exchange("POST", "/reports", status: 201, body: awaitingUploads(uploadUrl: "{{baseUrl}}/upload/1", headers: [
                "Content-Type": "text/plain",
                "X-Upload-Tag": "kept",
                "Authorization": "Bearer stolen",
                "Cookie": "session=1",
                "Proxy-Authorization": "Basic eA==",
                "Host": "evil.example.com",
                "Connection": "close",
                "Transfer-Encoding": "chunked",
                "Content-Length": "999",
            ])),
            exchange("PUT", "/upload/1", status: 200),
            exchange("POST", "/reports/rpt_AAAAAAAAAAAAAAAA0009/submit", status: 200, body: received),
        ])
        StubURLProtocol.server = server
        _ = try await Fixtures.client().report(reportWithAttachment(), using: try Fixtures.config())

        let put = try XCTUnwrap(server.recorded.first { $0.method == "PUT" })
        XCTAssertEqual(put.headers["content-type"], "text/plain")
        XCTAssertEqual(put.headers["x-upload-tag"], "kept")
        for name in ["authorization", "cookie", "proxy-authorization", "connection", "transfer-encoding"] {
            XCTAssertNil(put.headers[name], name)
        }
        XCTAssertNotEqual(put.headers["host"], "evil.example.com")
        XCTAssertNotEqual(put.headers["content-length"], "999")
        XCTAssertTrue(TododdleSupport.isForbiddenUploadHeader("PROXY-Connection"))
        XCTAssertTrue(TododdleSupport.isForbiddenUploadHeader("content-length"))
        XCTAssertFalse(TododdleSupport.isForbiddenUploadHeader("Content-Type"))
    }

    func testUploadURLMustBeHTTPSEvenWithALoopbackBaseURL() async throws {
        for uploadUrl in ["http://uploads.example.com/upload/1", "ftp://127.0.0.1/upload/1", "not a url"] {
            let server = MockServer(exchanges: [
                exchange("POST", "/reports", status: 201, body: awaitingUploads(uploadUrl: uploadUrl, headers: ["Content-Type": "text/plain"])),
            ])
            StubURLProtocol.server = server
            do {
                _ = try await Fixtures.client().report(reportWithAttachment(), using: try Fixtures.config())
                XCTFail("Expected an error for \(uploadUrl)")
            } catch let error as TododdleSupportError {
                XCTAssertEqual(error.code, .invalidResponse, uploadUrl)
            }
            XCTAssertEqual(server.requestCount, 1, uploadUrl)
        }
    }

    // MARK: Context and attachments

    func testContextMergeAndLimits() {
        let automatic = ReportContext(platform: "ios", appVersion: "1.0", osName: "iOS", locale: "en-GB")
        let app = ReportContext(appVersion: "2.0", screen: "Settings?token=secret#x", extra: ["plan": String(repeating: "x", count: 600)])
        let merged = DeviceContext.merge(automatic: automatic, app: app)
        XCTAssertEqual(merged?.appVersion, "2.0")
        XCTAssertEqual(merged?.platform, "ios")
        XCTAssertEqual(merged?.screen, "Settings")
        XCTAssertEqual(merged?.extra?["plan"]?.count, 500)
    }

    func testAutomaticContextHasOnlyTheListedFacts() {
        let context = DeviceContext.automatic()
        XCTAssertNotNil(context.osName)
        XCTAssertNotNil(context.osVersion)
        XCTAssertNotNil(context.locale)
        XCTAssertNil(context.screen)
        XCTAssertNil(context.extra)
    }

    func testScreenshotAttachmentKeepsPNGAndConvertsWhenNeeded() throws {
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="))
        let kept = try XCTUnwrap(ScreenshotAttachment.make(from: png))
        XCTAssertEqual(kept.contentType, "image/png")
        XCTAssertEqual(kept.fileName, "screenshot.png")
        XCTAssertEqual(kept.data, png)

        let converted = try XCTUnwrap(ScreenshotAttachment.make(from: png, allowedContentTypes: ["image/jpeg"]))
        XCTAssertEqual(converted.contentType, "image/jpeg")
        XCTAssertEqual(converted.fileName, "screenshot.jpeg")

        XCTAssertNil(ScreenshotAttachment.make(from: Data("not an image".utf8)))
    }

    func testErrorDecodingKeepsUnknownCodes() {
        let body = Data(#"{"error":{"code":"SOMETHING_NEW","message":"New.","requestId":"req_1","extra":1}}"#.utf8)
        let error = TododdleSupportError.from(status: 400, data: body, retryAfter: nil)
        XCTAssertEqual(error.code.rawValue, "SOMETHING_NEW")
        XCTAssertEqual(error.httpStatus, 400)
        XCTAssertEqual(error.requestId, "req_1")
        XCTAssertFalse(error.isTransient)

        let empty = TododdleSupportError.from(status: 502, data: Data(), retryAfter: nil)
        XCTAssertEqual(empty.code, .httpError)
        XCTAssertTrue(empty.isTransient)
    }

    func testConfigIgnoresUnknownFieldsAndValues() throws {
        var json = try Fixtures.cases()["config"]!.object!
        json["newTopLevel"] = .string("ignored")
        var form = json["form"]!.object!
        form["types"] = .array([.object(["value": .string("idea"), "label": .string("Idea")])])
        json["form"] = .object(form)
        let config = try JSONDecoder().decode(SupportConfig.self, from: JSONValue.object(json).data())
        XCTAssertEqual(config.form.types.first?.value.rawValue, "idea")
    }
}
