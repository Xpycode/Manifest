import AppKit
import Foundation
import Observation

/// Orchestrates HUD placement. Observes `vm.placementMode` / `placementOffset`,
/// drives the matching follower, applies the resulting origin to `FloatingPanel`,
/// and enforces the anti-feedback rules from `docs/specs/placement.md` §6:
///
/// - In `followPointer`, if the candidate frame would contain the current
///   pointer, the update is dropped (no shudder when the cursor is over the HUD).
/// - A user-initiated drag suspends follow updates for `suspendSeconds`; follow
///   resumes only after the anchor moves at least `resumeMinDelta` points.
/// - All applied origin deltas smaller than `applyEpsilon` are coalesced away.
///
/// In `pinned` mode this controller is a no-op; `FloatingPanel.panelDidMove`
/// continues to persist the origin as today.
@MainActor
final class PanelPlacementController {
    private weak var panel: FloatingPanel?
    private let vm: EventStreamViewModel
    private let monitor: FrontmostAppMonitor

    private let pointer = PointerFollower()
    private let caret = CaretFollower()

    private var observationTracker: Void?
    private var modeObservation: NSObjectProtocol?
    private var screenObservation: NSObjectProtocol?

    /// Active mode, mirrored from the VM. Read by `FloatingPanel.panelDidMove`
    /// (via the controller it holds) to decide whether to persist origin —
    /// origin persistence is `pinned`-only.
    private(set) var mode: PanelPlacement = .pinned
    private var offset: PanelOffset = .default

    // Drag-suspension state.
    private var suspendedUntil: Date?
    private var suspendedAtAnchor: CGPoint?
    private static let suspendSeconds: TimeInterval = 5.0
    private static let resumeMinDelta: CGFloat = 4.0

    // Last applied origin (CG top-left) so we can early-out on sub-epsilon ticks.
    private var lastAppliedTopLeft: CGPoint?
    private static let applyEpsilon: CGFloat = 0.5

    /// Approach-freeze tolerance. When the user's cursor is within this many
    /// points of the HUD's current frame, the HUD stops repositioning so the
    /// user can land a click on it. Without this, a positive offset means the
    /// cursor can never overlap the candidate frame (HUD is always offset pt
    /// away from the cursor) and so the HUD would flee forever.
    private static let approachPad: CGFloat = 12

    init(panel: FloatingPanel, vm: EventStreamViewModel, monitor: FrontmostAppMonitor) {
        self.panel = panel
        self.vm = vm
        self.monitor = monitor
    }

    // MARK: - Lifecycle

    func start() {
        // Pick up the persisted mode/offset from the VM and react to changes.
        mode = vm.placementMode
        offset = vm.placementOffset
        installObservationLoop()

        pointer.onTick = { [weak self] cgPoint in
            self?.handlePointerTick(cgPoint)
        }
        caret.onResult = { [weak self] result in
            self?.handleCaretResult(result)
        }

        // Caret follower needs the current frontmost PID and re-binds on switch.
        // We're additive on `monitor.onSwitch` — the VM owns it for app-switch
        // rows, so we wrap and re-export.
        let previous = monitor.onSwitch
        monitor.onSwitch = { [weak self] from, to in
            previous?(from, to)
            self?.frontmostAppChangedByBundleID(to)
        }
        caret.start()

        // Screen reconfiguration (display attached/detached, resolution change)
        // can move the active visibleFrame under us — force a re-apply.
        screenObservation = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The closure runs on .main but Swift sees it as a nonisolated
            // context. assumeIsolated to call MainActor-isolated state.
            MainActor.assumeIsolated {
                self?.applyForCurrentMode()
            }
        }

        applyForCurrentMode()
    }

    func stop() {
        pointer.stop()
        caret.stop()
        if let screenObservation {
            NotificationCenter.default.removeObserver(screenObservation)
        }
        screenObservation = nil
        suspendedUntil = nil
        suspendedAtAnchor = nil
    }

    /// Called by `FloatingPanel.mouseDown` before `performDrag(with:)`.
    func userDidDrag() {
        // While suspended we still track anchors but don't apply them.
        suspendedUntil = Date().addingTimeInterval(Self.suspendSeconds)
        suspendedAtAnchor = nil   // populated on the next tick so resume requires anchor movement
    }

    // MARK: - VM observation

    /// SwiftUI Observation loop: re-register after every read of `vm` props
    /// to receive the next change. Cheap and avoids us caring whether the VM
    /// owner is using a SwiftUI body or not.
    private func installObservationLoop() {
        withObservationTracking { [vm] in
            _ = vm.placementMode
            _ = vm.placementOffset
        } onChange: { [weak self] in
            // Observation fires on whatever queue performed the change. The VM
            // mutates these only from the SwiftUI binding (main), so hop to
            // main + re-install + re-apply.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.modeOrOffsetChanged()
                self.installObservationLoop()
            }
        }
    }

    private func modeOrOffsetChanged() {
        let newMode = vm.placementMode
        let modeChanged = newMode != mode
        mode = newMode
        offset = vm.placementOffset

        if modeChanged {
            // Drop suspension on explicit mode change — the user just told us
            // what they want; don't make them wait out the timer.
            suspendedUntil = nil
            suspendedAtAnchor = nil
            // Reset cached anchors so the freshly-engaged mode applies cleanly.
            lastAppliedTopLeft = nil
        }
        applyForCurrentMode()
    }

    private func applyForCurrentMode() {
        switch mode {
        case .pinned:
            pointer.stop()
            // Caret follower stays running so re-engaging follow-caret is snappy,
            // but its results are ignored while pinned (handleCaretResult checks).
            vm.statusMessage = nil
        case .followPointer:
            pointer.start()
            // Clear any stale caret-tier message — we're no longer following
            // caret, so "Caret bounds unavailable…" must not linger.
            vm.statusMessage = nil
        case .followCaret:
            pointer.stop()
            vm.statusMessage = nil
            // Rebind the AX observer to the current frontmost app (no-op if
            // unchanged) AND force the next delivery to be treated as a
            // transition. The latter handles the same-app re-engage case where
            // `frontmostAppChanged` early-outs and would otherwise leave the
            // user waiting for the next AX observer event before seeing the
            // tier-appropriate status message.
            caret.frontmostAppChanged(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier)
            caret.forceTransitionOnNextDelivery()
        }
    }

    // MARK: - Frontmost-app rebind (caret)

    private func frontmostAppChangedByBundleID(_ bundleID: String?) {
        // The bundle ID isn't enough — caret follower needs a PID. Resolve via
        // NSRunningApplication. nil bundleID (loginwindow/screensaver) clears.
        guard let bundleID else {
            caret.frontmostAppChanged(pid: nil)
            return
        }
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
        caret.frontmostAppChanged(pid: pid)
    }

    // MARK: - Tick handlers

    private func handlePointerTick(_ cgPoint: CGPoint) {
        guard mode == .followPointer else { return }
        guard let panel else { return }

        if isSuspended(anchor: cgPoint) { return }

        let hudSize = panel.frame.size
        let screen = PlacementScreens.containing(cgPoint: cgPoint) ?? NSScreen.main!
        let screenCG = PlacementScreens.visibleCGRect(for: screen)
        let topLeft = PlacementMath.placeHUD(
            anchor: cgPoint,
            hud: hudSize,
            screenCG: screenCG,
            offset: offset
        )

        applyTopLeft(topLeft, hud: hudSize)
    }

    private func handleCaretResult(_ result: CaretFollower.Result) {
        // CaretFollower computes `tierChanged` against its own (pid, tier)
        // cache, so we surface the status message exactly once per transition.
        if mode == .followCaret, result.tierChanged {
            switch result.tier {
            case .caret:
                vm.statusMessage = nil
            case .fieldRect:
                vm.statusMessage = "Caret bounds unavailable — docking to text field."
            case .frozen:
                vm.statusMessage = "No text position info — HUD held in place."
            }
        }

        guard mode == .followCaret else { return }
        guard let panel else { return }
        if result.tier == .frozen { return }
        if isSuspended(anchor: result.anchorCG) { return }

        let hudSize = panel.frame.size
        let screen = PlacementScreens.containing(cgPoint: result.anchorCG) ?? NSScreen.main!
        let screenCG = PlacementScreens.visibleCGRect(for: screen)
        let topLeft = PlacementMath.placeHUD(
            anchor: result.anchorCG,
            hud: hudSize,
            screenCG: screenCG,
            offset: offset
        )
        applyTopLeft(topLeft, hud: hudSize)
    }

    // MARK: - Apply / suspend

    private func isSuspended(anchor: CGPoint) -> Bool {
        guard let until = suspendedUntil else { return false }
        if Date() < until {
            // Track where the anchor was when suspension started so resume
            // requires meaningful movement.
            if suspendedAtAnchor == nil { suspendedAtAnchor = anchor }
            return true
        }
        // Timer expired — but require the anchor to have moved >= resumeMinDelta
        // before we resume applying, so we don't snap the HUD onto a stationary
        // pointer right after the user finished dragging.
        if let start = suspendedAtAnchor {
            let dx = anchor.x - start.x
            let dy = anchor.y - start.y
            if (dx * dx + dy * dy).squareRoot() < Self.resumeMinDelta {
                return true
            }
        }
        suspendedUntil = nil
        suspendedAtAnchor = nil
        return false
    }

    private func applyTopLeft(_ topLeft: CGPoint, hud: CGSize) {
        // Approach-freeze: if the cursor is on (or near) the HUD's current
        // frame, the user is reaching to click — stop moving so they can land
        // it. Uses the CURRENT frame, not the proposed one: with a positive
        // offset the proposed frame never contains the cursor, so checking
        // that would never fire and the HUD would flee forever.
        if isCursorApproachingHUD() { return }

        if let last = lastAppliedTopLeft,
           abs(last.x - topLeft.x) < Self.applyEpsilon,
           abs(last.y - topLeft.y) < Self.applyEpsilon {
            return
        }
        guard let panel else { return }
        let appKitOrigin = PlacementMath.cgTopLeftToAppKitOrigin(
            topLeft,
            hud: hud,
            primaryHeight: PlacementScreens.primaryHeight
        )
        panel.setFrameOrigin(appKitOrigin)
        lastAppliedTopLeft = topLeft
    }

    /// True when the user's pointer is over the HUD or within `approachPad`
    /// points of its edge. Cheap: one `NSEvent.mouseLocation` read + a
    /// rect-contains check.
    private func isCursorApproachingHUD() -> Bool {
        guard let panel else { return false }
        let mouseAppKit = NSEvent.mouseLocation
        let mouseCG = PlacementScreens.appKitMouseLocationToCG(mouseAppKit)
        let primaryH = PlacementScreens.primaryHeight
        let frame = panel.frame
        // Convert AppKit frame (bottom-left origin) to CG-space rect (top-left).
        let frameCG = CGRect(
            x: frame.origin.x,
            y: primaryH - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        let approach = frameCG.insetBy(dx: -Self.approachPad, dy: -Self.approachPad)
        return approach.contains(mouseCG)
    }
}
