import CoreGraphics
import Foundation

/// How the HUD chooses its on-screen position.
/// - `pinned`: legacy behavior — user drag, origin persisted as `hud.frame.origin{X,Y}`.
/// - `followPointer`: tracks `NSEvent.mouseLocation` every display frame.
/// - `followCaret`: tracks the focused text caret via AX; falls back to focused-field rect, then freezes.
enum PanelPlacement: String, Codable, CaseIterable, Sendable {
    case pinned
    case followPointer
    case followCaret
}

/// Signed offset from the anchor point (cursor or caret) to the HUD's nearest corner.
/// The sign encodes which corner anchors: +dx/+dy = HUD's top-left at anchor + (dx, dy)
/// in CG-space (top-left origin, +y down). Edge-flip flips signs when the trial placement
/// would overflow the active screen's visibleFrame.
struct PanelOffset: Codable, Equatable, Sendable {
    var dx: CGFloat
    var dy: CGFloat
    var flipNearEdges: Bool

    static let `default` = PanelOffset(dx: 24, dy: 24, flipNearEdges: true)

    /// UI bounds for the steppers; chosen to allow parking the HUD on the
    /// opposite half of a typical screen without overshooting common displays.
    static let range: ClosedRange<CGFloat> = -200...200
    static let step: CGFloat = 4
}
