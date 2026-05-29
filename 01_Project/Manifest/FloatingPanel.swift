import AppKit
import SwiftUI

/// Always-borderless floating panel that hosts the SwiftUI HUD. SwiftUI
/// draws all chrome (header, rounded corners, material background) so we
/// never have to mutate `styleMask` at runtime — toggling `.fullSizeContentView`
/// on a live panel leaves the titlebar area as a transparent gap because
/// the contentView keeps the smaller size from the previous chrome.
///
/// Critical traits:
/// - `.nonactivatingPanel`: clicks don't change the OS frontmost app, which
///   would otherwise corrupt our own bundle-ID attribution for events that
///   land on the HUD.
/// - `.floating` window level: stays above ordinary windows, but not as
///   aggressive as `.statusBar` (which hides during Spaces transitions on
///   older macOS).
/// - Window drag is driven by `mouseDown` → `performDrag(with:)`, not by
///   `isMovableByWindowBackground` (see the `mouseDown` override for why).
final class FloatingPanel: NSPanel {
    private static let originXDefaultsKey = "hud.frame.originX"
    private static let originYDefaultsKey = "hud.frame.originY"

    /// Set by `AppDelegate` after construction. The panel consults the
    /// controller's mode to decide whether `panelDidMove` should persist the
    /// origin (only in `.pinned`), and notifies it on user drag so follow
    /// modes can suspend for a few seconds.
    weak var placementController: PanelPlacementController?

    init<Content: View>(rootView: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        self.isMovableByWindowBackground = false
        self.isFloatingPanel = true
        self.level = .floating
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.isReleasedWhenClosed = false
        self.backgroundColor = .clear
        self.hasShadow = true

        let host = NSHostingView(rootView: rootView)
        host.autoresizingMask = [.width, .height]
        if let contentView = self.contentView {
            host.frame = contentView.bounds
            contentView.addSubview(host)
        }
        restoreOriginOrCenter()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidMove(_:)),
            name: NSWindow.didMoveNotification,
            object: self
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Drives window drag explicitly instead of relying on
    /// `isMovableByWindowBackground`. The auto-heuristic intermittently lost
    /// the drag on the 32 pt tall compact strip — once the cursor exited the
    /// panel before AppKit anchored the drag, subsequent `mouseDragged`
    /// events were silently dropped and the panel pinned at its current
    /// origin (the "can't drag further up; expand+collapse to unstick"
    /// symptom). `performDrag(with:)` is Apple's documented escape hatch.
    ///
    /// `mouseDown` reaches the panel only when no SwiftUI control claims the
    /// event first, so this preserves "click controls; drag background"
    /// without further effort.
    override func mouseDown(with event: NSEvent) {
        // Tell the placement controller a drag is starting — in follow modes
        // it suspends updates for a few seconds so the user can re-park the
        // HUD without the follower yanking it back.
        placementController?.userDidDrag()
        performDrag(with: event)
    }

    /// Restore the saved top-left origin if it still lands on a connected screen,
    /// otherwise center. The on-screen check guards against monitor disconnects
    /// (saved coords could place the panel entirely off the visible desktop).
    private func restoreOriginOrCenter() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.originXDefaultsKey) != nil,
              defaults.object(forKey: Self.originYDefaultsKey) != nil else {
            self.center()
            return
        }
        let x = defaults.double(forKey: Self.originXDefaultsKey)
        let y = defaults.double(forKey: Self.originYDefaultsKey)
        let candidate = NSRect(x: x, y: y, width: frame.width, height: frame.height)
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(candidate) }
        if onScreen {
            setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            self.center()
        }
    }

    @objc private func panelDidMove(_ note: Notification) {
        // Persist origin only when the user owns placement (pinned mode).
        // In follow modes, every applied origin is computed from the anchor
        // + offset — persisting those would clobber the user's last pinned
        // origin and surface as "the HUD jumped after switching back to
        // pinned." Nil controller = early launch before AppDelegate has
        // wired it; default to persisting (matches pre-feature behavior).
        if let controller = placementController, controller.mode != .pinned {
            return
        }
        let defaults = UserDefaults.standard
        defaults.set(Double(frame.origin.x), forKey: Self.originXDefaultsKey)
        defaults.set(Double(frame.origin.y), forKey: Self.originYDefaultsKey)
    }
}
