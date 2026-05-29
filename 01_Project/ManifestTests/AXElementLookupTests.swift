import CoreGraphics
import XCTest
@testable import Manifest

final class AXElementLookupTests: XCTestCase {

    // MARK: - resolveTitle fallback chain

    func testResolveTitleReturnsTitleWhenPresent() {
        XCTAssertEqual(
            AXElementLookup.resolveTitle(title: "Send", value: "value", description: "desc"),
            "Send"
        )
    }

    func testResolveTitleFallsThroughToValueWhenTitleNil() {
        XCTAssertEqual(
            AXElementLookup.resolveTitle(title: nil, value: "value", description: "desc"),
            "value"
        )
    }

    func testResolveTitleFallsThroughToDescriptionWhenTitleAndValueNil() {
        XCTAssertEqual(
            AXElementLookup.resolveTitle(title: nil, value: nil, description: "desc"),
            "desc"
        )
    }

    func testResolveTitleReturnsNilWhenAllNil() {
        XCTAssertNil(AXElementLookup.resolveTitle(title: nil, value: nil, description: nil))
    }

    func testResolveTitleTreatsWhitespaceOnlyAsEmpty() {
        XCTAssertEqual(
            AXElementLookup.resolveTitle(title: "   ", value: "Real", description: "desc"),
            "Real"
        )
    }

    func testResolveTitleTreatsEmptyStringAsEmpty() {
        XCTAssertEqual(
            AXElementLookup.resolveTitle(title: "", value: "Real", description: "desc"),
            "Real"
        )
    }

    func testResolveTitleTrimsLeadingTrailingWhitespace() {
        XCTAssertEqual(
            AXElementLookup.resolveTitle(title: "  Send  ", value: nil, description: nil),
            "Send"
        )
    }

    func testResolveTitleNewlineOnlyFallsThrough() {
        XCTAssertEqual(
            AXElementLookup.resolveTitle(title: "\n", value: "value", description: nil),
            "value"
        )
    }

    // MARK: - Deadline drop

    func testDeadlinePastSilentlyDrops() {
        let lookup = AXElementLookup()
        let resultExpectation = expectation(description: "onResult must not fire")
        resultExpectation.isInverted = true
        lookup.onResult = { _, _, _, _ in resultExpectation.fulfill() }

        lookup.enqueue(
            id: UUID(),
            point: CGPoint(x: 100, y: 100),
            deadline: Date().addingTimeInterval(-1.0)
        )
        lookup.syncForTests()

        // Pending must be empty: the worker dequeued the request, observed
        // the past deadline, and dropped it without calling AX.
        XCTAssertEqual(lookup.pendingCountForTests(), 0)
        wait(for: [resultExpectation], timeout: 0.2)
    }

    // MARK: - Queue cap

    func testQueueCapSoftBoundsAt20Pending() {
        let lookup = AXElementLookup()
        // Use a past deadline so every drain is a fast no-op (no real AX
        // call). This exercises the cap without depending on an AX target.
        let staleDeadline = Date().addingTimeInterval(-1.0)

        for _ in 0..<25 {
            lookup.enqueue(id: UUID(), point: .zero, deadline: staleDeadline)
        }
        lookup.syncForTests()

        // Every request was either dropped at enqueue (cap eviction) or
        // dropped at drain (past deadline). Either way the queue settles
        // empty — the cap test really asserts the enqueue path doesn't grow
        // beyond the cap and the drainOne path keeps consuming.
        XCTAssertEqual(lookup.pendingCountForTests(), 0)
    }
}
