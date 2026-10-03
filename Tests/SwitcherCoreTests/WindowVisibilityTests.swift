import XCTest
@testable import SwitcherCore

final class WindowVisibilityTests: XCTestCase {
    func testAllSpacesIncludesAnUnpublishedOffscreenWindow() {
        XCTAssertTrue(include(allSpaces: true, published: false, onScreen: false))
        XCTAssertFalse(include(allSpaces: false, published: false, onScreen: false))
    }

    func testCurrentSpacesKeepsCoveredPublishedWindows() {
        XCTAssertTrue(include(allSpaces: false, published: true, onScreen: false))
        XCTAssertTrue(include(allSpaces: false, published: false, onScreen: true))
    }

    func testMinimizedPreferenceAppliesInBothScopes() {
        for allSpaces in [true, false] {
            XCTAssertTrue(include(allSpaces: allSpaces, published: true, onScreen: false, minimized: true))
            XCTAssertFalse(include(allSpaces: allSpaces, published: true, onScreen: false,
                                   minimized: true, includeMinimized: false))
        }
    }

    private func include(allSpaces: Bool, published: Bool, onScreen: Bool, minimized: Bool = false,
                         includeMinimized: Bool = true) -> Bool {
        WindowVisibility.includes(allSpaces: allSpaces, publishedByAccessibility: published,
                                  onScreen: onScreen, minimized: minimized, includeMinimized: includeMinimized)
    }
}
