import PhotosUI
import SwiftUI

/// A ready-made report form built from the project's config.
///
/// It shows the report types, the title and description, the custom fields and an optional
/// "Add screenshot" button, themed with `config.theme`. Nothing is captured automatically: a
/// screenshot is attached only when the person taps the button, and they see a preview they can
/// remove.
///
/// ```swift
/// .sheet(isPresented: $showReport) {
///     ReportSheet(client: support, offeredScreenshot: lastScreenshot)
/// }
/// ```
public struct ReportSheet: View {
    /// The SDK's own wording. The config supplies the dialog title, labels and thank-you text;
    /// these cover the rest. Replace them to localise.
    public struct Strings: Sendable {
        public var cancel = "Cancel"
        public var done = "Done"
        public var retry = "Try again"
        public var loading = "Loading the form"
        public var loadFailed = "The report form could not load. Check your connection and try again."
        public var reportType = "Type"
        public var requiredMarker = "Required"
        public var choose = "Choose"
        public var addScreenshot = "Add screenshot"
        public var choosePhoto = "Choose from Photos"
        public var removeScreenshot = "Remove screenshot"
        public var screenshotPreview = "Screenshot preview"
        public var screenshotUnusable = "That image cannot be attached."
        public var checkFields = "Check the highlighted fields."
        public var formChanged = "The form has changed. Check it and send again."
        public var offline = "You seem to be offline. Try again when you are connected."
        public var sendFailed = "Your report could not be sent. Try again."
        public var queued = "You are offline. Your report will be sent when you are back online."
        public var reference = "Reference"

        public init() {}
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.tododdleSupport) private var environmentClient
    @StateObject private var model = ReportSheetModel()
    @State private var photoItem: PhotosPickerItem?

    private let explicitClient: TododdleSupport?
    private let offeredScreenshot: ReportAttachment?
    private let allowsPhotoPicker: Bool
    private let context: ReportContext?
    private let reporter: Reporter?
    private let strings: Strings
    private let onFinish: ((ReportReceipt?) -> Void)?

    /// - Parameters:
    ///   - client: The client to use. When `nil`, the sheet uses the one set with `.tododdleSupport(_:)`.
    ///   - offeredScreenshot: An image your app captured before showing the sheet. It is attached
    ///     only if the person taps "Add screenshot". Build it with ``ScreenshotAttachment/make(from:fileName:allowedContentTypes:maxBytes:)``.
    ///   - allowsPhotoPicker: Lets the person choose an image with the system photo picker.
    ///   - context: App context for the report, such as the screen name or `extra` values.
    ///   - reporter: Optional, unverified reporter details.
    ///   - strings: The SDK's own wording.
    ///   - onFinish: Called once with the receipt after sending, or `nil` if the person cancels.
    public init(
        client: TododdleSupport? = nil,
        offeredScreenshot: ReportAttachment? = nil,
        allowsPhotoPicker: Bool = true,
        context: ReportContext? = nil,
        reporter: Reporter? = nil,
        strings: Strings = Strings(),
        onFinish: ((ReportReceipt?) -> Void)? = nil
    ) {
        self.explicitClient = client
        self.offeredScreenshot = offeredScreenshot
        self.allowsPhotoPicker = allowsPhotoPicker
        self.context = context
        self.reporter = reporter
        self.strings = strings
        self.onFinish = onFinish
    }

    private var client: TododdleSupport? { explicitClient ?? environmentClient }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(model.config?.wording.dialogTitle ?? "")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { toolbar }
        }
        .tint(theme.flatMap { Color(hex: $0.accent) })
        .task {
            guard let client else {
                model.phase = .failed(strings.loadFailed)
                return
            }
            await model.load(client: client, strings: strings)
        }
        .task(id: photoItem) { await loadPhoto() }
        .interactiveDismissDisabled(model.isSubmitting)
    }

    private var theme: SupportConfig.Theme? { model.config?.theme }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        switch model.phase {
        case .done:
            ToolbarItem(placement: .confirmationAction) {
                Button(strings.done) { finish(sent: true) }
            }
        default:
            ToolbarItem(placement: .cancellationAction) {
                Button(strings.cancel) { finish(sent: false) }
                    .disabled(model.isSubmitting)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView(strings.loading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 16) {
                Text(message)
                    .multilineTextAlignment(.center)
                if client != nil {
                    Button(strings.retry) {
                        Task { if let client { await model.load(client: client, strings: strings) } }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .form(let config):
            form(config)
        case .done(let config, let receipt):
            thankYou(config, receipt: receipt)
        }
    }

    // MARK: Form

    private func form(_ config: SupportConfig) -> some View {
        Form {
            if let intro = config.wording.intro, !intro.isEmpty {
                Section { Text(intro).foregroundStyle(.secondary) }
            }

            if config.form.types.count > 1 {
                Section {
                    Picker(strings.reportType, selection: $model.type) {
                        ForEach(config.form.types, id: \.value) { option in
                            Text(option.label).tag(Optional(option.value))
                        }
                    }
                    errorText("type")
                }
            }

            Section {
                if let spec = config.form.title, spec.enabled {
                    labelled(spec.label, required: spec.required, key: "title") {
                        TextField(spec.label, text: $model.title)
                            .limit($model.title, to: spec.maxLength ?? 160)
                    }
                }
                let description = config.form.description
                labelled(description?.label ?? "Description", required: description?.required ?? false, key: "description") {
                    TextField(description?.placeholder ?? "", text: $model.description, axis: .vertical)
                        .lineLimit(4...12)
                        .limit($model.description, to: description?.maxLength ?? 10_000)
                }
            }

            if !config.form.fields.isEmpty {
                Section {
                    ForEach(config.form.fields) { field in
                        fieldView(field)
                    }
                }
            }

            if showsScreenshotSection(config) {
                screenshotSection(config)
            }

            Section {
                submitButton(config)
                if let error = model.submitError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .disabled(model.isSubmitting)
    }

    @ViewBuilder
    private func fieldView(_ field: FieldDefinition) -> some View {
        labelled(field.label, required: field.required, key: field.key) {
            switch field.type {
            case .select:
                Picker(field.label, selection: model.binding(for: field.key)) {
                    Text(strings.choose).tag("")
                    ForEach(field.options ?? [], id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .labelsHidden()
            case .longText:
                TextField(field.label, text: model.binding(for: field.key), axis: .vertical)
                    .lineLimit(3...10)
                    .limit(model.binding(for: field.key), to: field.effectiveMaxLength)
            default:
                TextField(field.label, text: model.binding(for: field.key))
                    .limit(model.binding(for: field.key), to: field.effectiveMaxLength)
            }
        }
    }

    /// A visible label above the control, the control itself, and any error under it.
    private func labelled<Control: View>(
        _ label: String,
        required: Bool,
        key: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(label).font(.subheadline.weight(.semibold))
                if required {
                    Text("*").foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
            .accessibilityHidden(true)
            control()
                .accessibilityLabel(required ? "\(label), \(strings.requiredMarker)" : label)
                .accessibilityHint(model.fieldErrors[key] ?? "")
            errorText(key)
        }
    }

    @ViewBuilder
    private func errorText(_ key: String) -> some View {
        if let message = model.fieldErrors[key] {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityLabel(message)
        }
    }

    // MARK: Screenshot

    private func showsScreenshotSection(_ config: SupportConfig) -> Bool {
        let rules = config.form.attachments
        let imagesAllowed = rules.contentTypes.contains { $0.hasPrefix("image/") }
        return rules.enabled && rules.maxCount > 0 && imagesAllowed && (offeredScreenshot != nil || allowsPhotoPicker || model.screenshot != nil)
    }

    private func screenshotSection(_ config: SupportConfig) -> some View {
        Section {
            if let preview = model.screenshotPreview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 240)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius(config.theme)))
                    .accessibilityElement()
                    .accessibilityLabel(strings.screenshotPreview)
                    .accessibilityAddTraits(.isImage)
                Button(role: .destructive) {
                    model.setScreenshot(nil)
                    photoItem = nil
                } label: {
                    Label(strings.removeScreenshot, systemImage: "trash")
                }
            } else {
                if let offeredScreenshot {
                    Button {
                        model.setScreenshot(offeredScreenshot)
                    } label: {
                        Label(strings.addScreenshot, systemImage: "camera.viewfinder")
                    }
                }
                if allowsPhotoPicker {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(offeredScreenshot == nil ? strings.addScreenshot : strings.choosePhoto, systemImage: "photo")
                    }
                }
            }
            errorText("attachments")
        }
    }

    private func loadPhoto() async {
        guard let photoItem, let config = model.config else { return }
        let rules = config.form.attachments
        guard let data = try? await photoItem.loadTransferable(type: Data.self),
              let attachment = ScreenshotAttachment.make(
                from: data,
                fileName: "photo",
                allowedContentTypes: rules.contentTypes,
                maxBytes: rules.maxBytes
              ) else {
            model.fieldErrors["attachments"] = strings.screenshotUnusable
            return
        }
        model.setScreenshot(attachment)
    }

    // MARK: Submit and thank you

    private func submitButton(_ config: SupportConfig) -> some View {
        Button {
            guard let client else { return }
            Task { await model.submit(client: client, context: context, reporter: reporter, strings: strings) }
        } label: {
            HStack {
                Spacer()
                if model.isSubmitting {
                    ProgressView().tint(Color(hex: config.theme.onAccent))
                } else {
                    Text(config.wording.submitLabel).font(.headline)
                }
                Spacer()
            }
            .padding(.vertical, 12)
            .foregroundStyle(Color(hex: config.theme.onAccent) ?? .white)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius(config.theme))
                    .fill(Color(hex: config.theme.accent) ?? .accentColor)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .accessibilityLabel(config.wording.submitLabel)
    }

    private func thankYou(_ config: SupportConfig, receipt: ReportReceipt) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: receipt.status == .queued ? "tray.and.arrow.up" : "checkmark.circle.fill")
                    .font(.system(.largeTitle))
                    .foregroundStyle(Color(hex: config.theme.accent) ?? .accentColor)
                    .accessibilityHidden(true)
                Text(config.wording.thankYouTitle)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(config.wording.thankYouMessage)
                    .multilineTextAlignment(.center)
                if receipt.status == .queued {
                    Text(strings.queued)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if let reportId = receipt.reportId {
                    Text("\(strings.reference): \(reportId)")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private func finish(sent: Bool) {
        if case .done(_, let receipt) = model.phase {
            onFinish?(receipt)
        } else {
            onFinish?(nil)
        }
        dismiss()
    }

    private func cornerRadius(_ theme: SupportConfig.Theme) -> CGFloat {
        theme.corners == "square" ? 0 : 10
    }
}

// MARK: - Presentation helpers

private struct TododdleSupportKey: EnvironmentKey {
    static let defaultValue: TododdleSupport? = nil
}

extension EnvironmentValues {
    /// The client ``ReportSheet`` uses when none is passed to it.
    public var tododdleSupport: TododdleSupport? {
        get { self[TododdleSupportKey.self] }
        set { self[TododdleSupportKey.self] = newValue }
    }
}

extension View {
    /// Makes `client` available to every ``ReportSheet`` below this view.
    public func tododdleSupport(_ client: TododdleSupport) -> some View {
        environment(\.tododdleSupport, client)
    }

    /// Presents a ``ReportSheet`` while `isPresented` is true.
    ///
    /// The client comes from `client`, or from `.tododdleSupport(_:)` higher in the view tree.
    public func tododdleReportSheet(
        isPresented: Binding<Bool>,
        client: TododdleSupport? = nil,
        offeredScreenshot: ReportAttachment? = nil,
        allowsPhotoPicker: Bool = true,
        context: ReportContext? = nil,
        reporter: Reporter? = nil,
        strings: ReportSheet.Strings = ReportSheet.Strings(),
        onFinish: ((ReportReceipt?) -> Void)? = nil
    ) -> some View {
        sheet(isPresented: isPresented) {
            ReportSheet(
                client: client,
                offeredScreenshot: offeredScreenshot,
                allowsPhotoPicker: allowsPhotoPicker,
                context: context,
                reporter: reporter,
                strings: strings,
                onFinish: onFinish
            )
        }
    }
}

extension Color {
    /// Parses `#rrggbb`. Returns `nil` for anything else.
    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}

private extension View {
    /// Stops a text binding from growing past the contract's limit.
    func limit(_ text: Binding<String>, to length: Int) -> some View {
        onChange(of: text.wrappedValue) { newValue in
            if newValue.count > length {
                text.wrappedValue = String(newValue.prefix(length))
            }
        }
    }
}
