import XCTest
@testable import SwitcherCore

final class WindowFocusHistoryTests: XCTestCase {
    func testPreviousWindowOnAnotherSpaceWinsOverCurrentSpaceEnumerationOrder() {
        var history = WindowFocusHistory<Int>()
        history.record(30) // Previous window, on another Space.
        history.record(10) // Current window, sharing its Space with window 20.

        // Cached cards and fresh AX discovery can arrive in different orders.
        for incoming in [[10, 20, 30], [20, 10, 30], [30, 20, 10]] {
            let ordered = history.ordered(incoming, focused: 10)
            XCTAssertEqual(ordered, [10, 30, 20])
            var selection = Selection()
            selection.beginWindows()
            selection.setWindows(count: ordered.count, preferredIndex: ordered.firstIndex(of: 10)!)
            selection.moveWindow(1) // Also used by release-before-enumeration completes.
            XCTAssertEqual(ordered[selection.windowIndex], 30)
            selection.moveWindow(1)
            XCTAssertEqual(ordered[selection.windowIndex], 20)
            selection.moveWindow(1)
            XCTAssertEqual(ordered[selection.windowIndex], 10)
        }
    }

    func testRepeatedFocusNotificationsDoNotLosePreviousWindowAndQuickTapsToggle() {
        var history = WindowFocusHistory<Int>()
        [20, 30, 10, 10, 10].forEach { history.record($0) }
        XCTAssertEqual(history.ordered([10, 20, 30], focused: 10), [10, 30, 20])
        history.record(30)
        history.record(30)
        XCTAssertEqual(history.ordered([30, 20, 10], focused: 30), [30, 10, 20])
    }

    func testLiveFocusOverridesAnEarlierObservation() {
        var history = WindowFocusHistory<Int>()
        history.record(30)
        history.record(10)
        XCTAssertEqual(history.ordered([10, 20, 30], focused: 20), [20, 10, 30])
    }

    func testClosedAndExcludedWindowsCannotBecomeTheNextTarget() {
        var history = WindowFocusHistory<Int>()
        [40, 20, 30, 10].forEach { history.record($0) }
        history.retain([10, 20, 30]) // Window 40 closed.
        XCTAssertEqual(history.ordered([10, 20], focused: 10), [10, 20])
        // A minimized/other-Space window temporarily excluded by preferences keeps its recency.
        XCTAssertEqual(history.ordered([10, 20, 30], focused: 10), [10, 30, 20])
        XCTAssertEqual(history.ordered([10, 20, 30, 40], focused: 10), [10, 30, 20, 40])
    }

    func testUnknownWindowsKeepEnumerationOrderAndReverseCyclingWraps() {
        let history = WindowFocusHistory<Int>()
        XCTAssertEqual(history.ordered([20, 10, 30], focused: nil), [20, 10, 30])
        let ordered = history.ordered([20, 10, 30], focused: 10)
        XCTAssertEqual(ordered, [10, 20, 30])
        var selection = Selection()
        selection.beginWindows()
        selection.setWindows(count: ordered.count)
        selection.moveWindow(-1)
        XCTAssertEqual(ordered[selection.windowIndex], 30)
        XCTAssertEqual(history.ordered([], focused: 10), [])
        XCTAssertEqual(history.ordered([10], focused: 10), [10])
    }

    func testHistoryHasABoundedNumberOfRetainedIdentities() {
        var history = WindowFocusHistory<Int>()
        (0..<100).forEach { history.record($0) }
        let ordered = history.ordered(Array(0..<100), focused: 99)
        XCTAssertEqual(Array(ordered.prefix(64)), Array((36..<100).reversed()))
        XCTAssertEqual(Array(ordered.suffix(36)), Array(0..<36))
    }
}
