import AppKit
import Foundation

/// Resolves bundle IDs → "Safari", "Xcode" with caching.
/// Safe to call from the main thread; `NSRunningApplication` calls are
/// MainActor-isolated in practice.
@MainActor
final class AppDisplayNameLookup {
    private var cache: [String: String] = [:]

    func displayName(forBundleID bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        if let hit = cache[bundleID] { return hit }
        let name = resolve(bundleID: bundleID)
        cache[bundleID] = name
        return name
    }

    private func resolve(bundleID: String) -> String {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let localized = running.localizedName {
            return localized
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = url.deletingPathExtension().lastPathComponent
            if !name.isEmpty { return name }
        }
        // Last resort: bare bundle ID. Better than `nil` in a HUD.
        return bundleID
    }
}
