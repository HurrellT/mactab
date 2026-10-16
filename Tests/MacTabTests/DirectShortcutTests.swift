import AppKit
import XCTest
import SwitcherCore
@testable import MacTab

private final class FakeShortcutWindows: ShortcutWindowServicing {
    var ids: [CGWindowID] = [1, 2, 3]
    var focused: CGWindowID = 1
    var frontmost = false
    var requests: [CGWindowID?] = []
    var discoveryCount = 0
    var deferDiscovery = false
    var deferred: (() -> Void)?
    var onDiscovery: (() -> Void)?
    var onFocus: (() -> Void)?
    var rememberValues: [Bool] = []

    func windows(for pid: pid_t, includeMinimized: Bool, remember: Bool, allSpaces: Bool,
                 startingAtFocusedWindow: Bool, completion: @escaping ([WindowItem], Int, Bool) -> Void) {
        discoveryCount += 1
        let cards = ids.map { WindowItem(element: nil, title: "Window \($0)", frame: .zero,
                                        isMinimized: false, displayName: "Test display", windowID: $0) }
        let preferred = ids.firstIndex(of: focused) ?? 0
        let deliver = {
            completion(cards, preferred, false)
            completion(cards, preferred, true)
        }
        if deferDiscovery { deferred = deliver }
        else { DispatchQueue.main.async(execute: deliver) }
        onDiscovery?()
    }
    func focus(_ window: WindowItem?, application: NSRunningApplication, remember: Bool,
               cancellation: ActionCancellation?, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            guard cancellation?.isCancelled != true else { completion(false); return }
            self.requests.append(window?.windowID)
            self.rememberValues.append(remember)
            self.frontmost = true
            if let id = window?.windowID {
                self.focused = id
                self.ids.removeAll { $0 == id }
                self.ids.insert(id, at: 0) // Typical AX focus reordering.
            }
            completion(true)
            self.onFocus?()
        }
    }
}

final class DirectShortcutTests: XCTestCase {
    private var suites: [String] = []
    override func tearDown() {
        for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) }
        super.tearDown()
    }
    private func preferences() -> Preferences {
        let name = "MacTabShortcutTests.\(UUID().uuidString)"
        suites.append(name)
        return Preferences(defaults: UserDefaults(suiteName: name)!)
    }
    private func binding(name: String = "Test", launch: Bool = true) -> ShortcutBinding {
        ShortcutBinding(shortcut: KeyboardShortcut(keyCode: 18, modifiers: [.command, .option]),
                        target: .application(ApplicationShortcutTarget(bundleIdentifier: "test.\(name)",
                            bundlePath: "/\(name).app", name: name, launchIfClosed: launch)))
    }
    private func environment(_ windows: FakeShortcutWindows) -> ShortcutApplicationEnvironment {
        var environment = ShortcutApplicationEnvironment()
        environment.runningApplication = { _ in NSRunningApplication.current }
        environment.isFrontmost = { _ in windows.frontmost }
        environment.isOwnApplication = { _ in false }
        return environment
    }

    func testRapidPressesActivateThenCycleDespiteFocusReordering() {
        let windows = FakeShortcutWindows()
        let settings = preferences()
        settings.rememberWindows = false
        let controller = DirectShortcutController(preferences: settings, windows: windows, environment: environment(windows))
        let finished = expectation(description: "Three sequential actions")
        windows.onFocus = { if windows.requests.count == 3 { finished.fulfill() } }
        let shortcut = binding()
        controller.perform(shortcut)
        controller.perform(shortcut)
        controller.perform(shortcut)
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(windows.requests, [nil, 2, 3])
        XCTAssertEqual(windows.discoveryCount, 2)
        XCTAssertEqual(windows.rememberValues, [false, false, false])
        controller.cancel()
    }

    func testFirstPressInActiveAppAdvancesAndSingleWindowWraps() {
        let windows = FakeShortcutWindows()
        windows.frontmost = true
        windows.ids = [7]
        windows.focused = 7
        let controller = DirectShortcutController(preferences: preferences(), windows: windows, environment: environment(windows))
        let finished = expectation(description: "One window still focuses")
        windows.onFocus = { finished.fulfill() }
        controller.perform(binding())
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(windows.requests, [7])
        controller.cancel()
    }

    func testCancelledDiscoveryCannotStealFocus() {
        let windows = FakeShortcutWindows()
        windows.frontmost = true
        windows.deferDiscovery = true
        let controller = DirectShortcutController(preferences: preferences(), windows: windows, environment: environment(windows))
        let discovered = expectation(description: "Discovery requested")
        windows.onDiscovery = { discovered.fulfill() }
        controller.perform(binding())
        wait(for: [discovered], timeout: 2)
        controller.cancel()
        windows.deferred?()
        XCTAssertTrue(windows.requests.isEmpty)
    }

    func testChangingDestinationCancelsAnEarlierQueuedFocus() {
        let windows = FakeShortcutWindows()
        let controller = DirectShortcutController(preferences: preferences(), windows: windows, environment: environment(windows))
        let finished = expectation(description: "Latest destination activated")
        windows.onFocus = { finished.fulfill() }
        controller.perform(binding(name: "Old"))
        controller.perform(binding(name: "New"))
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(windows.requests.count, 1)
        controller.cancel()
    }

    func testCancelledLaunchDoesNotActivateWhenItsCallbackArrives() {
        let windows = FakeShortcutWindows()
        var environment = environment(windows)
        environment.runningApplication = { _ in nil }
        environment.resolveApplication = { _ in URL(fileURLWithPath: "/Test.app") }
        let launched = expectation(description: "Launch requested")
        var completion: ((NSRunningApplication?, Error?) -> Void)?
        environment.launch = { _, callback in completion = callback; launched.fulfill() }
        let controller = DirectShortcutController(preferences: preferences(), windows: windows, environment: environment)
        controller.perform(binding())
        wait(for: [launched], timeout: 2)
        controller.cancel()
        completion?(NSRunningApplication.current, nil)
        let drained = expectation(description: "Launch callback drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertTrue(windows.requests.isEmpty)
    }

    func testClosedAppWithoutLaunchPermissionReportsErrorWithoutLaunching() {
        let windows = FakeShortcutWindows()
        var environment = environment(windows)
        environment.runningApplication = { _ in nil }
        environment.launch = { _, _ in XCTFail("Launching was disabled") }
        let controller = DirectShortcutController(preferences: preferences(), windows: windows, environment: environment)
        let error = expectation(description: "Closed app reported")
        controller.onError = { message in XCTAssertTrue(message.contains("not running")); error.fulfill() }
        controller.perform(binding(launch: false))
        wait(for: [error], timeout: 2)
        XCTAssertTrue(windows.requests.isEmpty)
    }

    func testPreferencesPersistBindingsWithoutChangingExistingOptions() {
        let original = preferences()
        original.showHints = false
        let shortcut = binding()
        original.shortcuts = ShortcutConfiguration(bindings: [shortcut])
        XCTAssertEqual(original.shortcuts.activeBindings, [shortcut])
        XCTAssertFalse(original.showHints)
    }

}
