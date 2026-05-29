import AppKit
import Foundation

/// Tracks the frontmost app's bundle ID and emits an `.appSwitch` row each
/// time it changes. The current value is exposed as a lock-free read so the
/// CGEventTap C callback can stamp it onto outgoing rows without an `await`.
@MainActor
final class FrontmostAppMonitor {
    /// Latest frontmost bundle ID. `nil` when no app is frontmost (rare —
    /// loginwindow/screensaver/uncapturable scenarios).
    ///
    /// Marked `nonisolated(unsafe)` because the C tap callback reads this on
    /// the main run loop without going through actor isolation. The write
    /// side is main-actor-bound (NSWorkspace notifications post to the main
    /// queue), so the invariant holds: single writer, callback-thread reader
    /// on the same run loop = no torn reads on a pointer-sized property.
    nonisolated(unsafe) private(set) var currentBundleID: String?

    /// Called every time the frontmost app changes. The closure receives the
    /// (previous, next) pair. Set by `EventStreamViewModel` to emit
    /// `.appSwitch` rows.
    var onSwitch: ((_ from: String?, _ to: String?) -> Void)?

    private var observation: NSKeyValueObservation?

    init() {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        self.currentBundleID = Self.normalize(frontmost)
    }

    func start() {
        guard observation == nil else { return }
        // KVO on `frontmostApplication` is the reliable signal.
        // `NSWorkspace.didActivateApplicationNotification` drops activations
        // intermittently in modern macOS (Sonoma/Sequoia), especially for
        // `.accessory`-policy observers — which left the bundleID stuck on
        // whichever app happened to be frontmost when the last notification
        // arrived, mis-stamping every subsequent CGEvent.
        observation = NSWorkspace.shared.observe(\.frontmostApplication, options: [.new]) { [weak self] _, change in
            // Pull only Sendable values out of the change before hopping
            // into MainActor isolation. KVO callbacks can fire off-main.
            let bundleID = change.newValue??.bundleIdentifier
            Task { @MainActor [weak self] in
                guard let self else { return }
                let next = Self.normalize(bundleID)
                let previous = self.currentBundleID
                self.currentBundleID = next
                if previous != next {
                    self.onSwitch?(previous, next)
                }
            }
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
    }

    /// Maps known "uncapturable" frontmost states to nil. Loginwindow and
    /// screensaver routinely become frontmost during system events; stamping
    /// rows with them is noise.
    private static func normalize(_ bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        switch bundleID {
        case "com.apple.loginwindow",
             "com.apple.ScreenSaver.Engine",
             "com.apple.screensaver.engine":
            return nil
        default:
            return bundleID
        }
    }
}
