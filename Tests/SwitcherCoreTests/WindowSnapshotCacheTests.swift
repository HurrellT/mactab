import XCTest
@testable import SwitcherCore

final class WindowSnapshotCacheTests: XCTestCase {
    private struct Key: Equatable {
        let pid: Int
        var allSpaces = true
        var includeMinimized = true
        var display = 1
        var inventory: Set<Int> = [10, 20]
        var minimized: Set<Int> = []
    }

    func testRepeatedOpenReusesMetadataUntilExpiration() {
        var cache = WindowSnapshotCache<Key, String>(lifetime: 30)
        let key = Key(pid: 1)
        cache.store(["one", "two"], for: key, now: 100)
        XCTAssertEqual(cache.value(for: key, now: 100.1), ["one", "two"])
        XCTAssertEqual(cache.value(for: key, now: 129.9), ["one", "two"])
        XCTAssertNil(cache.value(for: key, now: 130))
        XCTAssertNil(cache.key)
    }

    func testChangingAppReplacesTheSingleSnapshot() {
        var cache = WindowSnapshotCache<Key, Int>()
        cache.store([1, 2], for: Key(pid: 1), now: 100)
        cache.store([3], for: Key(pid: 2), now: 101)
        XCTAssertEqual(cache.value(for: Key(pid: 2), now: 102), [3])
        XCTAssertNil(cache.value(for: Key(pid: 1), now: 102))
    }

    func testVisibilityPreferencesAndDisplayChangesCannotReuseAnOldList() {
        let original = Key(pid: 1)
        for changed in [Key(pid: 1, allSpaces: false), Key(pid: 1, includeMinimized: false), Key(pid: 1, display: 2)] {
            var cache = WindowSnapshotCache<Key, Int>()
            cache.store([1], for: original, now: 100)
            XCTAssertNil(cache.value(for: changed, now: 101))
            XCTAssertNil(cache.key)
        }
    }

    func testWindowCreationAndClosureRequireAFreshCycleList() {
        for inventory in [Set([10, 20, 30]), Set([10])] {
            var cache = WindowSnapshotCache<Key, Int>()
            cache.store([10, 20], for: Key(pid: 1), now: 100)
            XCTAssertNil(cache.value(for: Key(pid: 1, inventory: inventory), now: 101))
        }
    }

    func testMinimizingOrRestoringAnExcludedWindowInvalidatesItsList() {
        var cache = WindowSnapshotCache<Key, Int>()
        cache.store([10], for: Key(pid: 1, includeMinimized: false, minimized: [20]), now: 100)
        XCTAssertNil(cache.value(for: Key(pid: 1, includeMinimized: false, minimized: []), now: 101))
    }

    func testOverCapacityListsAreNotTruncatedOrCached() {
        var cache = WindowSnapshotCache<Int, Int>(capacity: 2)
        cache.store([1, 2], for: 1, now: 100)
        XCTAssertEqual(cache.value(for: 1, now: 100), [1, 2])
        cache.store([1, 2, 3], for: 1, now: 101)
        XCTAssertNil(cache.value(for: 1, now: 101))
    }

    func testEmptyResultsAndTerminationClearRetainedMetadata() {
        var cache = WindowSnapshotCache<Int, Int>()
        cache.store([1], for: 1, now: 100)
        cache.store([], for: 1, now: 101)
        XCTAssertNil(cache.key)
        cache.store([1], for: 1, now: 102)
        cache.clear()
        XCTAssertNil(cache.value(for: 1, now: 102))
    }

    func testAnInvalidClockCannotResurrectASnapshot() {
        var cache = WindowSnapshotCache<Int, Int>()
        cache.store([1], for: 1, now: 100)
        XCTAssertNil(cache.value(for: 1, now: 99))
    }
}
