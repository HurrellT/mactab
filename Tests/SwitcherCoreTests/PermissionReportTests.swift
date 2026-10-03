import XCTest
@testable import SwitcherCore

final class PermissionReportTests: XCTestCase {
    func testRevokedAccessibilityCannotReportReadyWithAnExistingTap() {
        XCTAssertEqual(report(accessibility: false, keyboard: true).availability, .accessibilityRequired)
    }

    func testDisabledTapDoesNotReportReadyAfterGrantingAccessibility() {
        XCTAssertEqual(report(accessibility: true, keyboard: false).availability, .keyboardUnavailable)
    }

    func testSecureInputExplainsWhyAnEnabledTapCannotReceiveKeys() {
        XCTAssertEqual(report(accessibility: true, keyboard: true, secureInput: true).availability, .secureInput)
    }

    func testWorkingTapDoesNotDemandAnotherPermission() {
        XCTAssertEqual(report(accessibility: true, keyboard: true).availability, .ready)
    }

    func testPauseAndDemoHaveDistinctResultsFromPermissionFailure() {
        XCTAssertEqual(report(accessibility: false, keyboard: false, enabled: false).availability, .paused)
        XCTAssertEqual(report(accessibility: false, keyboard: false, demo: true).availability, .demo)
    }

    private func report(accessibility: Bool, keyboard: Bool, secureInput: Bool = false,
                        enabled: Bool = true, demo: Bool = false) -> PermissionReport {
        PermissionReport(accessibilityGranted: accessibility, keyboardRunning: keyboard,
                         inputMonitoringGranted: false, secureInputEnabled: secureInput, enabled: enabled, demo: demo)
    }
}
