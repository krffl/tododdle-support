import Foundation

/// The context the SDK fills in by itself: app version and build, OS name and version, device
/// model and locale. Nothing else is collected automatically.
enum DeviceContext {
    static func automatic(bundle: Bundle = .main) -> ReportContext {
        let info = bundle.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var osVersion = "\(os.majorVersion).\(os.minorVersion)"
        if os.patchVersion > 0 { osVersion += ".\(os.patchVersion)" }

        return ReportContext(
            platform: platform,
            appVersion: (info["CFBundleShortVersionString"] as? String)?.truncated(to: 50),
            build: (info["CFBundleVersion"] as? String)?.truncated(to: 50),
            osName: osName,
            osVersion: osVersion,
            deviceModel: deviceModel()?.truncated(to: 100),
            locale: Locale.current.identifier(.bcp47).truncated(to: 35)
        )
    }

    /// The contract's `platform` values have no entry for macOS, so a Mac build leaves it out.
    private static var platform: String? {
        #if os(iOS) || os(visionOS)
        return "ios"
        #else
        return nil
        #endif
    }

    private static var osName: String {
        #if targetEnvironment(macCatalyst)
        return "macOS"
        #elseif os(iOS)
        return "iOS"
        #elseif os(visionOS)
        return "visionOS"
        #elseif os(macOS)
        return "macOS"
        #else
        return "unknown"
        #endif
    }

    /// The hardware identifier, for example `iPhone16,1`. The simulator reports the model it simulates.
    private static func deviceModel() -> String? {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        #endif
        #if os(macOS) || targetEnvironment(macCatalyst)
        return sysctlString("hw.model")
        #else
        return sysctlString("hw.machine")
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Merges app context over automatic context and applies the contract's limits.
    static func merge(automatic: ReportContext?, app: ReportContext?) -> ReportContext? {
        guard automatic != nil || app != nil else { return nil }
        let a = automatic ?? ReportContext()
        let b = app ?? ReportContext()
        var extra: [String: String]?
        if let appExtra = b.extra, !appExtra.isEmpty {
            extra = Dictionary(uniqueKeysWithValues: appExtra.keys.sorted().prefix(20).map { key in
                (key, appExtra[key]!.truncated(to: 500))
            })
        }
        return ReportContext(
            platform: b.platform ?? a.platform,
            appVersion: (b.appVersion ?? a.appVersion)?.truncated(to: 50),
            build: (b.build ?? a.build)?.truncated(to: 50),
            osName: (b.osName ?? a.osName)?.truncated(to: 50),
            osVersion: (b.osVersion ?? a.osVersion)?.truncated(to: 50),
            deviceModel: (b.deviceModel ?? a.deviceModel)?.truncated(to: 100),
            locale: (b.locale ?? a.locale)?.truncated(to: 35),
            screen: (b.screen ?? a.screen).map(stripQuery)?.truncated(to: 200),
            extra: extra
        )
    }

    /// Screen names must never carry a query string or fragment.
    static func stripQuery(_ screen: String) -> String {
        String(screen.prefix { $0 != "?" && $0 != "#" })
    }
}
