import Foundation
import XCTest
@testable import TododdleSupport

/// Keeps the Swift copies in step with the repository's single sources of truth.
final class ContractSyncTests: XCTestCase {
    func testCasesCopyMatchesContract() throws {
        let source = Fixtures.repositoryRoot.appendingPathComponent("contract/cases/cases.json")
        let copy = try Fixtures.casesURL()
        XCTAssertEqual(
            try Data(contentsOf: copy),
            try Data(contentsOf: source),
            "swift/Tests/TododdleSupportTests/Resources/cases.json differs from contract/cases/cases.json. Run scripts/sync-swift-cases.sh."
        )
    }

    func testSDKVersionMatchesVersionFile() throws {
        let version = try String(contentsOf: Fixtures.repositoryRoot.appendingPathComponent("VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(TododdleSupport.sdkVersion, version, "Run npm run sync-version.")
        // The contract's pattern for X-Tododdle-Sdk.
        XCTAssertNotNil("swift/\(TododdleSupport.sdkVersion)".range(of: "^[a-z-]+/[0-9A-Za-z.+-]+$", options: .regularExpression))
    }

    func testRetryPolicyMatchesCases() throws {
        let policy = try XCTUnwrap(Fixtures.cases()["retryPolicy"])
        XCTAssertEqual(RetryPolicy.standard.maxAttempts, policy["maxAttempts"]?.int)
        XCTAssertEqual(RetryPolicy.standard.backoffSeconds, policy["backoffSeconds"]?.array?.compactMap { $0.int.map(Double.init) })
        XCTAssertEqual(RetryPolicy.standard.retryStatuses, Set(policy["retryStatuses"]?.array?.compactMap(\.int) ?? []))
    }
}
