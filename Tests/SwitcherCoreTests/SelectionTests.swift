import XCTest
@testable import SwitcherCore

final class SelectionTests: XCTestCase {
    func testFirstDirectShortcutAdvancesRelativeToFocusedWindow() {
        // Enumeration may complete after Command is released. Its queued first
        // press must still advance, including wraparound and reverse switching.
        for (focused, steps, expected) in [(0, 1, 1), (2, 1, 0), (0, -1, 2)] {
            var state = Selection()
            state.beginWindows()
            state.setWindows(count: 3, preferredIndex: focused)
            state.moveWindow(steps)
            XCTAssertEqual(state.windowIndex, expected)
        }
        var state = Selection()
        state.beginWindows()
        state.setWindows(count: 1)
        state.moveWindow(1)
        XCTAssertEqual(state.windowIndex, 0)
    }

    func testStandaloneWindowsStayOnCurrentAppAndCycle() {
        var state = Selection()
        state.beginWindows()
        XCTAssertTrue(state.isActive)
        XCTAssertTrue(state.isWindowOnly)
        XCTAssertTrue(state.isExpanded)
        XCTAssertEqual(state.appIndex, 0)
        state.setWindows(count: 3, preferredIndex: 1)
        state.moveWindow(1)
        XCTAssertEqual(state.windowIndex, 2)
        state.moveWindow(1)
        XCTAssertEqual(state.windowIndex, 0)
        state.moveWindow(-1)
        XCTAssertEqual(state.windowIndex, 2)
        state.moveApp(1)
        state.collapse()
        XCTAssertTrue(state.isExpanded)
        XCTAssertEqual(state.windowIndex, 2)
        state.end()
        XCTAssertFalse(state.isWindowOnly)
    }

    func testTabCanReplaceStandaloneWindowSession() {
        var state = Selection()
        state.beginWindows()
        state.begin(appCount: 4)
        XCTAssertFalse(state.isWindowOnly)
        XCTAssertFalse(state.isExpanded)
        XCTAssertEqual(state.appIndex, 1)
    }

    func testTabStartsAtPreviousAppAndWraps() {
        var state = Selection()
        state.begin(appCount: 3)
        XCTAssertEqual(state.appIndex, 1)
        state.moveApp(2)
        XCTAssertEqual(state.appIndex, 0)
        state.moveApp(-1)
        XCTAssertEqual(state.appIndex, 2)
    }

    func testReverseTabAndSingleApp() {
        var state = Selection()
        state.begin(appCount: 4, backwards: true)
        XCTAssertEqual(state.appIndex, 3)
        state.begin(appCount: 1)
        state.moveApp(-1)
        XCTAssertEqual(state.appIndex, 0)
    }

    func testExpansionKeepsRememberedWindowUntilNextGrave() {
        var state = Selection()
        state.begin(appCount: 2)
        state.setWindows(count: 3, preferredIndex: 2)
        state.expand()
        XCTAssertEqual(state.windowIndex, 2)
        state.moveWindow(1)
        XCTAssertEqual(state.windowIndex, 0)
        state.moveWindow(-1)
        XCTAssertEqual(state.windowIndex, 2)
    }

    func testChangingAppClearsWindowSelection() {
        var state = Selection()
        state.begin(appCount: 3)
        state.expand()
        state.setWindows(count: 4, preferredIndex: 3)
        state.moveApp(1)
        XCTAssertFalse(state.isExpanded)
        XCTAssertEqual(state.windowCount, 0)
        XCTAssertEqual(state.windowIndex, 0)
    }

    func testEmptyClosedAndInvalidSelectionsAreSafe() {
        var state = Selection()
        state.begin(appCount: 0)
        state.expand()
        XCTAssertFalse(state.isActive)
        XCTAssertFalse(state.isExpanded)
        state.begin(appCount: 2)
        state.setWindows(count: 0, preferredIndex: 8)
        state.expand()
        state.moveWindow(-1)
        XCTAssertEqual(state.windowIndex, 0)
        state.selectApp(20)
        XCTAssertEqual(state.appIndex, 1)
        state.end()
        XCTAssertFalse(state.isActive)
    }
}
