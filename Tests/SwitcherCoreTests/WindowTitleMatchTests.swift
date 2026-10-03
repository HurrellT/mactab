import XCTest
@testable import SwitcherCore

final class WindowTitleMatchTests: XCTestCase {
    func testWindowMenuCanOmitBrowserAndProfileSuffix() {
        XCTAssertTrue(WindowTitleMatch.matches(window: "Research - Google Chrome - Personal", menu: "Research"))
        XCTAssertTrue(WindowTitleMatch.matches(window: "Research", menu: "Research"))
    }
    func testNoPartialOrMissingTitleMatches() {
        XCTAssertFalse(WindowTitleMatch.matches(window: "Research notes", menu: "Research"))
        XCTAssertFalse(WindowTitleMatch.matches(window: "Research", menu: ""))
        XCTAssertFalse(WindowTitleMatch.matches(window: "", menu: "Research"))
    }
}
