import AppKit
import QuartzCore

/// Reads `NSEvent.mouseLocation` once per display frame via `CADisplayLink`.
/// Lightweight (no AX, no event tap traffic) and naturally throttled — the
/// display link pauses when the display sleeps.
///
/// Publishes the latest CG-space pointer position to its delegate. The
/// delegate is invoked on the main actor; the display-link callback hops via
/// `DispatchQueue.main.async` only when the new position differs from the last
/// applied one by ≥ 0.5 pt, so a stationary cursor produces zero main-queue
/// traffic.
@MainActor
final class PointerFollower {
    /// Called on the main actor with a CG-space pointer location (top-left origin).
    var onTick: ((CGPoint) -> Void)?

    private var displayLink: CADisplayLink?
    private var lastReportedCG: CGPoint?
    private static let deltaEpsilon: CGFloat = 0.5

    func start() {
        guard displayLink == nil else { return }
        // macOS 14+ vends `CADisplayLink` from a screen/window/view rather than
        // exposing `init(target:selector:)`. The link inherits the screen's
        // refresh rate (60 or 120 Hz on ProMotion) and pauses with the display.
        // .common modes keeps us ticking while an NSPanel drag is putting the
        // run loop into eventTrackingMode.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        lastReportedCG = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        // `NSEvent.mouseLocation` is AppKit space (bottom-left). Convert once
        // to CG to align with everything downstream (placement math + AX bounds).
        let appKit = NSEvent.mouseLocation
        let cg = PlacementScreens.appKitMouseLocationToCG(appKit)

        if let last = lastReportedCG,
           abs(cg.x - last.x) < Self.deltaEpsilon,
           abs(cg.y - last.y) < Self.deltaEpsilon {
            return
        }
        lastReportedCG = cg
        onTick?(cg)
    }
}
