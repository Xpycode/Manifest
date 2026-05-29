import XCTest
@testable import Manifest

final class CaretFollowerTests: XCTestCase {

    // MARK: - didTransition dedup predicate

    func testDidTransitionFiresOnFirstDelivery() {
        XCTAssertTrue(CaretFollower.didTransition(
            previous: nil,
            currentPID: 100,
            currentTier: .caret
        ))
    }

    func testDidTransitionSuppressesSamePIDAndTier() {
        XCTAssertFalse(CaretFollower.didTransition(
            previous: (pid: 100, tier: .fieldRect),
            currentPID: 100,
            currentTier: .fieldRect
        ))
    }

    func testDidTransitionFiresOnPIDChange() {
        XCTAssertTrue(CaretFollower.didTransition(
            previous: (pid: 100, tier: .caret),
            currentPID: 200,
            currentTier: .caret
        ))
    }

    func testDidTransitionFiresOnTierChangeWithinSameApp() {
        XCTAssertTrue(CaretFollower.didTransition(
            previous: (pid: 100, tier: .caret),
            currentPID: 100,
            currentTier: .fieldRect
        ))
    }

    func testDidTransitionFiresOnFrozenAfterCaret() {
        XCTAssertTrue(CaretFollower.didTransition(
            previous: (pid: 100, tier: .caret),
            currentPID: 100,
            currentTier: .frozen
        ))
    }
}
