import CoreGraphics
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The state behind ``ReportSheet``.
@MainActor
final class ReportSheetModel: ObservableObject {
    enum Phase {
        case loading
        case failed(String)
        case form(SupportConfig)
        case done(SupportConfig, ReportReceipt)
    }

    @Published var phase: Phase = .loading
    @Published var type: ReportType?
    @Published var title = ""
    @Published var description = ""
    @Published var fieldValues: [String: String] = [:]
    @Published var screenshot: ReportAttachment?
    @Published var screenshotPreview: CGImage?
    @Published var fieldErrors: [String: String] = [:]
    @Published var submitError: String?
    @Published var isSubmitting = false

    private var loadedVersion: Int?

    var config: SupportConfig? {
        switch phase {
        case .form(let config), .done(let config, _): return config
        case .loading, .failed: return nil
        }
    }

    func load(client: TododdleSupport, strings: ReportSheet.Strings, forceRefresh: Bool = false) async {
        if config == nil { phase = .loading }
        do {
            let config: SupportConfig
            if !forceRefresh, let cached = await client.cachedConfig {
                // Show the form straight away, then refresh it quietly.
                apply(cached)
                config = (try? await client.config()) ?? cached
            } else {
                config = try await client.config(forceRefresh: forceRefresh)
            }
            apply(config)
        } catch {
            if self.config == nil { phase = .failed(strings.loadFailed) }
        }
    }

    private func apply(_ config: SupportConfig) {
        if case .done = phase { return }
        phase = .form(config)
        if type == nil || !config.form.types.contains(where: { $0.value == type }) {
            type = config.form.types.first?.value
        }
        if loadedVersion != config.form.version {
            loadedVersion = config.form.version
            let keys = Set(config.form.fields.map(\.key))
            fieldValues = fieldValues.filter { keys.contains($0.key) }
        }
    }

    func binding(for key: String) -> Binding<String> {
        Binding(get: { self.fieldValues[key] ?? "" }, set: { self.fieldValues[key] = $0 })
    }

    func setScreenshot(_ attachment: ReportAttachment?) {
        screenshot = attachment
        screenshotPreview = attachment.flatMap { ScreenshotAttachment.previewImage($0.data) }
        fieldErrors["attachments"] = nil
    }

    func makeReport(context: ReportContext?, reporter: Reporter?) -> Report? {
        guard let type else { return nil }
        return Report(
            type: type,
            title: title,
            description: description,
            fields: fieldValues,
            context: context,
            reporter: reporter,
            attachments: screenshot.map { [$0] } ?? []
        )
    }

    func submit(client: TododdleSupport, context: ReportContext?, reporter: Reporter?, strings: ReportSheet.Strings) async {
        guard case .form(let config) = phase, let report = makeReport(context: context, reporter: reporter) else { return }
        submitError = nil
        fieldErrors = ReportValidator.validate(report, against: config)
        guard fieldErrors.isEmpty else {
            announce(strings.checkFields)
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let receipt = try await client.report(report, using: config)
            phase = .done(config, receipt)
            announce(config.wording.thankYouTitle)
        } catch let error as TododdleSupportError {
            switch error.code {
            case .invalidFields:
                fieldErrors = error.fields
                submitError = strings.checkFields
            case .fieldsChanged:
                fieldErrors = error.fields
                submitError = strings.formChanged
                await load(client: client, strings: strings, forceRefresh: true)
            case .networkError:
                submitError = strings.offline
            default:
                submitError = strings.sendFailed
            }
            announce(submitError ?? strings.sendFailed)
        } catch {
            submitError = strings.sendFailed
        }
    }

    private func announce(_ message: String) {
        #if canImport(UIKit) && !os(watchOS)
        UIAccessibility.post(notification: .announcement, argument: message)
        #endif
    }
}
