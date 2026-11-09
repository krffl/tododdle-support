import Foundation

/// Checks a report against the config before it is sent, the same way the server does.
///
/// The result maps a key to a message: `type`, `title`, `description`, `attachments`, or a custom
/// field key. An empty result means the report is valid. The server still has the final word.
public enum ReportValidator {
    public static func validate(_ report: Report, against config: SupportConfig) -> [String: String] {
        var errors: [String: String] = [:]
        let form = config.form

        if !form.types.contains(where: { $0.value == report.type }) {
            errors["type"] = "Choose a report type."
        }

        let title = report.title?.trimmedOrNil
        if let spec = form.title, spec.enabled {
            if spec.required, title == nil {
                errors["title"] = "\(spec.label) is required."
            } else if let title, title.count > (spec.maxLength ?? 160) {
                errors["title"] = "\(spec.label) must be \(spec.maxLength ?? 160) characters or fewer."
            }
        }

        let description = report.description?.trimmedOrNil
        let descriptionSpec = form.description
        let descriptionLabel = descriptionSpec?.label ?? "Description"
        if descriptionSpec?.required == true, description == nil {
            errors["description"] = "\(descriptionLabel) is required."
        } else if let description, description.count > (descriptionSpec?.maxLength ?? 10_000) {
            errors["description"] = "\(descriptionLabel) must be \(descriptionSpec?.maxLength ?? 10_000) characters or fewer."
        }

        for field in form.fields {
            let value = report.fields[field.key]?.trimmedOrNil
            guard let value else {
                if field.required { errors[field.key] = "\(field.label) is required." }
                continue
            }
            if field.type == .select, let options = field.options, !options.contains(value) {
                errors[field.key] = "Choose one of the options for \(field.label)."
            } else if value.count > field.effectiveMaxLength {
                errors[field.key] = "\(field.label) must be \(field.effectiveMaxLength) characters or fewer."
            }
        }

        if let message = attachmentError(report.attachments, rules: form.attachments) {
            errors["attachments"] = message
        }
        return errors
    }

    static func attachmentError(_ attachments: [ReportAttachment], rules: SupportConfig.AttachmentRules) -> String? {
        guard !attachments.isEmpty else { return nil }
        guard rules.enabled else { return "This form does not accept attachments." }
        if attachments.count > min(rules.maxCount, 5) {
            return "Attach \(min(rules.maxCount, 5)) files or fewer."
        }
        for attachment in attachments {
            if attachment.data.isEmpty { return "\(attachment.fileName) is empty." }
            if attachment.data.count > rules.maxBytes {
                return "\(attachment.fileName) is too large."
            }
            if !rules.contentTypes.contains(attachment.contentType) {
                return "\(attachment.fileName) is a file type this form does not accept."
            }
            if attachment.fileName.isEmpty || attachment.fileName.count > 255 {
                return "Attachment file names must be 1 to 255 characters."
            }
        }
        return nil
    }
}

extension String {
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func truncated(to length: Int) -> String {
        count > length ? String(prefix(length)) : self
    }
}
