import Foundation

/// Persists events as append-only JSONL at
/// `~/Library/Application Support/Manifest/events-YYYY-MM-DD.jsonl`.
/// Crash-safe by virtue of being append-only; no in-memory buffer to lose.
///
/// The view model writes here on every event. File I/O is small (one line
/// per event), but if it ever shows up in a profile we can batch.
actor EventStore {
    private let directory: URL
    private let encoder: JSONEncoder
    private let dayFormatter: DateFormatter
    private var currentDay: String?
    private var currentHandle: FileHandle?

    init(directory: URL? = nil) {
        let support = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Manifest", isDirectory: true)
        self.directory = support
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"
        self.dayFormatter = fmt
    }

    func append(_ event: InputEvent) async {
        do {
            try ensureDirectory()
            let day = dayFormatter.string(from: event.timestamp)
            let handle = try handle(forDay: day)
            var data = try encoder.encode(event)
            data.append(0x0A) // newline
            try handle.write(contentsOf: data)
        } catch {
            // Persistence is best-effort. Don't crash the UI for a disk hiccup.
            // The user-facing live stream is unaffected; record it for support.
            DiagnosticLogger.shared.log("persist failed", level: .error,
                                        state: ["error": "\(error)"])
        }
    }

    /// Returns all events currently visible in the today-and-prior on-disk
    /// log, parsed back into `InputEvent`. Used at app launch to repopulate
    /// the UI's rolling buffer.
    func loadRecent(limit: Int = 200) async -> [InputEvent] {
        try? ensureDirectory()
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil))
            ?? []
        let jsonl = urls.filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var collected: [InputEvent] = []
        for url in jsonl.suffix(2) {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in raw.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let event = try? decoder.decode(InputEvent.self, from: data) else { continue }
                collected.append(event)
            }
        }
        return Array(collected.suffix(limit))
    }

    func currentFileURL() async -> URL? {
        try? ensureDirectory()
        guard let day = currentDay else {
            let today = dayFormatter.string(from: Date())
            return directory.appendingPathComponent("events-\(today).jsonl")
        }
        return directory.appendingPathComponent("events-\(day).jsonl")
    }

    private func ensureDirectory() throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
        }
    }

    private func handle(forDay day: String) throws -> FileHandle {
        if let h = currentHandle, currentDay == day {
            return h
        }
        currentHandle?.closeFile()
        currentHandle = nil
        let url = directory.appendingPathComponent("events-\(day).jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        currentDay = day
        currentHandle = h
        return h
    }
}
