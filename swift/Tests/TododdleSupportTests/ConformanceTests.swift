import Foundation
import XCTest
@testable import TododdleSupport

/// Runs the shared conformance cases from `contract/cases/cases.json`.
final class ConformanceTests: XCTestCase {
    static let knownCases: Set<String> = [
        "config_ok",
        "config_not_modified_uses_cache",
        "report_received",
        "report_with_attachment",
        "invalid_fields",
        "rate_limited_then_received_with_same_key",
        "server_error_then_received",
        "revoked_key_is_not_retried",
        "support_unavailable_is_not_retried",
        "expired_report",
        "unknown_error_code_falls_back_to_status",
    ]

    override func tearDown() {
        StubURLProtocol.server = nil
        super.tearDown()
    }

    func testEveryCaseHasATest() throws {
        let names = try Fixtures.cases()["cases"]!.array!.compactMap { $0["name"]?.string }
        XCTAssertEqual(Set(names), Self.knownCases, "Add a test method for each new conformance case.")
        XCTAssertEqual(names.count, Self.knownCases.count)
    }

    func test_config_ok() async throws { try await run("config_ok") }
    func test_config_not_modified_uses_cache() async throws { try await run("config_not_modified_uses_cache") }
    func test_report_received() async throws { try await run("report_received") }
    func test_report_with_attachment() async throws { try await run("report_with_attachment") }
    func test_invalid_fields() async throws { try await run("invalid_fields") }
    func test_rate_limited_then_received_with_same_key() async throws { try await run("rate_limited_then_received_with_same_key") }
    func test_server_error_then_received() async throws { try await run("server_error_then_received") }
    func test_revoked_key_is_not_retried() async throws { try await run("revoked_key_is_not_retried") }
    func test_support_unavailable_is_not_retried() async throws { try await run("support_unavailable_is_not_retried") }
    func test_expired_report() async throws { try await run("expired_report") }
    func test_unknown_error_code_falls_back_to_status() async throws { try await run("unknown_error_code_falls_back_to_status") }

    // MARK: Runner

    private struct Outcome {
        var config: SupportConfig?
        var receipt: ReportReceipt?
        var error: TododdleSupportError?
    }

    private func run(_ name: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let root = try Fixtures.cases()
        let testCase = try XCTUnwrap(root["cases"]?.array?.first { $0["name"]?.string == name }, "No case \(name)")
        let key = try XCTUnwrap(root["key"]?.string)
        let configData = try root["config"]!.data()

        var substitutions = ["$config": configData]
        var attachment: ReportAttachment?
        if let spec = testCase["attachment"] {
            let bytes = try XCTUnwrap(Data(base64Encoded: spec["bytesBase64"]!.string!))
            substitutions["$attachment"] = bytes
            attachment = ReportAttachment(fileName: spec["fileName"]!.string!, contentType: spec["contentType"]!.string!, data: bytes)
        }

        let server = MockServer(exchanges: testCase["exchanges"]!.array!, substitutions: substitutions)
        StubURLProtocol.server = server
        let sleeps = SleepRecorder()
        let client = Fixtures.client(key: key, sleep: sleeps.sleep)

        var outcome = Outcome()
        do {
            switch testCase["operation"]?.string {
            case "getConfig":
                outcome.config = try await client.config()
            case "getConfigTwice":
                _ = try await client.config()
                outcome.config = try await client.config()
            case "report", "reportWithAttachment":
                let config = try JSONDecoder().decode(SupportConfig.self, from: configData)
                var report = try Fixtures.report(root["report"]!)
                if testCase["operation"]?.string == "reportWithAttachment" {
                    report.attachments = [try XCTUnwrap(attachment, "The case has no attachment")]
                }
                outcome.receipt = try await client.report(report, using: config)
            case let other:
                XCTFail("Unknown operation \(other ?? "nil")", file: file, line: line)
                return
            }
        } catch let error as TododdleSupportError {
            outcome.error = error
        }

        for failure in server.allFailures {
            XCTFail("\(name): \(failure)", file: file, line: line)
        }
        XCTAssertEqual(server.unusedExchanges, 0, "\(name): not every exchange was used", file: file, line: line)
        check(testCase["expect"]!, outcome: outcome, server: server, sleeps: sleeps, name: name, file: file, line: line)

        // Every API request carries the SDK headers with the exact values.
        for request in server.recorded where !request.path.hasPrefix("/upload/") {
            XCTAssertEqual(request.headers["x-tododdle-key"], key, file: file, line: line)
            XCTAssertEqual(request.headers["x-tododdle-sdk"], "swift/\(TododdleSupport.sdkVersion)", file: file, line: line)
            XCTAssertEqual(request.headers["x-tododdle-app-id"], Fixtures.appId, file: file, line: line)
        }
        // The key never goes to the upload host.
        for request in server.recorded where request.path.hasPrefix("/upload/") {
            XCTAssertNil(request.headers["x-tododdle-key"], file: file, line: line)
        }
    }

    private func check(
        _ expect: JSONValue,
        outcome: Outcome,
        server: MockServer,
        sleeps: SleepRecorder,
        name: String,
        file: StaticString,
        line: UInt
    ) {
        let ok = expect["ok"]?.bool ?? true
        if ok {
            XCTAssertNil(outcome.error, "\(name): unexpected error \(String(describing: outcome.error))", file: file, line: line)
        } else {
            XCTAssertNotNil(outcome.error, "\(name): expected an error", file: file, line: line)
        }
        if let version = expect["formVersion"]?.int {
            XCTAssertEqual(outcome.config?.form.version, version, file: file, line: line)
        }
        if let keys = expect["fieldKeys"]?.array {
            XCTAssertEqual(outcome.config?.form.fields.map(\.key), keys.compactMap(\.string), file: file, line: line)
        }
        if let reportId = expect["reportId"]?.string {
            XCTAssertEqual(outcome.receipt?.reportId, reportId, file: file, line: line)
            XCTAssertEqual(outcome.receipt?.status, .received, file: file, line: line)
        }
        if let code = expect["errorCode"]?.string {
            XCTAssertEqual(outcome.error?.code.rawValue, code, file: file, line: line)
        }
        if let fields = expect["fieldErrors"]?.object {
            XCTAssertEqual(outcome.error?.fields, fields.compactMapValues(\.string), file: file, line: line)
        }
        if let status = expect["httpStatus"]?.int {
            XCTAssertEqual(outcome.error?.httpStatus, status, file: file, line: line)
        }
        if let requests = expect["requests"]?.int {
            XCTAssertEqual(server.requestCount, requests, file: file, line: line)
        }
        if let minDelay = expect["minDelayMs"]?.int {
            XCTAssertGreaterThanOrEqual(sleeps.totalMilliseconds, Int64(minDelay), "\(name): waited too little", file: file, line: line)
        }
    }
}

/// Shared test fixtures.
enum Fixtures {
    static let appId = "com.example.tododdle-tests"

    static func casesURL() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "cases", withExtension: "json", subdirectory: "Resources"))
    }

    static func cases() throws -> JSONValue {
        try JSONValue.parse(Data(contentsOf: casesURL()))
    }

    /// The repository root, found from this file's location.
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TododdleSupportTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // swift
            .deletingLastPathComponent() // root
    }

    static func config() throws -> SupportConfig {
        try JSONDecoder().decode(SupportConfig.self, from: cases()["config"]!.data())
    }

    static func client(
        key: String = "tdsk_pub_TESTKEY0000000000000000000000000",
        sleep: @escaping SleepFunction = { _ in },
        configCache: TododdleSupport.Configuration.ConfigCache = .memory,
        configDirectory: URL? = nil,
        offlineQueue: Bool = false,
        queueDirectory: URL? = nil
    ) -> TododdleSupport {
        TododdleSupport(
            configuration: .init(
                key: key,
                baseURL: URL(string: MockServer.baseURL)!,
                appId: appId,
                urlSession: StubURLProtocol.session(),
                configCache: configCache,
                offlineQueue: offlineQueue
            ),
            sleep: sleep,
            configDirectory: configDirectory,
            queueDirectory: queueDirectory
        )
    }

    /// Builds the SDK's ``Report`` from the cases' `report` object.
    static func report(_ json: JSONValue) throws -> Report {
        let context = try json["context"].map { try JSONDecoder().decode(ReportContext.self, from: $0.data()) }
        let reporter = try json["reporter"].map { try JSONDecoder().decode(Reporter.self, from: $0.data()) }
        return Report(
            type: ReportType(rawValue: try XCTUnwrap(json["type"]?.string)),
            title: json["title"]?.string,
            description: json["description"]?.string,
            fields: json["fields"]?.object?.compactMapValues(\.string) ?? [:],
            context: context,
            reporter: reporter
        )
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TododdleSupportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
