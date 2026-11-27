import XCTest
@testable import Engine

final class CravingTrailTests: XCTestCase {
    func testTheTrailLoopsWithoutLosingItsStageNumberOrChapterFinales() {
        let first = CravingStage(number: 1)
        let encore = CravingStage(number: 21)
        XCTAssertEqual(first.stageInChapter, 1)
        XCTAssertEqual(encore.number, 21)
        XCTAssertEqual(encore.stageInChapter, 1)
        XCTAssertEqual(encore.chapterTheme, first.chapterTheme)
        XCTAssertEqual(encore.encore, 1)
        XCTAssertEqual(CravingStage(number: 5).goals.count, 2)
        XCTAssertTrue(CravingStage(number: 35).isFinale)
        XCTAssertEqual(CravingStage(number: 4).spotlight, .cupcake)
        XCTAssertEqual(CravingStage(number: 9).spotlight, .teido)
        XCTAssertEqual(CravingStage(number: 1_000_000).number, 1_000_000)
    }

    func testEveryKindOfStageStartsPlayableAndIsRepeatable() {
        for number in [1, 2, 3, 4, 5, 9, 10, 15, 20, 60, 101, 1_000_000] {
            for seed in [1, 42, 127] as [UInt64] {
                let game = CascadeResolver(stage: CravingStage(number: number), seed: seed)
                let retry = CascadeResolver(stage: CravingStage(number: number), seed: seed)
                XCTAssertTrue(game.board.findMatches().isEmpty, "Stage \(number) seed \(seed)")
                XCTAssertGreaterThanOrEqual(MoveValidator.findAllValidMoves(in: game.board).count, 3)
                XCTAssertEqual(game.board.grid, retry.board.grid)
            }
        }
    }

    func testFailedSwapsAndEmergencyShuffleLeaveTheStageBudgetAlone() throws {
        var game = CascadeResolver(stage: CravingStage(number: 1), seed: 42)
        let initial = try XCTUnwrap(game.stage)
        let move = try XCTUnwrap(MoveValidator.findBestHint(in: game.board))
        _ = game.performSwap(from: move.from, to: move.from)
        XCTAssertEqual(game.stage, initial)
        XCTAssertFalse(game.triggerEmergencyShuffle().isEmpty)
        XCTAssertEqual(game.stage, initial)

        let good = try XCTUnwrap(MoveValidator.findBestHint(in: game.board))
        _ = game.performSwap(from: good.from, to: good.to)
        XCTAssertEqual(game.stage?.movesRemaining, initial.movesRemaining - 1)
    }

    func testTheFirstRescueHasTwoOpeningSolutionsAndAnObjectiveAwareHint() throws {
        for seed in 1...16 {
            var game = CascadeResolver(stage: CravingStage(number: 3), seed: UInt64(seed))
            let bottom = BoardState.rows - 1
            let column = try XCTUnwrap((0..<BoardState.cols).first { game.board[bottom - 1, $0]?.kind.isPuppy == true })
            let puppy = GridPos(row: bottom - 1, col: column)
            let beneath = GridPos(row: bottom, col: column)
            let exits = MoveValidator.findAllValidMoves(in: game.board).filter { move in
                guard move.from != puppy && move.to != puppy else { return false }
                var swapped = game.board
                swapped.swapTiles(at: move.from, and: move.to)
                return swapped.findMatches().contains { $0.positions.contains(beneath) }
            }
            XCTAssertGreaterThanOrEqual(exits.count, 2)
            let hint = try XCTUnwrap(game.suggestedMove())
            _ = game.performSwap(from: hint.from, to: hint.to)
            guard case .cleared = game.stage?.result else { return XCTFail("The first puppy should be reachable on seed \(seed)") }
        }
    }

    func testFinalesRequireBothGoalsAndCompletionWinsOnTheFinalSwap() {
        let definition = CravingStage(number: 5)
        var attempt = CravingAttempt(definition)
        for _ in 0..<definition.moveLimit { attempt.spendSwap() }
        for _ in 0..<(definition.goals[0].target + 3) { attempt.collect(.biltemaCombo) }
        XCTAssertEqual(attempt.objectives[0].progress, definition.goals[0].target)

        let at = GridPos(row: 2, col: 2)
        let popped = BoardStep.snorePopped(at: at, pointsAwarded: 0)
        var nearMiss = attempt
        nearMiss.finishSwap([popped, popped], blocked: nil)
        XCTAssertEqual(nearMiss.result, .outOfSwaps)
        XCTAssertEqual(nearMiss.objectives[1].remaining, 1)
        attempt.finishSwap([popped, popped, popped], blocked: nil)
        XCTAssertEqual(attempt.result, .cleared(stars: 1, bonusMoves: 0))
    }

    func testStageSpotlightsReuseThePuppyCadenceAndPadThaiRules() {
        let cupcakeStage = CravingStage(number: 4)
        let cupcake = CascadeResolver(stage: cupcakeStage, seed: 6)
        XCTAssertEqual(cupcake.currentConfig.surge, .cupcake)
        XCTAssertLessThan(cupcake.currentConfig.basePuppyPointInterval, DifficultyConfig.forTier(cupcake.stats.tier).basePuppyPointInterval)
        var attempt = CravingAttempt(cupcakeStage)
        attempt.collect(.cupcake)
        attempt.collect(.bigMac)
        attempt.collect(.partillePoke)
        XCTAssertEqual(attempt.objectives[0].progress, 4)

        let teido = CascadeResolver(stage: CravingStage(number: 9), seed: 6)
        XCTAssertEqual(teido.currentConfig.surge, .teido)
        XCTAssertTrue(teido.board.grid.joined().contains { $0?.kind.isPadThai == true })
    }

    func testCollectionBiasIncreasesOnlyForAClutchOpportunity() throws {
        var attempt = CravingAttempt(CravingStage(number: 1))
        let normal = try XCTUnwrap(attempt.refillBias)
        XCTAssertEqual(normal.kind, .biltemaCombo)
        while attempt.movesRemaining > 3 { attempt.spendSwap() }
        XCTAssertEqual(attempt.refillBias?.extraWeight, normal.extraWeight)
        for _ in 0..<8 { attempt.collect(.biltemaCombo) }
        XCTAssertGreaterThan(try XCTUnwrap(attempt.refillBias).extraWeight, normal.extraWeight)
        for _ in 0..<7 { attempt.collect(.biltemaCombo) }
        XCTAssertNil(attempt.refillBias)
    }

    func testUnusedSwapsEachLandAndDetonateAPowerUpWithoutAffectingTheBudget() throws {
        var game = CascadeResolver(stage: CravingStage(number: 3), seed: 42)
        let hint = try XCTUnwrap(game.suggestedMove())
        let steps = game.performSwap(from: hint.from, to: hint.to)
        let attempt = try XCTUnwrap(game.stage)
        guard case .cleared(let stars, let bonus) = attempt.result else { return XCTFail("Expected a clear") }
        XCTAssertEqual(stars, 3)
        XCTAssertEqual(bonus, 5)
        XCTAssertEqual(game.stats.movesMade, 1)
        let event = try XCTUnwrap(steps.firstIndex { if case .stageFinale = $0 { true } else { false } })
        guard case .stageFinale(let placements) = steps[event] else { return XCTFail("Expected finale placements") }
        XCTAssertEqual(placements.count, bonus)
        XCTAssertEqual(Set(placements.map(\.at)).count, bonus)
        let chain = steps.dropFirst(event + 1).prefix { if case .gravityApplied = $0 { false } else { true } }
        let detonations = chain.compactMap { step -> GridPos? in
            if case .specialTriggered(_, let origin, _, _) = step { return origin }
            return nil
        }
        for placement in placements {
            XCTAssertTrue(placement.tile.special.isSpecial)
            XCTAssertEqual(detonations.filter { $0 == placement.at }.count, 1)
        }
        let points = steps.reduce(0) { score, step in
            switch step {
            case .matchCleared(_, _, let amount, _), .specialTriggered(_, _, _, let amount),
                 .snorePopped(_, let amount), .puppyRescued(_, _, let amount): score + amount
            default: score
            }
        }
        XCTAssertEqual(game.stats.score, points)
        XCTAssertTrue(game.board.findMatches().isEmpty)
        XCTAssertTrue(game.board.grid.joined().allSatisfy { $0 != nil })
        XCTAssertTrue(game.isGameOver)
        XCTAssertTrue(game.performSwap(from: hint.from, to: hint.to).isEmpty)
    }
}
