import Foundation

/// Every failure from the SDK.
///
/// `code` is the server's stable code when there is one. The server may add codes inside v1, so
/// handle an unknown code by its ``httpStatus``. Codes the SDK makes itself (``Code/networkError``,
/// ``Code/invalidResponse``, ``Code/httpError``) have no `httpStatus` or the status that caused them.
public struct TododdleSupportError: Error, Sendable, Equatable, LocalizedError {
    public struct Code: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.rawValue = value }
        public var description: String { rawValue }

        // Server codes from the v1 contract.
        public static let invalidRequest: Code = "INVALID_REQUEST"
        public static let invalidKey: Code = "INVALID_KEY"
        public static let keyRevoked: Code = "KEY_REVOKED"
        public static let originNotAllowed: Code = "ORIGIN_NOT_ALLOWED"
        public static let appNotAllowed: Code = "APP_NOT_ALLOWED"
        public static let supportUnavailable: Code = "SUPPORT_UNAVAILABLE"
        public static let invalidFields: Code = "INVALID_FIELDS"
        public static let fieldsChanged: Code = "FIELDS_CHANGED"
        public static let payloadTooLarge: Code = "PAYLOAD_TOO_LARGE"
        public static let tooManyAttachments: Code = "TOO_MANY_ATTACHMENTS"
        public static let attachmentTypeNotAllowed: Code = "ATTACHMENT_TYPE_NOT_ALLOWED"
        public static let idempotencyKeyReused: Code = "IDEMPOTENCY_KEY_REUSED"
        public static let attachmentsNotReady: Code = "ATTACHMENTS_NOT_READY"
        public static let reportNotFound: Code = "REPORT_NOT_FOUND"
        public static let reportExpired: Code = "REPORT_EXPIRED"
        public static let rateLimited: Code = "RATE_LIMITED"

        // SDK codes.
        /// The request did not reach the server, or no response came back.
        public static let networkError: Code = "NETWORK_ERROR"
        /// The server answered with something the SDK could not read.
        public static let invalidResponse: Code = "INVALID_RESPONSE"
        /// An error status without a readable error body.
        public static let httpError: Code = "HTTP_ERROR"
    }

    public let code: Code
    /// The HTTP status, or `nil` when the error happened before a response (network or local validation).
    public let httpStatus: Int?
    /// Plain English, safe to log. Show your own wording to people.
    public let message: String
    /// For ``Code/invalidFields`` and ``Code/fieldsChanged``: a message per field key.
    public let fields: [String: String]
    public let requestId: String?
    /// Seconds from `Retry-After`, when the server sent it.
    public let retryAfter: TimeInterval?

    public init(
        code: Code,
        httpStatus: Int? = nil,
        message: String,
        fields: [String: String] = [:],
        requestId: String? = nil,
        retryAfter: TimeInterval? = nil
    ) {
        self.code = code
        self.httpStatus = httpStatus
        self.message = message
        self.fields = fields
        self.requestId = requestId
        self.retryAfter = retryAfter
    }

    public var errorDescription: String? { message }

    /// True for network errors and the statuses the retry policy retries (408, 429, 5xx in the list).
    public var isTransient: Bool {
        if code == .networkError { return true }
        guard let httpStatus else { return false }
        return RetryPolicy.standard.retryStatuses.contains(httpStatus)
    }
}

extension TododdleSupportError {
    private struct Envelope: Decodable {
        struct Body: Decodable {
            var code: String
            var message: String
            var fields: [String: String]?
            var requestId: String?
        }
        var error: Body
    }

    /// Builds an error from a non-success response. Unknown codes are kept as they are.
    static func from(status: Int, data: Data, retryAfter: TimeInterval?) -> TododdleSupportError {
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            return TododdleSupportError(
                code: Code(rawValue: envelope.error.code),
                httpStatus: status,
                message: envelope.error.message,
                fields: envelope.error.fields ?? [:],
                requestId: envelope.error.requestId,
                retryAfter: retryAfter
            )
        }
        return TododdleSupportError(
            code: status == 429 ? .rateLimited : .httpError,
            httpStatus: status,
            message: "The server answered with HTTP \(status).",
            retryAfter: retryAfter
        )
    }

    static func network(_ error: Error) -> TododdleSupportError {
        TododdleSupportError(code: .networkError, message: "The request did not complete: \(error.localizedDescription)")
    }

    static func invalidResponse(_ detail: String, status: Int? = nil) -> TododdleSupportError {
        TododdleSupportError(code: .invalidResponse, httpStatus: status, message: detail)
    }
}
