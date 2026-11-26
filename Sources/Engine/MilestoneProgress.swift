/// Each successive scrapbook tier requires one more copy of the first goal.
public struct MilestoneProgress: Equatable, Sendable {
    public let tiersEarned: UInt64
    public let progress: UInt64
    public let goal: UInt64

    public var nextTier: UInt64 { tiersEarned + 1 }
    public var percent: Int { min(99, Int(Double(progress) * 100 / Double(goal))) }

    public init(total: UInt64, firstGoal: UInt64) {
        precondition(firstGoal > 0)
        let availableUnits = total / firstGoal
        var lower: UInt64 = 0
        var upper = availableUnits
        while lower < upper {
            let gap = upper - lower
            let tier = lower + gap / 2 + gap % 2
            let required = Self.requiredUnits(for: tier)
            if !required.overflow && required.partialValue <= availableUnits {
                lower = tier
            } else {
                upper = tier - 1
            }
        }

        tiersEarned = lower
        progress = total - Self.requiredUnits(for: lower).partialValue * firstGoal
        let nextGoal = firstGoal.multipliedReportingOverflow(by: lower + 1)
        goal = nextGoal.overflow ? UInt64.max : nextGoal.partialValue
    }

    private static func requiredUnits(for tier: UInt64) -> (partialValue: UInt64, overflow: Bool) {
        let half = tier / 2
        // Divide the even factor before multiplying so tier × (tier + 1) never wraps.
        if tier.isMultiple(of: 2) { return half.multipliedReportingOverflow(by: tier + 1) }
        return tier.multipliedReportingOverflow(by: half + 1)
    }
}
