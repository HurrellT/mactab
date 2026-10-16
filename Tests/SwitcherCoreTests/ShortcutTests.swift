import XCTest
@testable import SwitcherCore

final class ShortcutTests: XCTestCase {
    private let primary = KeyboardShortcut(keyCode: 18, modifiers: [.command, .option], keyLabel: "1")
    private func app(_ shortcut: KeyboardShortcut?) -> ShortcutBinding {
        ShortcutBinding(shortcut: shortcut, target: .application(ApplicationShortcutTarget(
            bundleIdentifier: "test.app", bundlePath: "/Applications/Test.app", name: "Test")))
    }

    func testRoundTripRetainsDestinationsAndDisabledBindings() throws {
        var application = app(primary)
        application.enabled = false
        let secondApp = app(KeyboardShortcut(keyCode: 19, modifiers: [.option, .command]))
        let saved = ShortcutConfiguration(bindings: [application, secondApp])
        let restored = try JSONDecoder().decode(ShortcutConfiguration.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(restored.bindings, saved.bindings)
        XCTAssertEqual(restored.activeBindings, [secondApp])
        var future = restored
        future.version = 2
        XCTAssertTrue(future.activeBindings.isEmpty)
    }

    func testDisplayLabelsDoNotAffectMatchingOrDuplicateDetection() {
        let renamed = KeyboardShortcut(keyCode: 18, modifiers: [.option, .command], keyLabel: "!")
        XCTAssertEqual(primary, renamed)
        XCTAssertEqual(Set([primary, renamed]).count, 1)
        let first = app(primary)
        var second = app(renamed)
        second.enabled = false
        let configuration = ShortcutConfiguration(bindings: [first, second])
        XCTAssertNotNil(configuration.validationError(for: first))
        XCTAssertTrue(configuration.activeBindings.isEmpty)
    }

    func testLegacyDesktopBindingsAreDiscardedWithoutLosingApplicationShortcuts() throws {
        let application = app(primary)
        let encoded = try JSONEncoder().encode(ShortcutConfiguration(bindings: [application]))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let applicationRecord = try XCTUnwrap((legacy["bindings"] as? [[String: Any]])?.first)
        var desktopRecord = applicationRecord
        desktopRecord["id"] = UUID().uuidString
        desktopRecord["target"] = ["desktop": ["number": 2, "nativeShortcut": [
            "keyCode": 19, "modifiers": ["rawValue": 1], "keyLabel": "2"
        ]]]
        legacy["bindings"] = [desktopRecord, applicationRecord]
        let restored = try JSONDecoder().decode(ShortcutConfiguration.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(restored.bindings, [application])
        XCTAssertEqual(restored.activeBindings, [application])
        let roundTrip = try JSONDecoder().decode(ShortcutConfiguration.self, from: JSONEncoder().encode(restored))
        XCTAssertEqual(roundTrip.bindings, [application])
    }

    func testTypingAndSwitcherShortcutsStayReserved() {
        for modifiers: ShortcutModifiers in [[], .shift] {
            XCTAssertNotNil(KeyboardShortcut(keyCode: 18, modifiers: modifiers).validationError)
        }
        for code: UInt16 in [48, 50] {
            for modifiers: ShortcutModifiers in [.command, [.command, .shift]] {
                XCTAssertNotNil(KeyboardShortcut(keyCode: code, modifiers: modifiers).validationError)
            }
            XCTAssertNil(KeyboardShortcut(keyCode: code, modifiers: [.command, .option]).validationError)
        }
        XCTAssertNotNil(KeyboardShortcut(keyCode: 55, modifiers: .command).validationError)
        XCTAssertNotNil(KeyboardShortcut(keyCode: 53, modifiers: .control).validationError)
    }

    func testIncompleteOrInvalidSavedBindingsFailClosed() {
        let missing = app(nil)
        let invalid = ShortcutBinding(shortcut: primary, target: .application(ApplicationShortcutTarget(
            bundleIdentifier: "", bundlePath: "", name: "Missing")))
        let duplicatedID = app(primary)
        XCTAssertTrue(ShortcutConfiguration(bindings: [missing, invalid]).activeBindings.isEmpty)
        XCTAssertTrue(ShortcutConfiguration(bindings: [duplicatedID, duplicatedID]).activeBindings.isEmpty)
    }

    func testStableWindowCycleSurvivesFocusReorderingAndWindowChanges() {
        var cycle = WindowCycle<Int>()
        XCTAssertEqual(cycle.next(incoming: [1, 2, 3], focused: 1), 2)
        XCTAssertEqual(cycle.next(incoming: [2, 1, 3], focused: 2), 3)
        XCTAssertEqual(cycle.next(incoming: [3, 2, 1], focused: 3), 1)
        XCTAssertEqual(cycle.next(incoming: [1, 3, 4], focused: 1), 3)
        XCTAssertEqual(cycle.next(incoming: [3, 4, 1], focused: 3), 4)
        XCTAssertEqual(cycle.next(incoming: [4], focused: 4), 4)
        XCTAssertNil(cycle.next(incoming: [], focused: nil))
        XCTAssertTrue(cycle.order.isEmpty)
        XCTAssertEqual(cycle.next(incoming: [9, 10], focused: nil), 9)
    }

    func testLargeWindowListsAreNotTruncatedOrRetained() {
        var cycle = WindowCycle<Int>()
        let windows = Array(0..<80)
        XCTAssertEqual(cycle.next(incoming: windows, focused: 78), 79)
        XCTAssertEqual(cycle.next(incoming: windows, focused: 79), 0)
        XCTAssertTrue(cycle.order.isEmpty)
    }
}
