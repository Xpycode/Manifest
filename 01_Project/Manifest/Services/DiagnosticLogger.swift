import Foundation
import os

/// Operational logging for the app itself — distinct from `EventStore`, which
/// persists the *product data* (captured input events). This records the app's
/// own *state*: TCC trust, tap lifecycle, when the system disables our tap,
/// persistence/export failures. The things you need when a user says "it
/// stopped capturing" and there's no crash to look at.
///
/// Writes to two places:
/// 1. The unified logging system (`os.Logger`) — visible live in Console.app or
///    `log stream --predicate 'subsystem == "com.lucesumbrarum.Manifest"'`.
/// 2. A plain-text file at `~/Library/Application Support/Manifest/diagnostic.log`
///    — so a user can attach it to a bug report without touching Console.
///
/// Privacy: we deliberately log *state*, never event payloads — no keystrokes,
/// no clicked element titles, no app names from the captured stream. Everything
/// here is safe to mark `.public` so it's actually readable in Console.
///
/// Thread-safe: file writes are serialized on a private queue and the
/// `os.Logger` is `Sendable`, so `log` is safe to call from the MainActor, the
/// `EventStore` actor, and the nonisolated `CGEventTap` callback alike. Hence
/// `@unchecked Sendable` — the unchecked invariant is "all mutable file access
/// goes through `queue`."
final class DiagnosticLogger: @unchecked Sendable {
    static let shared = DiagnosticLogger()

    enum Level: String { case info = "INFO", warn = "WARN", error = "ERROR" }

    /// Location of the on-disk log, exposed so the UI can reveal it in Finder.
    /// `nil` only if Application Support couldn't be resolved (effectively never).
    let fileURL: URL?

    private let osLog = Logger(subsystem: "com.lucesumbrarum.Manifest", category: "diagnostic")
    private let queue = DispatchQueue(label: "com.lucesumbrarum.Manifest.diagnostic", qos: .utility)
    /// Confined to `queue` — `ISO8601DateFormatter` isn't thread-safe.
    private let iso = ISO8601DateFormatter()

    private init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Manifest", isDirectory: true)
        if let support {
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        }
        self.fileURL = support?.appendingPathComponent("diagnostic.log")
    }

    /// Log a message plus optional structured state. State is rendered as
    /// `key=value` pairs, sorted for stable output. Example:
    /// `log("capture started", state: ["axTrusted": "true"])`.
    func log(_ message: String, level: Level = .info, state: [String: String] = [:]) {
        let stateStr = state.isEmpty
            ? ""
            : " | " + state.map { "\($0)=\($1)" }.sorted().joined(separator: " ")
        let combined = message + stateStr

        switch level {
        case .info:  osLog.info("\(combined, privacy: .public)")
        case .warn:  osLog.warning("\(combined, privacy: .public)")
        case .error: osLog.error("\(combined, privacy: .public)")
        }

        guard let fileURL else { return }
        let levelTag = level.rawValue
        queue.async {
            let line = "[\(self.iso.string(from: Date()))] [\(levelTag)] \(combined)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                // File doesn't exist yet (or was deleted) — create it.
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
}
