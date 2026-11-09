import Foundation

// MARK: - Open string enums

/// A report type. The contract may add values inside v1, so unknown values decode without error.
public struct ReportType: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let problem: ReportType = "problem"
    public static let feedback: ReportType = "feedback"
    public static let question: ReportType = "question"
}

/// The kind of a custom form field. Unknown kinds decode without error; the sheet shows them as short text.
public struct FieldType: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let shortText: FieldType = "SHORT_TEXT"
    public static let longText: FieldType = "LONG_TEXT"
    public static let select: FieldType = "SELECT"
}

// MARK: - Config

/// The report form, wording and branding from `GET /config`.
public struct SupportConfig: Codable, Sendable, Equatable {
    public var project: Project
    public var form: Form
    public var wording: Wording
    public var theme: Theme

    public init(project: Project, form: Form, wording: Wording, theme: Theme) {
        self.project = project
        self.form = form
        self.wording = wording
        self.theme = theme
    }

    public struct Project: Codable, Sendable, Equatable {
        public var name: String
        /// Kept as a string so a bad URL does not break the whole config. See ``logoURL``.
        public var logoUrl: String?

        public var logoURL: URL? { logoUrl.flatMap(URL.init(string:)) }

        public init(name: String, logoUrl: String? = nil) {
            self.name = name
            self.logoUrl = logoUrl
        }
    }

    public struct Form: Codable, Sendable, Equatable {
        /// Send it back as `formVersion`.
        public var version: Int
        public var types: [TypeOption]
        public var title: TitleSpec?
        public var description: DescriptionSpec?
        public var fields: [FieldDefinition]
        public var attachments: AttachmentRules

        public init(
            version: Int,
            types: [TypeOption],
            title: TitleSpec? = nil,
            description: DescriptionSpec? = nil,
            fields: [FieldDefinition] = [],
            attachments: AttachmentRules
        ) {
            self.version = version
            self.types = types
            self.title = title
            self.description = description
            self.fields = fields
            self.attachments = attachments
        }
    }

    public struct TypeOption: Codable, Sendable, Equatable, Hashable {
        public var value: ReportType
        public var label: String

        public init(value: ReportType, label: String) {
            self.value = value
            self.label = label
        }
    }

    public struct TitleSpec: Codable, Sendable, Equatable {
        public var enabled: Bool
        public var required: Bool
        public var label: String
        public var maxLength: Int?

        public init(enabled: Bool, required: Bool, label: String, maxLength: Int? = 160) {
            self.enabled = enabled
            self.required = required
            self.label = label
            self.maxLength = maxLength
        }
    }

    public struct DescriptionSpec: Codable, Sendable, Equatable {
        public var required: Bool
        public var label: String
        public var placeholder: String?
        public var maxLength: Int?

        public init(required: Bool, label: String, placeholder: String? = nil, maxLength: Int? = 10_000) {
            self.required = required
            self.label = label
            self.placeholder = placeholder
            self.maxLength = maxLength
        }
    }

    public struct AttachmentRules: Codable, Sendable, Equatable {
        public var enabled: Bool
        public var maxCount: Int
        /// Per file.
        public var maxBytes: Int
        public var contentTypes: [String]

        public init(enabled: Bool, maxCount: Int, maxBytes: Int, contentTypes: [String]) {
            self.enabled = enabled
            self.maxCount = maxCount
            self.maxBytes = maxBytes
            self.contentTypes = contentTypes
        }
    }

    public struct Wording: Codable, Sendable, Equatable {
        public var dialogTitle: String
        public var intro: String?
        public var submitLabel: String
        public var thankYouTitle: String
        public var thankYouMessage: String

        public init(dialogTitle: String, intro: String? = nil, submitLabel: String, thankYouTitle: String, thankYouMessage: String) {
            self.dialogTitle = dialogTitle
            self.intro = intro
            self.submitLabel = submitLabel
            self.thankYouTitle = thankYouTitle
            self.thankYouMessage = thankYouMessage
        }
    }

    public struct Theme: Codable, Sendable, Equatable {
        /// `#rrggbb`.
        public var accent: String
        /// `#rrggbb`, readable on ``accent``.
        public var onAccent: String
        /// `rounded` or `square`.
        public var corners: String
        /// A portal font id. The SDK uses the app font and ignores it.
        public var headingFont: String?

        public init(accent: String, onAccent: String, corners: String, headingFont: String? = nil) {
            self.accent = accent
            self.onAccent = onAccent
            self.corners = corners
            self.headingFont = headingFont
        }
    }
}

/// A custom field on the report form.
public struct FieldDefinition: Codable, Sendable, Equatable, Identifiable {
    public var key: String
    public var label: String
    public var type: FieldType
    public var required: Bool
    /// For ``FieldType/select`` only.
    public var options: [String]?
    public var maxLength: Int?

    public var id: String { key }

    public init(key: String, label: String, type: FieldType, required: Bool, options: [String]? = nil, maxLength: Int? = nil) {
        self.key = key
        self.label = label
        self.type = type
        self.required = required
        self.options = options
        self.maxLength = maxLength
    }

    /// The limit to apply: the config's value, or the contract default for the field type.
    public var effectiveMaxLength: Int {
        if let maxLength { return maxLength }
        return type == .longText ? 5_000 : 300
    }
}

// MARK: - Report input

/// One report, as the app or the ``ReportSheet`` builds it.
public struct Report: Sendable, Equatable {
    public var type: ReportType
    public var title: String?
    public var description: String?
    /// Values by field key: text, or one of the options for a select field.
    public var fields: [String: String]
    /// App-supplied context. It overrides the automatic context key by key.
    public var context: ReportContext?
    /// Optional and unverified. ToDoddle never emails the reporter.
    public var reporter: Reporter?
    /// Files the person chose and previewed. At most five.
    public var attachments: [ReportAttachment]

    public init(
        type: ReportType,
        title: String? = nil,
        description: String? = nil,
        fields: [String: String] = [:],
        context: ReportContext? = nil,
        reporter: Reporter? = nil,
        attachments: [ReportAttachment] = []
    ) {
        self.type = type
        self.title = title
        self.description = description
        self.fields = fields
        self.context = context
        self.reporter = reporter
        self.attachments = attachments
    }
}

/// A file the person chose to send with a report.
public struct ReportAttachment: Codable, Sendable, Equatable {
    public var fileName: String
    /// One of the config's `attachments.contentTypes`, for example `image/png`.
    public var contentType: String
    public var data: Data

    public init(fileName: String, contentType: String, data: Data) {
        self.fileName = fileName
        self.contentType = contentType
        self.data = data
    }
}

/// Facts about the app and device. All optional. Never put URL query strings or personal data here.
public struct ReportContext: Codable, Sendable, Equatable {
    public var platform: String?
    public var appVersion: String?
    public var build: String?
    public var osName: String?
    public var osVersion: String?
    public var deviceModel: String?
    public var locale: String?
    /// Screen or route name, without a query string.
    public var screen: String?
    /// App-defined key/value context, shown on the ticket as is. Up to 20 keys.
    public var extra: [String: String]?

    public init(
        platform: String? = nil,
        appVersion: String? = nil,
        build: String? = nil,
        osName: String? = nil,
        osVersion: String? = nil,
        deviceModel: String? = nil,
        locale: String? = nil,
        screen: String? = nil,
        extra: [String: String]? = nil
    ) {
        self.platform = platform
        self.appVersion = appVersion
        self.build = build
        self.osName = osName
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.locale = locale
        self.screen = screen
        self.extra = extra
    }
}

/// Optional, unverified reporter details. ToDoddle never emails this address.
public struct Reporter: Codable, Sendable, Equatable {
    public var name: String?
    public var email: String?
    /// The app's own user or account ID.
    public var customerReference: String?

    public init(name: String? = nil, email: String? = nil, customerReference: String? = nil) {
        self.name = name
        self.email = email
        self.customerReference = customerReference
    }
}

/// The result of ``TododdleSupport/report(_:using:)``.
public struct ReportReceipt: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        /// ToDoddle has the report.
        case received
        /// The device was offline. The report is saved and goes with the next ``TododdleSupport/flushQueue()``.
        case queued
    }

    /// The reference to show, for example `rpt_…`. `nil` while queued.
    public let reportId: String?
    public let status: Status
    /// The key sent on every attempt for this report.
    public let idempotencyKey: String

    public init(reportId: String?, status: Status, idempotencyKey: String) {
        self.reportId = reportId
        self.status = status
        self.idempotencyKey = idempotencyKey
    }
}

// MARK: - Wire types

struct ReportRequest: Codable, Sendable, Equatable {
    var idempotencyKey: String
    var type: ReportType
    var formVersion: Int
    var title: String?
    var description: String?
    var fields: [String: String]?
    var context: ReportContext?
    var reporter: Reporter?
    var attachments: [AttachmentDeclaration]?

    struct AttachmentDeclaration: Codable, Sendable, Equatable {
        var fileName: String
        var contentType: String
        var size: Int
    }
}

struct SubmitRequest: Encodable {
    var submitToken: String
}

struct ReportResponse: Decodable, Sendable {
    var reportId: String
    var status: String
    var submitToken: String?
    var expiresAt: String?
    var uploads: [Upload]?

    struct Upload: Decodable, Sendable {
        var uploadUrl: String
        var headers: [String: String]
        var expiresAt: String
    }

    static let received = "received"
    static let awaitingUploads = "awaiting_uploads"
}
