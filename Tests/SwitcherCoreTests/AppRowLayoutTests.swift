import XCTest
@testable import SwitcherCore

final class AppRowLayoutTests: XCTestCase {
    func testUsesWideDisplayBeforeShrinking() {
        let layout = AppRowLayout(appCount: 15, screenWidth: 2560)
        XCTAssertEqual(layout.width, 1832)
        XCTAssertEqual(layout.iconSize, 96)
        XCTAssertEqual(layout.tileWidth, 120)
    }

    func testAllAppsFitNarrowDisplayWithoutOverflow() {
        let layout = AppRowLayout(appCount: 25, screenWidth: 1440)
        XCTAssertEqual(layout.width, 1392)
        XCTAssertLessThan(layout.iconSize, 96)
        XCTAssertEqual(layout.tileWidth * 25 + 32, layout.width, accuracy: 0.001)
    }

    func testIconsNeverGrowPastMaximumAndEmptyListIsSafe() {
        for count in [0, 1, 5, 40, 100] {
            let layout = AppRowLayout(appCount: count, screenWidth: 1920)
            XCTAssertLessThanOrEqual(layout.iconSize, 96)
            XCTAssertGreaterThan(layout.iconSize, 0)
            XCTAssertLessThanOrEqual(layout.width, 1872)
        }
    }
}
