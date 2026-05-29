import AppKit
import CoreGraphics
import Foundation
import Observation

/// Top-level VM. Owns the service lifecycle, the rolling in-memory event
/// list, persistence, and export. The view binds to `events`.
@MainActor
@Observable
final class EventStreamViewModel {
    /// Most recent first — newest event at index 0. Capped at `maxLiveEvents`
    /// to keep the SwiftUI list lightweight; everything still goes to disk.
    private(set) var events: [InputEvent] = []
    var isCapturing: Bool = false
    var permissionGranted: Bool = EventTapService.isAccessibilityTrusted
    var statusMessage: String?
    /// When true, the UI collapses to just the header strip. Capture keeps
    /// running — this is purely a display toggle so the HUD can stay
    /// on-screen during a screencast without showing the rolling list.
    /// Persisted across launches.
    var isCompact: Bool {
        didSet { UserDefaults.standard.set(isCompact, forKey: Self.isCompactDefaultsKey) }
    }
    /// HUD placement mode (pinned / followPointer / followCaret).
    /// Persisted as raw string in UserDefaults.
    var placementMode: PanelPlacement {
        didSet {
            UserDefaults.standard.set(placementMode.rawValue, forKey: Self.placementModeKey)
        }
    }
    /// Signed offset from the anchor to the HUD's nearest corner, plus
    /// edge-flip toggle. See `docs/specs/placement.md` §1.
    var placementOffset: PanelOffset {
        didSet {
            UserDefaults.standard.set(Double(placementOffset.dx), forKey: Self.placementDxKey)
            UserDefaults.standard.set(Double(placementOffset.dy), forKey: Self.placementDyKey)
            UserDefaults.standard.set(placementOffset.flipNearEdges, forKey: Self.placementFlipKey)
        }
    }

    private static let isCompactDefaultsKey = "hud.isCompact"
    private static let placementModeKey = "hud.placement.mode"
    private static let placementDxKey = "hud.placement.dx"
    private static let placementDyKey = "hud.placement.dy"
    private static let placementFlipKey = "hud.placement.flipNearEdges"

    /// Exposed so the AppDelegate can hand it to `PanelPlacementController`
    /// — the controller piggy-backs `onSwitch` to rebind the AX caret observer.
    let monitor: FrontmostAppMonitor
    private let service: EventTapService
    private let store: EventStore
    private let nameLookup: AppDisplayNameLookup
    private let axLookup: AXElementLookup
    private var consumeTask: Task<Void, Never>?

    /// Soft deadline for AX enrichment requests. The worker drops requests
    /// whose deadline has passed at dequeue time — 2 s is long enough to
    /// absorb a transient stall (target app GC pause, brief window-server
    /// hiccup) but short enough that a stuck app can't keep stale requests
    /// alive past the user's attention span.
    private static let axDeadlineSeconds: TimeInterval = 2.0

    private static let maxLiveEvents = 200
    /// Consecutive scrolls in the same app/direction within this window are
    /// merged into a single row. 1.5 s covers slower scrolls and inertial
    /// tails — short enough that two clearly distinct gestures (separated
    /// by a pause + another action) still produce separate rows.
    private static let scrollCoalesceWindow: TimeInterval = 1.5

    init(monitor: FrontmostAppMonitor = FrontmostAppMonitor(),
         store: EventStore = EventStore(),
         nameLookup: AppDisplayNameLookup = AppDisplayNameLookup(),
         axLookup: AXElementLookup = AXElementLookup()) {
        self.monitor = monitor
        self.service = EventTapService(monitor: monitor)
        self.store = store
        self.nameLookup = nameLookup
        self.axLookup = axLookup
        self.isCompact = UserDefaults.standard.bool(forKey: Self.isCompactDefaultsKey)
        // Placement defaults read once; subsequent changes flow through didSet.
        let defaults = UserDefaults.standard
        let rawMode = defaults.string(forKey: Self.placementModeKey)
        self.placementMode = rawMode.flatMap(PanelPlacement.init(rawValue:)) ?? .pinned
        // For dx/dy: if the key is absent, fall back to PanelOffset.default
        // values. UserDefaults.double returns 0 for missing keys, which
        // would override the 24-pt default — so probe object(forKey:) first.
        let hasDx = defaults.object(forKey: Self.placementDxKey) != nil
        let hasDy = defaults.object(forKey: Self.placementDyKey) != nil
        let hasFlip = defaults.object(forKey: Self.placementFlipKey) != nil
        let dx = hasDx ? CGFloat(defaults.double(forKey: Self.placementDxKey)) : PanelOffset.default.dx
        let dy = hasDy ? CGFloat(defaults.double(forKey: Self.placementDyKey)) : PanelOffset.default.dy
        let flip = hasFlip ? defaults.bool(forKey: Self.placementFlipKey) : PanelOffset.default.flipNearEdges
        self.placementOffset = PanelOffset(dx: dx, dy: dy, flipNearEdges: flip)

        // AX worker posts results on the main queue (DispatchQueue.main.async),
        // so we're already on main when this closure fires — `assumeIsolated`
        // is safe and avoids a Task hop that would lose ordering relative to
        // other main-queue work.
        self.axLookup.onResult = { [weak self] id, role, title, pid in
            MainActor.assumeIsolated {
                self?.applyAX(id: id, role: role, title: title, pid: pid)
            }
        }
    }

    /// Call at app launch.
    func bootstrap() {
        monitor.start()
        monitor.onSwitch = { [weak self] previous, next in
            self?.service.emitAppSwitch(from: previous, to: next)
        }
        Task { await self.preload() }
        start()
    }

    func start() {
        guard !isCapturing else { return }
        permissionGranted = EventTapService.isAccessibilityTrusted
        guard permissionGranted else {
            statusMessage = "Grant Accessibility in System Settings → Privacy & Security."
            DiagnosticLogger.shared.log("capture blocked: Accessibility not trusted", level: .warn)
            EventTapService.requestAccessibilityTrust()
            return
        }
        do {
            let stream = try service.start()
            isCapturing = true
            statusMessage = nil
            DiagnosticLogger.shared.log("capture started")
            consumeTask = Task { [weak self] in
                guard let self else { return }
                for await event in stream {
                    await self.handle(event)
                }
            }
        } catch {
            statusMessage = "Tap failed: \(error)"
            DiagnosticLogger.shared.log("tap start failed", level: .error,
                                        state: ["error": "\(error)"])
        }
    }

    func stop() {
        service.stop()
        monitor.stop()
        consumeTask?.cancel()
        consumeTask = nil
        isCapturing = false
        DiagnosticLogger.shared.log("capture stopped")
    }

    func clear() {
        events.removeAll()
    }

    func exportCSV() {
        save(data: Data(Exporter.csv(events: events).utf8),
             suggestedName: "Manifest-\(timestampSlug()).csv",
             allowedExtension: "csv")
    }

    func exportJSON() {
        guard let data = try? Exporter.json(events: events) else {
            statusMessage = "Export failed."
            DiagnosticLogger.shared.log("JSON export encode failed", level: .error,
                                        state: ["count": "\(events.count)"])
            return
        }
        save(data: data,
             suggestedName: "Manifest-\(timestampSlug()).json",
             allowedExtension: "json")
    }

    private func handle(_ event: InputEvent) async {
        // Mouse events that land inside our own panel are HUD-control
        // interactions (Start/Stop, Clear, Export, the chevron, the ×, or
        // dragging the panel). They're noise in a tool whose purpose is to
        // show what the user did in *other* apps, so we drop them entirely
        // — not persisted, not inserted, no AX enqueue.
        //
        // The geometric hit-test also serves as the AX-recursion guard
        // (would have applied below): AX queries on a point inside our
        // own process recurse synchronously into our SwiftUI hit-test on
        // the worker thread, tripping its main-actor isolation check and
        // SIGTRAPing us. Since we early-return here, we never even reach
        // the AX enqueue site.
        if event.kind == .mouse, let point = event.point, hitTestOwnPanel(point) {
            return
        }
        let bundleID = event.bundleID
        let enriched = InputEvent(
            id: event.id,
            kind: event.kind,
            label: event.label,
            timestamp: event.timestamp,
            bundleID: bundleID,
            appName: nameLookup.displayName(forBundleID: bundleID),
            point: event.point,
            scrollDelta: event.scrollDelta,
            count: event.count
        )

        // Raw event always hits the on-disk log — coalescing is a display
        // concern only, so the JSONL stays a faithful record.
        await store.append(enriched)

        // Try to coalesce into the existing top row if it's a recent scroll
        // in the same direction + same app.
        if enriched.kind == .scroll,
           let newDelta = enriched.scrollDelta,
           let last = events.first,
           last.kind == .scroll,
           last.bundleID == enriched.bundleID,
           let lastDelta = last.scrollDelta,
           enriched.timestamp.timeIntervalSince(last.timestamp) < Self.scrollCoalesceWindow,
           Self.sameDirection(lastDelta, newDelta) {
            let mergedDelta = ScrollDelta(dx: lastDelta.dx + newDelta.dx,
                                          dy: lastDelta.dy + newDelta.dy)
            let mergedCount = last.count + 1
            events[0] = InputEvent(
                id: last.id, // keep id stable so SwiftUI doesn't churn the row
                kind: .scroll,
                label: Self.formatScrollLabel(delta: mergedDelta, count: mergedCount),
                timestamp: enriched.timestamp,
                bundleID: enriched.bundleID,
                appName: enriched.appName,
                point: nil,
                scrollDelta: mergedDelta,
                count: mergedCount
            )
            return
        }

        events.insert(enriched, at: 0)
        if events.count > Self.maxLiveEvents {
            events.removeLast(events.count - Self.maxLiveEvents)
        }

        // Kick off AX enrichment for mouse rows. Own-panel clicks already
        // returned at the top of this method, so any mouse row reaching here
        // is cross-process and safe to enqueue. Defensive nil-point check
        // because the type allows it; tap callback always populates it.
        if enriched.kind == .mouse, let point = enriched.point {
            axLookup.enqueue(
                id: enriched.id,
                point: point,
                deadline: Date().addingTimeInterval(Self.axDeadlineSeconds)
            )
        }
    }

    /// Patches the AX fields of the row matching `id`. Silent no-op if the
    /// row is no longer in `events` — possible because (a) Clear was pressed
    /// between the click and the AX result, (b) the row was evicted by the
    /// `maxLiveEvents` cap during a burst, or (c) capture was stopped and
    /// `events` was reset.
    ///
    /// Also repairs the click-attribution race: the tap callback stamps
    /// `bundleID` from the frontmost snapshot, which can lag ~50 ms behind a
    /// Cmd+Tab still in flight. The AX element's owning PID is authoritative
    /// for "what was under the cursor", so when the PID resolves to a
    /// different bundle than the stamped one, we overwrite `bundleID` and
    /// re-resolve `appName`. A PID with no live `NSRunningApplication`
    /// (process died between click and AX response) leaves the original
    /// stamp alone.
    ///
    /// The persisted JSONL is not patched — AX data, including the re-stamp,
    /// is a live-display concern only; the on-disk log stays a faithful
    /// record of what the tap saw at click time. Exports replayed from disk
    /// retain the original (possibly racy) bundleID.
    private func applyAX(id: UUID, role: String, title: String?, pid: pid_t) {
        guard let idx = events.firstIndex(where: { $0.id == id }) else { return }
        events[idx].axRole = role
        events[idx].axTitle = title

        if let axBundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           axBundleID != events[idx].bundleID {
            events[idx].bundleID = axBundleID
            events[idx].appName = nameLookup.displayName(forBundleID: axBundleID)
        }
    }

    /// True when two scroll deltas don't cross zero on either axis.
    /// A zero on one side never blocks coalescing — pure-vertical followed by
    /// pure-vertical-of-the-same-sign should merge.
    private static func sameDirection(_ a: ScrollDelta, _ b: ScrollDelta) -> Bool {
        func sign(_ n: Int) -> Int { n == 0 ? 0 : (n > 0 ? 1 : -1) }
        if sign(a.dy) != 0, sign(b.dy) != 0, sign(a.dy) != sign(b.dy) { return false }
        if sign(a.dx) != 0, sign(b.dx) != 0, sign(a.dx) != sign(b.dx) { return false }
        return true
    }

    private static func formatScrollLabel(delta: ScrollDelta, count: Int) -> String {
        var parts: [String] = []
        if delta.dy != 0 {
            parts.append("\(delta.dy > 0 ? "↑" : "↓") \(abs(delta.dy))")
        }
        if delta.dx != 0 {
            parts.append("\(delta.dx > 0 ? "→" : "←") \(abs(delta.dx))")
        }
        var label = "Scroll " + parts.joined(separator: " ")
        if count > 1 { label += " ×\(count)" }
        return label
    }

    /// True when `point` (CGEvent global coordinates — top-left origin, primary
    /// screen's origin) falls inside one of our visible windows.
    /// CG global y grows downward from the primary screen's top edge; AppKit
    /// window frames grow upward from the primary screen's bottom edge. We
    /// flip once over the primary screen's height to compare in AppKit space.
    private func hitTestOwnPanel(_ cgPoint: CGPoint) -> Bool {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return false }
        let appKitPoint = NSPoint(x: cgPoint.x, y: primaryHeight - cgPoint.y)
        for window in NSApp.windows where window.isVisible {
            if window.frame.contains(appKitPoint) { return true }
        }
        return false
    }

    private func preload() async {
        let recent = await store.loadRecent(limit: 50)
        // Persisted log is oldest-first; UI wants newest-first.
        events = recent.reversed().map { event in
            InputEvent(
                id: event.id,
                kind: event.kind,
                label: event.label,
                timestamp: event.timestamp,
                bundleID: event.bundleID,
                appName: nameLookup.displayName(forBundleID: event.bundleID),
                point: event.point,
                scrollDelta: event.scrollDelta,
                count: event.count
            )
        }
    }

    private func save(data: Data, suggestedName: String, allowedExtension: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: [.atomic])
            statusMessage = "Exported \(events.count) events."
        } catch {
            statusMessage = "Export failed: \(error)"
            DiagnosticLogger.shared.log("export write failed", level: .error,
                                        state: ["error": "\(error)"])
        }
    }

    private func timestampSlug() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        return fmt.string(from: Date())
    }
}
