import XCTest
@testable import MarkViewCore

final class TabClosingTests: XCTestCase {
    func testActiveTabAfterClosing() {
        let keep = [false, true, false, false, true, false]
        let cases: [([Bool], Int, Int)] = [
            (keep, 1, 0), (keep, 4, 1), (keep, 3, 0), (keep, 5, 1), (keep, 0, 0), (keep, 2, 0),
            ([false, false, false], 1, -1), ([true, true], 1, 1), ([true, false, true], 2, 1),
            (keep, -1, -1), ([], 0, -1), ([], -1, -1), ([true], 0, 0), ([false], 0, -1),
            (keep, 99, 1), ([false, true, false], 7, 0),
        ]
        for (kept, active, expected) in cases {
            XCTAssertEqual(TabClosing.activeIndex(afterKeeping: kept, active: active), expected, "keep=\(kept), active=\(active)")
        }
    }
}
