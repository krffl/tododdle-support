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
        var request = URLRequest(url: URL(string: "http://mock.test/reports")!)
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
