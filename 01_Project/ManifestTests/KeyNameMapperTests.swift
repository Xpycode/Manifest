import XCTest
import Carbon.HIToolbox
@testable import Manifest

final class KeyNameMapperTests: XCTestCase {
    func testReturnIsNamed() {
        let label = KeyNameMapper.label(forKeyCode: UInt16(kVK_Return), modifiers: [])
        XCTAssertEqual(label, "Return")
    }

    func testCmdSChord() {
        // The 'S' keycode is kVK_ANSI_S; under the active layout it should
        // translate to "S". Cmd is the leading modifier in the standard order.
        let label = KeyNameMapper.label(forKeyCode: UInt16(kVK_ANSI_S),
                                        modifiers: .maskCommand)
        XCTAssertTrue(label.hasPrefix("Cmd+"),
                      "Expected Cmd+ prefix, got '\(label)'")
        XCTAssertTrue(label.hasSuffix("S"), "Expected suffix 'S', got '\(label)'")
    }

    func testModifierOrdering() {
        // Standard macOS chord order: Ctrl, Opt, Shift, Cmd, key.
        let mods: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]
        let label = KeyNameMapper.label(forKeyCode: UInt16(kVK_ANSI_A), modifiers: mods)
        let order: [String] = ["Ctrl", "Opt", "Shift", "Cmd"]
        var lastIndex = -1
        for token in order {
            guard let range = label.range(of: token) else {
                XCTFail("Missing token \(token) in \(label)")
                return
            }
            let idx = label.distance(from: label.startIndex, to: range.lowerBound)
            XCTAssertGreaterThan(idx, lastIndex, "\(token) out of order in \(label)")
            lastIndex = idx
        }
    }

    func testModifierOnlyLabel() {
        XCTAssertEqual(KeyNameMapper.modifierOnlyLabel(for: .maskCommand), "Cmd")
        XCTAssertEqual(KeyNameMapper.modifierOnlyLabel(for: .maskShift),   "Shift")
        XCTAssertNil(KeyNameMapper.modifierOnlyLabel(for: []))
    }
}
