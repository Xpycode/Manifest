import CoreGraphics
import Foundation

/// One captured input event. Mostly immutable per row; mouse rows have a few
/// `var` fields that the view model patches in place once AX enrichment
/// arrives — both the role/title hints and, when the AX element's owning PID
/// disagrees with the racy frontmost snapshot taken in the tap callback, the
/// `bundleID`/`appName` themselves. Live-display only — the persisted JSONL
/// keeps whatever the tap stamped at click time.
struct InputEvent: Identifiable, Sendable, Hashable, Codable {
    enum Kind: String, Sendable, Hashable, Codable {
        case key
        case modifier
        case mouse
        case scroll
        case appSwitch
    }

    let id: UUID
    let kind: Kind
    /// Human-readable summary: "Cmd+S", "Left Click", "Scroll ↓", "Switched: Safari → Xcode".
    let label: String
    /// Canonical timestamp. Always UTC under the hood (Foundation `Date` is timezone-agnostic).
    let timestamp: Date
    /// Bundle ID of the frontmost app at the moment the event fired. `nil` when no app is
    /// frontmost (loginwindow, screensaver) or when the monitor hasn't seeded yet.
    /// `var` because AX enrichment can re-stamp this on mouse rows when the
    /// element under the click belongs to a different process than the
    /// frontmost snapshot — see `EventStreamViewModel.applyAX` for the race.
    var bundleID: String?
    /// Display name for `bundleID`, resolved via `AppDisplayNameLookup`. Cached so we
    /// don't pound the filesystem in the C callback path. `var` for the same
    /// re-stamp reason as `bundleID`.
    var appName: String?
    /// Screen-coordinate location of the event. Populated only for mouse rows.
    let point: CGPoint?
    /// Scroll delta — vertical, horizontal. Populated only for scroll rows.
    let scrollDelta: ScrollDelta?
    /// How many raw events this row represents. >1 only for coalesced scroll
    /// bursts (see `EventStreamViewModel.handle(_:)`). All other kinds are
    /// always 1 — keystrokes and clicks are individually meaningful.
    let count: Int
    /// AX role of the element under the mouse-down point, patched onto mouse
    /// rows asynchronously by `AXElementLookup`. `var` so the view model can
    /// update the row in place when the off-main worker reports back; nil
    /// while the lookup is in flight or if the lookup yielded nothing useful.
    /// Raw AX role string (e.g. "AXButton") — the view formats for display.
    var axRole: String?
    /// AX title for the same element. Resolved via title → value → description
    /// fallback in `AXElementLookup.resolveTitle`. nil when AX returned only
    /// a role (unlabeled element, or trimming reduced every candidate to "").
    var axTitle: String?

    init(
        id: UUID = UUID(),
        kind: Kind,
        label: String,
        timestamp: Date = Date(),
        bundleID: String? = nil,
        appName: String? = nil,
        point: CGPoint? = nil,
        scrollDelta: ScrollDelta? = nil,
        count: Int = 1,
        axRole: String? = nil,
        axTitle: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.timestamp = timestamp
        self.bundleID = bundleID
        self.appName = appName
        self.point = point
        self.scrollDelta = scrollDelta
        self.count = count
        self.axRole = axRole
        self.axTitle = axTitle
    }
}

struct ScrollDelta: Sendable, Hashable, Codable {
    let dx: Int
    let dy: Int
}
