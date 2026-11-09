import CryptoKit
import Foundation

/// A config with the validators the server sent.
struct CachedConfig: Codable, Sendable {
    var config: SupportConfig
    var etag: String?
    var fetchedAt: Date
    var maxAge: TimeInterval?

    func isFresh(at now: Date) -> Bool {
        guard let maxAge, maxAge > 0 else { return false }
        return now.timeIntervalSince(fetchedAt) < maxAge
    }

    static func maxAge(fromCacheControl header: String?) -> TimeInterval? {
        guard let header else { return nil }
        for directive in header.split(separator: ",") {
            let parts = directive.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "max-age", let seconds = Double(parts[1]) {
                return seconds
            }
            if parts.first?.lowercased() == "no-store" || parts.first?.lowercased() == "no-cache" {
                return nil
            }
        }
        return nil
    }
}

/// A report waiting in the offline queue: the request body (with its idempotency key) and the files.
struct QueuedReport: Codable, Sendable {
    var request: ReportRequest
    var attachments: [ReportAttachment]
    var queuedAt: Date
}

/// Small JSON files in the app container. Every method is synchronous; callers serialise access.
struct FileStore: Sendable {
    let directory: URL

    /// A per-key, per-server folder name, so two clients in one app never share files.
    static func scope(key: String, baseURL: URL) -> String {
        let digest = SHA256.hash(data: Data("\(key)|\(baseURL.absoluteString)".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func cachesDirectory(scope: String) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TododdleSupport", isDirectory: true)
            .appendingPathComponent(scope, isDirectory: true)
    }

    static func applicationSupportDirectory(scope: String) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TododdleSupport", isDirectory: true)
            .appendingPathComponent(scope, isDirectory: true)
            .appendingPathComponent("queue", isDirectory: true)
    }

    func read<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    func write<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory.appendingPathComponent(name)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        #if os(iOS) || os(visionOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    func remove(name: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    func names() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted()
    }
}
