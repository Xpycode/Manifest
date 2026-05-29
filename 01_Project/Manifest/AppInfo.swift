import Foundation

/// Marketing version + build number, read from the bundle's Info.plist.
/// XcodeGen injects these from `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`
/// (see `01_Project/project.yml`) via `GENERATE_INFOPLIST_FILE`. One source of
/// truth so the launch log and the Preferences footer always agree.
enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    static var displayName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Manifest"
    }

    /// e.g. `0.1.0 (1)` — for compact UI display.
    static var shortVersionString: String { "\(version) (\(build))" }

    /// e.g. `Manifest 0.1.0 (1)` — for the launch log line.
    static var fullVersionString: String { "\(displayName) \(version) (\(build))" }
}
