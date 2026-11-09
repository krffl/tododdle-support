// A minimal SwiftUI app that uses TododdleSupport. See README.md in this folder to run it.
import SwiftUI
import TododdleSupport
#if canImport(UIKit)
import UIKit
#endif

// Use your project's public key from ToDoddle > Support > SDK keys. A test key (`tdsk_test_…`)
// marks its tickets as test reports.
private let support = TododdleSupport(configuration: .init(
    key: "tdsk_test_REPLACEWITHYOURKEY00000000000000",
    offlineQueue: true
))

@main
struct ExampleApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tododdleSupport(support)
        }
        .onChange(of: scenePhase) { phase in
            // Send any reports saved while offline.
            if phase == .active {
                Task { await support.flushQueue() }
            }
        }
    }
}

struct ContentView: View {
    @State private var showReport = false
    @State private var offeredScreenshot: ReportAttachment?
    @State private var lastReference: String?
    @State private var headlessResult: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Sheet") {
                    Button("Report a problem") {
                        // Capture before the sheet covers the screen. It is attached only if the
                        // person taps "Add screenshot".
                        offeredScreenshot = captureScreen()
                        showReport = true
                    }
                    if let lastReference {
                        LabeledContent("Last reference", value: lastReference)
                    }
                }
                Section("Headless") {
                    Button("Send a test report without UI") {
                        Task { await sendHeadless() }
                    }
                    if let headlessResult {
                        Text(headlessResult).font(.footnote)
                    }
                }
            }
            .navigationTitle("Support example")
        }
        .tododdleReportSheet(
            isPresented: $showReport,
            offeredScreenshot: offeredScreenshot,
            context: ReportContext(screen: "Home", extra: ["plan": "free"]),
            reporter: Reporter(customerReference: "user-42")
        ) { receipt in
            lastReference = receipt?.reportId ?? (receipt == nil ? lastReference : "Queued")
        }
    }

    private func sendHeadless() async {
        do {
            let config = try await support.config()
            let report = Report(
                type: config.form.types.first?.value ?? .problem,
                description: "Test report from the example app.",
                fields: Dictionary(uniqueKeysWithValues: config.form.fields.filter(\.required).map { field in
                    (field.key, field.options?.first ?? "Example")
                })
            )
            let errors = support.validate(report, against: config)
            guard errors.isEmpty else {
                headlessResult = "Fix: \(errors)"
                return
            }
            let receipt = try await support.report(report, using: config)
            headlessResult = "Sent: \(receipt.reportId ?? "queued")"
        } catch let error as TododdleSupportError {
            headlessResult = "\(error.code) (\(error.httpStatus.map(String.init) ?? "no status")): \(error.message)"
        } catch {
            headlessResult = error.localizedDescription
        }
    }

    /// Renders the key window to PNG. Your app decides when to call this; the SDK never does.
    private func captureScreen() -> ReportAttachment? {
        #if canImport(UIKit)
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else { return nil }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        guard let png = image.pngData() else { return nil }
        return ScreenshotAttachment.make(from: png)
        #else
        return nil
        #endif
    }
}
