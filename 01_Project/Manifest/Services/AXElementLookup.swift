import ApplicationServices
import CoreGraphics
import Foundation

/// Off-callback AX enrichment worker. The CGEventTap callback runs on the main
/// run loop and must stay fast — calling `AXUIElementCopyElementAtPosition`
/// there would block the main thread for up to 6 seconds against an
/// unresponsive target. Instead the caller enqueues `(id, point, deadline)`
/// triples here and a serial `DispatchQueue` drains them with an aggressive
/// 250 ms `AXUIElementSetMessagingTimeout` cap.
///
/// Backpressure: soft cap of 20 pending items; if the queue overflows, the
/// oldest pending entry is dropped (drop-newest would be wrong — the user
/// just clicked and we want a chance to enrich the most recent event).
/// Items whose deadline has elapsed at dequeue time are dropped without an
/// AX call — clicking faster than the worker can drain is normal under
/// bursts and leaves the older rows with no element hint rather than backing
/// up.
///
/// Threading: all mutable state is touched on `serialQueue` only. The public
/// API (`enqueue`) is non-blocking and safe to call from any thread; results
/// are posted to `DispatchQueue.main` via `onResult` so callers don't have
/// to hop themselves.
///
/// Provenance: ported verbatim from DownKeyCounter / Tachograph's
/// `Services/AXElementLookup.swift`; see that file's git log for the
/// failure-mode history that shaped the timeout/deadline/cap numbers.
final class AXElementLookup: @unchecked Sendable {
    /// Worker drains pending requests one at a time. `qos: .utility` because
    /// AX enrichment is not user-facing in the way capture itself is — a
    /// half-second of latency here just delays the row's element hint, not a
    /// missed key.
    private let serialQueue = DispatchQueue(label: "showinputs.ax-enrich", qos: .utility)
    private let systemWide: AXUIElement
    /// Touched only on `serialQueue`. FIFO; soft-bounded at `queueCap`.
    private var pending: [(id: UUID, point: CGPoint, deadline: Date)] = []

    /// Soft cap on pending requests. 20 absorbs a one-second click burst at
    /// 20 Hz (well above human limits) without dropping, but is small enough
    /// that a stuck target can't queue thousands of stale requests during
    /// its 250 ms timeout window.
    static let queueCap = 20

    /// Main-queue callback fired when an AX lookup successfully resolves a
    /// role (and optionally a title), plus the PID of the element's owning
    /// process — used by the view model to repair the click-attribution race
    /// (the tap callback stamps `bundleID` from the frontmost snapshot, which
    /// can lag ~50 ms behind a Cmd+Tab in flight). `nil` results are dropped
    /// silently inside the worker — there's no "lookup failed" callback by
    /// design, because the row's defaults (nil axRole/axTitle) are already
    /// the correct "no enrichment" rendering.
    var onResult: ((UUID, String, String?, pid_t) -> Void)?

    init() {
        self.systemWide = AXUIElementCreateSystemWide()
        // 0.25 s cap: AX is synchronous IPC and the default messagingTimeout
        // is ~6 s. Without this cap, a single hung target could stall the
        // serial queue for multiple seconds and back up every subsequent
        // enrichment.
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
    }

    /// Enqueue an AX lookup for a row that has already been inserted. The
    /// `deadline` is the absolute moment after which this request becomes
    /// stale and should be dropped without an AX call — typically
    /// `Date() + 2.0` so a request lingering more than ~2 s in the queue
    /// (because the worker is draining a stuck app) is abandoned.
    /// Non-blocking.
    func enqueue(id: UUID, point: CGPoint, deadline: Date) {
        serialQueue.async { [self] in
            if pending.count >= Self.queueCap {
                pending.removeFirst()
            }
            pending.append((id: id, point: point, deadline: deadline))
            drainOne()
        }
    }

    /// Drains the head of `pending`. Called once per enqueue; because each
    /// `enqueue` schedules exactly one `drainOne` on the same serial queue,
    /// the queue stays in lock-step with the pending array without needing
    /// a separate dispatch source.
    private func drainOne() {
        guard !pending.isEmpty else { return }
        let item = pending.removeFirst()

        if Date() > item.deadline {
            return
        }

        var element: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(item.point.x),
            Float(item.point.y),
            &element
        )

        guard error == .success, let element else { return }

        var roleRef: CFTypeRef?
        let roleErr = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        guard roleErr == .success, let role = roleRef as? String, !role.isEmpty else { return }

        let title = readString(from: element, attribute: kAXTitleAttribute)
        let value = readString(from: element, attribute: kAXValueAttribute)
        let description = readString(from: element, attribute: kAXDescriptionAttribute)
        let resolved = Self.resolveTitle(title: title, value: value, description: description)

        var pid: pid_t = 0
        let pidErr = AXUIElementGetPid(element, &pid)
        guard pidErr == .success, pid > 0 else { return }

        DispatchQueue.main.async { [onResult] in
            onResult?(item.id, role, resolved, pid)
        }
    }

    private func readString(from element: AXUIElement, attribute: String) -> String? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard err == .success else { return nil }
        return ref as? String
    }

    /// Pure fallback chain. Returns the first of (title, value, description)
    /// that is non-nil after trimming whitespace and newlines. Trimming
    /// matters because AX backends often return `" "` or `"\n"` for
    /// unlabeled elements rather than nil.
    static func resolveTitle(title: String?, value: String?, description: String?) -> String? {
        let trim: (String?) -> String? = { raw in
            guard let raw else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return trim(title) ?? trim(value) ?? trim(description)
    }

    /// Test-only synchronous drain. Blocks until the serial queue has caught
    /// up to the calling point — useful for asserting queue-cap and
    /// deadline-drop behavior without sleeping. Not for production paths
    /// (would deadlock if the queue is busy with a slow AX call).
    func syncForTests() {
        serialQueue.sync {}
    }

    /// Test-only inspector. Snapshots the pending array on the serial queue
    /// so tests can assert "N items left after a burst" without racing.
    func pendingCountForTests() -> Int {
        serialQueue.sync { pending.count }
    }
}
