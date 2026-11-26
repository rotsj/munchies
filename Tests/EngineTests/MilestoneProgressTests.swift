import Engine
import XCTest

final class MilestoneProgressTests: XCTestCase {
    func testEachTierStartsAtItsExactThresholdAndCarriesSurplus() {
        for firstGoal: UInt64 in [1, 10, 15, 25, 50, 100, 10_000] {
            let beforeFirst = MilestoneProgress(total: firstGoal - 1, firstGoal: firstGoal)
            XCTAssertEqual(beforeFirst.tiersEarned, 0)
            XCTAssertEqual(beforeFirst.goal, firstGoal)
            XCTAssertLessThan(beforeFirst.percent, 100)

            let first = MilestoneProgress(total: firstGoal, firstGoal: firstGoal)
            XCTAssertEqual(first.tiersEarned, 1)
            XCTAssertEqual(first.nextTier, 2)
            XCTAssertEqual(first.progress, 0)
            XCTAssertEqual(first.goal, 2 * firstGoal)

            let lastPointOfSecond = MilestoneProgress(total: 3 * firstGoal - 1, firstGoal: firstGoal)
            XCTAssertEqual(lastPointOfSecond.tiersEarned, 1)
            XCTAssertEqual(lastPointOfSecond.progress, 2 * firstGoal - 1)
            XCTAssertLessThan(lastPointOfSecond.percent, 100)

            let second = MilestoneProgress(total: 3 * firstGoal, firstGoal: firstGoal)
            XCTAssertEqual(second.tiersEarned, 2)
            XCTAssertEqual(second.nextTier, 3)
            XCTAssertEqual(second.progress, 0)
            XCTAssertEqual(second.goal, 3 * firstGoal)

            let jump = MilestoneProgress(total: 10 * firstGoal + 1, firstGoal: firstGoal)
            XCTAssertEqual(jump.tiersEarned, 4)
            XCTAssertEqual(jump.progress, 1)
            XCTAssertEqual(jump.goal, 5 * firstGoal)
        }
    }

    func testLateTiersStillHaveGoalsWithoutOverflow() {
        let before = MilestoneProgress(total: 50_000_499_999_999, firstGoal: 10_000)
        let exact = MilestoneProgress(total: 50_000_500_000_000, firstGoal: 10_000)
        XCTAssertEqual(before.tiersEarned, 99_999)
        XCTAssertEqual(before.percent, 99)
        XCTAssertEqual(exact.tiersEarned, 100_000)
        XCTAssertEqual(exact.progress, 0)
        XCTAssertEqual(exact.goal, 1_000_010_000)

        let largest = MilestoneProgress(total: UInt64.max, firstGoal: 1)
        XCTAssertEqual(largest.tiersEarned, 6_074_000_999)
        XCTAssertEqual(largest.nextTier, 6_074_001_000)
        XCTAssertEqual(largest.progress, 2_746_052_115)
        XCTAssertEqual(largest.goal, 6_074_001_000)
        XCTAssertEqual(largest.percent, 45)
    }
}
