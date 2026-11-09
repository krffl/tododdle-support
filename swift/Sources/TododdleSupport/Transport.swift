import Foundation

/// The shared retry policy from `contract/cases/cases.json`.
struct RetryPolicy: Sendable {
    var maxAttempts: Int
    var backoffSeconds: [Double]
    var retryStatuses: Set<Int>
    /// A `Retry-After` longer than this is not waited for inside one call. The error goes back to the
    /// app (or the offline queue) with ``TododdleSupportError/retryAfter`` set.
    var maxRetryAfterSeconds: Double

    static let standard = RetryPolicy(
        maxAttempts: 3,
        backoffSeconds: [1, 2, 4],
        retryStatuses: [408, 429, 500, 502, 503, 504],
        maxRetryAfterSeconds: 60
    )

    func backoff(afterAttempt attempt: Int) -> Double {
        backoffSeconds[min(max(attempt - 1, 0), backoffSeconds.count - 1)]
    }
}

typealias SleepFunction = @Sendable (Duration) async throws -> Void

/// Sends requests with the shared retry policy. It never adds headers of its own.
struct Transport: Sendable {
    let session: URLSession
    let policy: RetryPolicy
    let sleep: SleepFunction

    /// Sends the request and returns any 2xx or 304 response. Throws ``TododdleSupportError``.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            attempt += 1
            let failure: TododdleSupportError
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw TododdleSupportError.invalidResponse("The response was not HTTP.")
                }
                if (200..<300).contains(http.statusCode) || http.statusCode == 304 {
                    return (data, http)
                }
                failure = TododdleSupportError.from(
                    status: http.statusCode,
                    data: data,
                    retryAfter: Self.retryAfter(http)
                )
            } catch let error as TododdleSupportError {
                throw error
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                failure = .network(error)
            }

            guard attempt < policy.maxAttempts, failure.isTransient else { throw failure }
            let delay: Double
            if let retryAfter = failure.retryAfter {
                guard retryAfter <= policy.maxRetryAfterSeconds else { throw failure }
                delay = retryAfter
            } else {
                delay = policy.backoff(afterAttempt: attempt)
            }
            try await sleep(.milliseconds(Int64(delay * 1000)))
        }
    }

    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
              let seconds = Double(value), seconds >= 0 else { return nil }
        return seconds
    }
}
