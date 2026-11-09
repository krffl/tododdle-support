import Foundation
@testable import TododdleSupport

/// Replays the `exchanges` of one conformance case and checks each `request.must` rule.
///
/// It is installed with ``StubURLProtocol``. Requests must arrive in the listed order and match by
/// method and path. `{{baseUrl}}` is ``MockServer/baseURL``.
final class MockServer: @unchecked Sendable {
    static let baseURL = "http://mock.test"

    struct Recorded {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    private let lock = NSLock()
    private let exchanges: [JSONValue]
    private let substitutions: [String: Data]
    private var index = 0
    private(set) var recorded: [Recorded] = []
    private(set) var failures: [String] = []
    private var lastIdempotencyKey: String?

    /// - Parameter substitutions: Values for `$config` (a JSON body) and `$attachment` (raw bytes).
    init(exchanges: [JSONValue], substitutions: [String: Data] = [:]) {
        self.exchanges = exchanges
        self.substitutions = substitutions
    }

    var requestCount: Int { lock.withLock { recorded.count } }
    var unusedExchanges: Int { lock.withLock { exchanges.count - index } }
    var allFailures: [String] { lock.withLock { failures } }

    enum Reply {
        case http(HTTPURLResponse, Data)
        case networkError(URLError)
    }

    func handle(_ request: URLRequest, body: Data) -> Reply {
        lock.withLock {
            let url = request.url!
            let method = request.httpMethod ?? "GET"
            var headers: [String: String] = [:]
            for (name, value) in request.allHTTPHeaderFields ?? [:] { headers[name.lowercased()] = value }
            recorded.append(Recorded(method: method, path: url.path, headers: headers, body: body))

            guard index < exchanges.count else {
                failures.append("Unexpected request \(method) \(url.path) after all exchanges were used.")
                return .http(HTTPURLResponse(url: url, statusCode: 418, httpVersion: nil, headerFields: nil)!, Data())
            }
            let exchange = exchanges[index]
            index += 1

            let expected = exchange["request"]!
            if expected["method"]?.string != method || expected["path"]?.string != url.path {
                failures.append("Exchange \(index): expected \(expected["method"]?.string ?? "?") \(expected["path"]?.string ?? "?"), got \(method) \(url.path).")
            }
            if let must = expected["must"] {
                check(must, headers: headers, body: body, exchange: index)
            }
            if let json = try? JSONValue.parse(body), let key = json["idempotencyKey"]?.string {
                lastIdempotencyKey = key
            }
            return reply(exchange["response"]!, url: url)
        }
    }

    private func check(_ must: JSONValue, headers: [String: String], body: Data, exchange: Int) {
        switch must["headers"] {
        case .array(let names):
            for name in names.compactMap(\.string) where headers[name.lowercased()] == nil {
                failures.append("Exchange \(exchange): header \(name) is missing.")
            }
        case .object(let values):
            for (name, value) in values where headers[name.lowercased()] != value.string {
                failures.append("Exchange \(exchange): header \(name) is \(headers[name.lowercased()] ?? "missing"), expected \(value.string ?? "?").")
            }
        default: break
        }

        let json = try? JSONValue.parse(body)
        switch must["body"] {
        case .array(let paths):
            for path in paths.compactMap(\.string) where json?.at(path: path) == nil || json?.at(path: path) == .null {
                failures.append("Exchange \(exchange): body field \(path) is missing.")
            }
        case .object(let values):
            for (path, value) in values where json?.at(path: path) != value {
                failures.append("Exchange \(exchange): body field \(path) is \(String(describing: json?.at(path: path))), expected \(value).")
            }
        default: break
        }

        if let raw = must["rawBodyBase64"]?.string {
            let expected = raw.hasPrefix("$") ? substitutions[raw] : Data(base64Encoded: raw)
            if expected != body {
                failures.append("Exchange \(exchange): the raw body is not the expected bytes (\(body.count) bytes sent).")
            }
        }

        if must["sameIdempotencyKeyAsPrevious"]?.bool == true {
            let key = json?["idempotencyKey"]?.string
            if key == nil || key != lastIdempotencyKey {
                failures.append("Exchange \(exchange): idempotencyKey \(key ?? "nil") is not the previous key \(lastIdempotencyKey ?? "nil").")
            }
        }
    }

    private func reply(_ response: JSONValue, url: URL) -> Reply {
        if response["networkError"]?.bool == true {
            return .networkError(URLError(.notConnectedToInternet))
        }
        let status = response["status"]?.int ?? 200
        var headers: [String: String] = [:]
        for (name, value) in response["headers"]?.object ?? [:] { headers[name] = value.string }

        var data = Data()
        switch response["body"] {
        case .string(let token) where token.hasPrefix("$"):
            data = substitutions[token] ?? Data()
        case .some(let body) where body != .null:
            data = (try? body.data()) ?? Data()
        default: break
        }
        if !data.isEmpty {
            headers["Content-Type"] = headers["Content-Type"] ?? "application/json"
            let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "{{baseUrl}}", with: Self.baseURL)
            data = Data(text.utf8)
        }
        return .http(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, data)
    }
}

/// Routes every request of a test session to the current ``MockServer``.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _server: MockServer?

    static var server: MockServer? {
        get { lock.withLock { _server } }
        set { lock.withLock { _server = newValue } }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = Self.server else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        switch server.handle(request, body: Self.body(of: request)) {
        case .networkError(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .http(let response, let data):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Records requested sleeps instead of waiting, so retry tests stay fast.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _durations: [Duration] = []

    var durations: [Duration] { lock.withLock { _durations } }
    var totalMilliseconds: Int64 {
        durations.reduce(Int64(0)) { total, duration in
            total + duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
        }
    }

    var sleep: SleepFunction {
        { [self] duration in lock.withLock { _durations.append(duration) } }
    }
}
