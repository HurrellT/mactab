import AppKit
import XCTest
import SwitcherCore
@testable import MacTab

final class KeyboardShortcutTests: XCTestCase {
    private let app = ShortcutBinding(shortcut: KeyboardShortcut(keyCode: 18, modifiers: [.command, .option]),
        target: .application(ApplicationShortcutTarget(bundleIdentifier: "test.app", bundlePath: "/Test.app", name: "Test")))
    private func event(_ code: CGKeyCode = 18, flags: CGEventFlags = [.maskCommand, .maskAlternate], repeatKey: Bool = false) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
        return event
    }
    func testRepeatedAppPressesFireOncePerPressWithoutOverlay() {
        let keyboard = KeyboardInterceptor()
        keyboard.bindings = [app]
        var activations = 0
        var overlayEvents = 0
        keyboard.onShortcut = { _ in activations += 1 }
        keyboard.onKey = { _ in overlayEvents += 1 }
        XCTAssertTrue(keyboard.handle(.keyDown, event()) == nil)
        XCTAssertTrue(keyboard.handle(.keyDown, event(repeatKey: true)) == nil)
        XCTAssertTrue(keyboard.handle(.keyDown, event(flags: [], repeatKey: true)) == nil)
        XCTAssertTrue(keyboard.handle(.keyUp, event(flags: [])) == nil)
        XCTAssertTrue(keyboard.handle(.keyDown, event()) == nil)
        XCTAssertEqual(activations, 2)
        XCTAssertEqual(overlayEvents, 0)
        XCTAssertTrue(keyboard.handle(.keyDown, event(19)) != nil)
    }
    func testRecordingSuspendsActionsAndInterruptionClearsCapturedKeys() {
        let keyboard = KeyboardInterceptor()
        keyboard.bindings = [app]
        var actions = 0
        var interruptions = 0
        keyboard.onShortcut = { _ in actions += 1 }
        keyboard.onInterruption = { interruptions += 1 }
        keyboard.isRecording = true
        XCTAssertTrue(keyboard.handle(.keyDown, event()) != nil)
        XCTAssertEqual(actions, 0)
        keyboard.isRecording = false
        XCTAssertTrue(keyboard.handle(.keyDown, event()) == nil)
        XCTAssertEqual(actions, 1)
        _ = keyboard.handle(.tapDisabledByTimeout, event())
        XCTAssertTrue(keyboard.handle(.keyUp, event(flags: [])) != nil)
        XCTAssertEqual(actions, 1)
        XCTAssertEqual(interruptions, 2)
    }
    func testSwitcherShortcutsAndNavigationArePreserved() {
        let keyboard = KeyboardInterceptor()
        var tabEvents = 0
        var releaseEvents = 0
        keyboard.onKey = {
            if case .tab = $0 { tabEvents += 1 }
            if case .release = $0 { releaseEvents += 1 }
        }
        keyboard.isSwitching = { true }
        XCTAssertTrue(keyboard.handle(.keyDown, event(48, flags: .maskCommand)) == nil)
        XCTAssertTrue(keyboard.handle(.keyDown, event(48, flags: .maskCommand, repeatKey: true)) == nil)
        XCTAssertTrue(keyboard.handle(.flagsChanged, event(flags: [])) != nil)
        XCTAssertEqual(tabEvents, 2, "Cmd+Tab auto-repeat should continue cycling")
        XCTAssertEqual(releaseEvents, 1)
    }
}
