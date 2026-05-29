import CoreGraphics
import XCTest
@testable import Manifest

/// Pure-math tests for `PlacementMath.placeHUD` and the CG↔AppKit helpers.
/// All cases use synthetic screen rectangles so we don't depend on the test
/// host's actual display configuration.
final class PlacementMathTests: XCTestCase {

    // A 1440-pt-tall "primary" screen for AppKit↔CG conversions.
    private let primaryHeight: CGFloat = 1440

    // Default HUD size in expanded mode.
    private let hud = CGSize(width: 520, height: 360)

    // CG-space rect for a 2560×1440 primary monitor — origin at (0,0) top-left.
    private let primaryCG = CGRect(x: 0, y: 0, width: 2560, height: 1440)

    // MARK: - placeHUD: no flip needed

    func testPlaceHUD_appliesOffsetWhenInsideScreen() {
        let offset = PanelOffset(dx: 24, dy: 24, flipNearEdges: true)
        let anchor = CGPoint(x: 500, y: 500)
        let topLeft = PlacementMath.placeHUD(
            anchor: anchor, hud: hud, screenCG: primaryCG, offset: offset
        )
        XCTAssertEqual(topLeft.x, 524, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, 524, accuracy: 0.001)
    }

    func testPlaceHUD_negativeOffsetPlacesHUDAboveLeftOfAnchor() {
        let offset = PanelOffset(dx: -24, dy: -24, flipNearEdges: true)
        // Anchor far enough from edges that the negative offset doesn't flip.
        let anchor = CGPoint(x: 800, y: 800)
        let topLeft = PlacementMath.placeHUD(
            anchor: anchor, hud: hud, screenCG: primaryCG, offset: offset
        )
        XCTAssertEqual(topLeft.x, 776, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, 776, accuracy: 0.001)
    }

    // MARK: - placeHUD: edge flip

    func testPlaceHUD_flipsRightEdgeOverflow() {
        // Anchor near right edge: dx=24 would place HUD's right edge at
        // 2500 + 24 + 520 = 3044 > 2560. Flip should send HUD to the left of
        // the anchor: dx becomes -24 - 520 = -544; topLeft.x = 2500 - 544 = 1956.
        let offset = PanelOffset(dx: 24, dy: 24, flipNearEdges: true)
        let anchor = CGPoint(x: 2500, y: 500)
        let topLeft = PlacementMath.placeHUD(
            anchor: anchor, hud: hud, screenCG: primaryCG, offset: offset
        )
        XCTAssertEqual(topLeft.x, 1956, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, 524, accuracy: 0.001)
    }

    func testPlaceHUD_flipsBottomEdgeOverflow() {
        // Anchor near bottom edge: dy=24 would place HUD's bottom edge at
        // 1200 + 24 + 360 = 1584 > 1440. Flip: dy becomes -24 - 360 = -384;
        // topLeft.y = 1200 - 384 = 816.
        let offset = PanelOffset(dx: 24, dy: 24, flipNearEdges: true)
        let anchor = CGPoint(x: 500, y: 1200)
        let topLeft = PlacementMath.placeHUD(
            anchor: anchor, hud: hud, screenCG: primaryCG, offset: offset
        )
        XCTAssertEqual(topLeft.x, 524, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, 816, accuracy: 0.001)
    }

    func testPlaceHUD_flipsLeftEdgeUnderflow() {
        // Negative dx near left edge: dx=-24 places topLeft.x at -4 (< 0).
        // Flip negates dx → +24, topLeft.x = 20 + 24 = 44.
        let offset = PanelOffset(dx: -24, dy: 0, flipNearEdges: true)
        let anchor = CGPoint(x: 20, y: 500)
        let topLeft = PlacementMath.placeHUD(
            anchor: anchor, hud: hud, screenCG: primaryCG, offset: offset
        )
        XCTAssertEqual(topLeft.x, 44, accuracy: 0.001)
    }

    func testPlaceHUD_doesNotFlipWhenToggleDisabled() {
        // Same right-edge overflow case as testPlaceHUD_flipsRightEdgeOverflow,
        // but with flip disabled — hard clamp must kick in to keep HUD on screen.
        let offset = PanelOffset(dx: 24, dy: 24, flipNearEdges: false)
        let anchor = CGPoint(x: 2500, y: 500)
        let topLeft = PlacementMath.placeHUD(
            anchor: anchor, hud: hud, screenCG: primaryCG, offset: offset
        )
        // Clamp: maxX - hud.width = 2560 - 520 = 2040.
        XCTAssertEqual(topLeft.x, 2040, accuracy: 0.001)
    }

    // MARK: - Clamp safety net

    func testPlaceHUD_clampOnRightEdge() {
        // Force a position that would otherwise overflow even after flip:
        // anchor exactly at maxX, dx=0, flip on. dx>=0 branch: 2560+0+520=3080 > 2560 → flip:
        // dx = 0 - 520 = -520; topLeft.x = 2560 - 520 = 2040.
        let offset = PanelOffset(dx: 0, dy: 0, flipNearEdges: true)
        let anchor = CGPoint(x: 2560, y: 0)
        let topLeft = PlacementMath.placeHUD(
            anchor: anchor, hud: hud, screenCG: primaryCG, offset: offset
        )
        XCTAssertEqual(topLeft.x, 2040, accuracy: 0.001)
    }

    func testPlaceHUD_clampDoesNotLoopWhenHUDWiderThanScreen() {
        // HUD is wider than the screen. The clamp should pin to minX, not
        // wrap into negatives or infinite-loop.
        let bigHUD = CGSize(width: 3000, height: 360)
        let offset = PanelOffset(dx: 24, dy: 24, flipNearEdges: true)
        let anchor = CGPoint(x: 500, y: 500)
        let topLeft = PlacementMath.placeHUD(
            anchor: anchor, hud: bigHUD, screenCG: primaryCG, offset: offset
        )
        XCTAssertEqual(topLeft.x, 0, accuracy: 0.001)
    }

    // MARK: - Negative-x screen (monitor to the left of primary)

    func testPlaceHUD_onLeftOfPrimaryMonitorWithNegativeOrigin() {
        // A 1920x1080 monitor positioned to the left of the primary occupies
        // x: -1920…0 in CG-space. Anchor near its center should work.
        let leftMonitor = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let offset = PanelOffset(dx: 24, dy: 24, flipNearEdges: true)
        let anchor = CGPoint(x: -1000, y: 400)
        let topLeft = PlacementMath.placeHUD(
            anchor: anchor, hud: hud, screenCG: leftMonitor, offset: offset
        )
        XCTAssertEqual(topLeft.x, -976, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, 424, accuracy: 0.001)
    }

    func testPlaceHUD_clampsToNegativeMonitorLeftEdge() {
        // Anchor near the left edge of the left monitor; -24 offset would
        // underflow. Flip should kick in.
        let leftMonitor = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let offset = PanelOffset(dx: -24, dy: 0, flipNearEdges: true)
        let anchor = CGPoint(x: -1910, y: 400)
        let topLeft = PlacementMath.placeHUD(
            anchor: anchor, hud: hud, screenCG: leftMonitor, offset: offset
        )
        // dx<0 underflow → flip → dx=+24 → topLeft.x = -1910 + 24 = -1886.
        XCTAssertEqual(topLeft.x, -1886, accuracy: 0.001)
    }

    // MARK: - Coordinate-system round-trip

    func testCGTopLeftToAppKitOriginRoundTrip() {
        // A point 100 pt below the top of the primary screen, AppKit-space
        // should be (primaryHeight - 100 - hud.height) from the bottom.
        let cg = CGPoint(x: 200, y: 100)
        let appKit = PlacementMath.cgTopLeftToAppKitOrigin(cg, hud: hud, primaryHeight: primaryHeight)
        XCTAssertEqual(appKit.x, 200, accuracy: 0.001)
        XCTAssertEqual(appKit.y, primaryHeight - 100 - hud.height, accuracy: 0.001)
    }

    func testCGRectForScreen_primaryScreenIsIdentity() {
        // Primary screen: AppKit origin (0,0), height = primaryHeight. CG-space
        // origin should also be (0,0) and same size.
        let appKitFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let cg = PlacementMath.cgRectForScreen(appKitFrame: appKitFrame, primaryHeight: primaryHeight)
        XCTAssertEqual(cg.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(cg.origin.y, 0, accuracy: 0.001)
        XCTAssertEqual(cg.size.width, 2560, accuracy: 0.001)
        XCTAssertEqual(cg.size.height, 1440, accuracy: 0.001)
    }

    func testCGRectForScreen_secondaryAbovePrimaryHasNegativeCGY() {
        // A secondary monitor stacked above the primary in AppKit-space sits
        // at y >= primaryHeight in AppKit but at y < 0 in CG-space (top-left
        // is "above" the primary's top).
        let above = CGRect(x: 0, y: primaryHeight, width: 1920, height: 1080)
        let cg = PlacementMath.cgRectForScreen(appKitFrame: above, primaryHeight: primaryHeight)
        // maxY in AppKit = primaryHeight + 1080; CG y = primaryHeight - maxY = -1080.
        XCTAssertEqual(cg.origin.y, -1080, accuracy: 0.001)
    }
}
