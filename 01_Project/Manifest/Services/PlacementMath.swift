import AppKit
import CoreGraphics

/// Pure placement math. Two coordinate systems coexist:
///
/// - **CG/AX space**: a single global plane shared by all screens, top-left
///   origin at the primary screen's top-left, +y pointing down. Negative
///   coordinates are normal (left/upper monitors). This is the space of
///   `CGEvent.location` and `kAXBoundsForRangeParameterizedAttribute`.
/// - **AppKit space**: a single global plane, bottom-left origin at the primary
///   screen's bottom-left, +y pointing up. This is the space of
///   `NSEvent.mouseLocation`, `NSScreen.frame`, `NSWindow.frame`.
///
/// Both planes use points, not pixels, on Retina. Everything below stays in
/// points; backingScaleFactor never enters the math.
///
/// All exposed functions are pure of side effects (no NSScreen reads) so they
/// can be unit-tested with synthetic screens.
enum PlacementMath {

    /// CG-space rect for a screen given its AppKit-space frame plus the
    /// primary screen's height. AppKit screens use the primary's height to
    /// flip, *not* their own — the bottom-left of a screen above the primary
    /// can have y > primary.height in AppKit space.
    static func cgRectForScreen(appKitFrame: CGRect, primaryHeight: CGFloat) -> CGRect {
        let cgY = primaryHeight - appKitFrame.maxY
        return CGRect(x: appKitFrame.minX, y: cgY, width: appKitFrame.width, height: appKitFrame.height)
    }

    /// Convert a CG-space top-left point to an AppKit-space bottom-left
    /// origin for an `NSWindow.setFrameOrigin` call. `hud.height` is the
    /// HUD's height; AppKit window frames anchor at the *bottom*-left, so
    /// the bottom edge is `cgPoint.y + hud.height` in CG, which becomes
    /// `primaryHeight - (cgPoint.y + hud.height)` in AppKit.
    static func cgTopLeftToAppKitOrigin(_ cgPoint: CGPoint, hud: CGSize, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: cgPoint.x, y: primaryHeight - cgPoint.y - hud.height)
    }

    /// Compute the HUD's CG-space top-left given an anchor (cursor or caret
    /// point) and an offset, with optional edge-flip + hard-clamp against the
    /// active screen's CG-space rect. The active screen is whichever passes
    /// `anchor`; the caller resolves it.
    static func placeHUD(
        anchor: CGPoint,
        hud: CGSize,
        screenCG: CGRect,
        offset: PanelOffset
    ) -> CGPoint {
        var dx = offset.dx
        var dy = offset.dy
        var topLeft = CGPoint(x: anchor.x + dx, y: anchor.y + dy)

        if offset.flipNearEdges {
            if dx >= 0, topLeft.x + hud.width  > screenCG.maxX { dx = -dx - hud.width }
            if dy >= 0, topLeft.y + hud.height > screenCG.maxY { dy = -dy - hud.height }
            if dx <  0, topLeft.x              < screenCG.minX { dx = -dx }
            if dy <  0, topLeft.y              < screenCG.minY { dy = -dy }
            topLeft = CGPoint(x: anchor.x + dx, y: anchor.y + dy)
        }

        // Hard clamp regardless of flip toggle. Min/max ordering protects
        // against HUDs wider than the screen: max(minX, ...) wins so we don't
        // negative-loop into oblivion, and the HUD pins to the left edge.
        let maxX = max(screenCG.minX, screenCG.maxX - hud.width)
        let maxY = max(screenCG.minY, screenCG.maxY - hud.height)
        topLeft.x = min(max(topLeft.x, screenCG.minX), maxX)
        topLeft.y = min(max(topLeft.y, screenCG.minY), maxY)
        return topLeft
    }
}

/// AppKit-glue helpers that read live `NSScreen` state. Kept off `PlacementMath`
/// so the pure functions stay testable.
@MainActor
enum PlacementScreens {

    /// Primary screen's height in AppKit/CG points. The "primary" screen is
    /// `NSScreen.screens.first` (the one with the menu bar, by AppKit
    /// convention). Falls back to `NSScreen.main?.frame.height` then 0.
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
    }

    /// Find the screen whose AppKit frame contains the given CG-space point.
    /// Returns nil only if no screens are connected (shouldn't happen during
    /// normal app runtime).
    static func containing(cgPoint: CGPoint) -> NSScreen? {
        let primaryHeight = self.primaryHeight
        for screen in NSScreen.screens {
            let cgRect = PlacementMath.cgRectForScreen(appKitFrame: screen.frame, primaryHeight: primaryHeight)
            if cgRect.contains(cgPoint) {
                return screen
            }
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// The CG-space rect of `screen.visibleFrame` (i.e. excluding menu bar +
    /// Dock). Use this as the clamping rect.
    static func visibleCGRect(for screen: NSScreen) -> CGRect {
        PlacementMath.cgRectForScreen(appKitFrame: screen.visibleFrame, primaryHeight: primaryHeight)
    }

    /// Convert AppKit-space `NSEvent.mouseLocation` (bottom-left origin) to
    /// CG-space (top-left origin) using the primary screen's height. Both
    /// planes are global, so a single flip suffices.
    static func appKitMouseLocationToCG(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}
