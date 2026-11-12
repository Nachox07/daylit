import XCTest
@testable import DaylitCore

final class ShortcutRuleTests: XCTestCase {
    func testDistinctCombinationsDoNotClash() {
        XCTAssertNil(ShortcutRule.clash([(126, 4096), (125, 4096), (2, 4096)]))
    }
    func testTheFirstPairWithTheSameKeyAndModifiersIsReported() {
        let c = ShortcutRule.clash([(126, 4096), (125, 4096), (126, 4096)])
        XCTAssertEqual(c?.first, 0)
        XCTAssertEqual(c?.second, 2)
    }
    func testTheSameKeyWithOtherModifiersIsNotAClash() {
        XCTAssertNil(ShortcutRule.clash([(2, 4096), (2, 6144)]))
    }
}
