import XCTest
@testable import Engine

final class SnackRunTests: XCTestCase {
    private func play(_ move: ValidMove, in game: inout CascadeResolver) -> [BoardStep] {
        game.performSwap(from: move.from, to: move.to)
    }

    func testOffersAtTenAndEveryTwentyFiveSuccessfulSwapsAfterward() throws {
        for turn in [1, 9, 10, 11, 34, 35, 36, 59, 60, 61] {
            var game = CascadeResolver(seed: 42)
            game.stats.movesMade = turn - 1
            let move = try XCTUnwrap(MoveValidator.findBestHint(in: game.board))
            _ = play(move, in: &game)
            XCTAssertEqual(game.stats.movesMade, turn)
            if [10, 35, 60].contains(turn) {
                guard case .offered(let goals) = game.snackRun else { XCTFail("Missing offer at \(turn)"); continue }
                XCTAssertFalse(goals.isEmpty)
                XCTAssertEqual(Set(goals.map(\.kind)).count, goals.count)
            } else {
                XCTAssertEqual(game.snackRun, .idle)
            }
        }
    }

    func testOffersAreOptionalAndSimulationsLeaveTheBoardAndRandomStreamAlone() throws {
        var offered = CascadeResolver(seed: 42)
        offered.stats.movesMade = 9
        var plain = offered
        let move = try XCTUnwrap(MoveValidator.findBestHint(in: offered.board))
        _ = play(move, in: &offered)
        _ = plain.resolveSwap(from: move.from, to: move.to)
        XCTAssertEqual(offered.board.grid, plain.board.grid)
        XCTAssertEqual(offered.stats, plain.stats)
        var offeredRandom = offered.board.rng
        var plainRandom = plain.board.rng
        XCTAssertEqual(offeredRandom.next(), plainRandom.next())

        let invalid = offered.performSwap(from: move.from, to: move.from)
        XCTAssertEqual(invalid, [.swap(from: move.from, to: move.from, reverted: true)])
        XCTAssertEqual(offered.stats.movesMade, 10)
        guard case .offered(let goals) = offered.snackRun else { return XCTFail("Expected an optional offer") }
        let choice = try XCTUnwrap(goals.first?.kind)
        var accepted = offered
        XCTAssertTrue(accepted.acceptSnackRun(choice))
        XCTAssertFalse(accepted.acceptSnackRun(choice))
        guard case .active(let active) = accepted.snackRun else { return XCTFail("The choice should start a run") }
        XCTAssertEqual(active.movesRemaining, ActiveSnackRun.moveLimit)
        XCTAssertEqual(accepted.stats, offered.stats)
        XCTAssertEqual(accepted.board.grid, offered.board.grid)

        var left = accepted
        left.skipSnackRun()
        XCTAssertEqual(left.snackRun, .idle)
        XCTAssertEqual(left.stats, accepted.stats)
        XCTAssertEqual(left.board.grid, accepted.board.grid)

        var shuffledOffer = offered
        XCTAssertFalse(shuffledOffer.triggerEmergencyShuffle().isEmpty)
        XCTAssertEqual(shuffledOffer.snackRun, .idle)
        XCTAssertEqual(shuffledOffer.stats.movesMade, 10)

        var shuffledRun = accepted
        XCTAssertFalse(shuffledRun.triggerEmergencyShuffle().isEmpty)
        XCTAssertEqual(shuffledRun.snackRun, accepted.snackRun)
        XCTAssertEqual(shuffledRun.stats.movesMade, 10)

        var skipped = offered
        skipped.skipSnackRun()
        XCTAssertEqual(skipped.snackRun, .idle)
        XCTAssertFalse(skipped.acceptSnackRun(choice))

        let next = try XCTUnwrap(MoveValidator.findBestHint(in: offered.board))
        XCTAssertEqual(play(next, in: &offered), play(next, in: &plain))
        XCTAssertEqual(offered.snackRun, .idle)
        XCTAssertEqual(offered.board.grid, plain.board.grid)
    }

    func testDashTracksCellsOnceIncludingSpecialClearsAndPuppyBlasts() {
        let a = GridPos(row: 2, col: 0), b = GridPos(row: 3, col: 2), c = GridPos(row: 4, col: 7)
        var dash = ActiveSnackRun(goal: .biltemaDash(receipts: [a, b, c]))
        dash.apply(SnackRunTurn(steps: [.matchCleared(positions: [a], cascadeDepth: 1, pointsAwarded: 0, matchedKinds: [.cupcake])]))
        XCTAssertEqual(dash.remainingReceipts, [b, c])
        XCTAssertEqual(dash.movesRemaining, 5)
        dash.apply(SnackRunTurn(steps: [.specialTriggered(kind: .fiestaBomb, origin: a, affectedPositions: [a, b], pointsAwarded: 0)]))
        XCTAssertEqual(dash.remainingReceipts, [c])
        dash.apply(SnackRunTurn(steps: [.puppyRescued(at: c, blastPositions: [c], pointsAwarded: 0)]))
        XCTAssertTrue(dash.isComplete)
    }

    func testPokeOrderRequiresTheNamedKindOnTwoSeparateTurns() {
        var order = ActiveSnackRun(goal: .pokeOrder(first: .hermanosTaco))
        func turn(_ kinds: [StandardTileKind]) -> SnackRunTurn {
            SnackRunTurn(steps: [.matchCleared(positions: [], cascadeDepth: 1, pointsAwarded: 0, matchedKinds: kinds)])
        }
        order.apply(SnackRunTurn(steps: [.specialTriggered(kind: .fiestaBomb, origin: GridPos(row: 3, col: 3),
                                                           affectedPositions: [GridPos(row: 3, col: 3)], pointsAwarded: 0)]))
        XCTAssertEqual(order.ingredientsMatched, 0)
        order.apply(turn([.partillePoke]))
        XCTAssertEqual(order.ingredientsMatched, 0)
        order.apply(turn([.hermanosTaco, .partillePoke]))
        XCTAssertEqual(order.ingredientsMatched, 1)
        XCTAssertFalse(order.isComplete)
        order.apply(turn([.hermanosTaco]))
        XCTAssertEqual(order.ingredientsMatched, 1)
        order.apply(turn([.partillePoke]))
        XCTAssertTrue(order.isComplete)
        XCTAssertEqual(order.movesRemaining, 1)
    }

    private func tierThirteenOffer(seed: UInt64 = 42) throws -> CascadeResolver {
        var game = CascadeResolver(seed: seed, startingTier: 13)
        for _ in 0..<10 {
            let move = try XCTUnwrap(MoveValidator.findBestHint(in: game.board))
            _ = play(move, in: &game)
        }
        XCTAssertEqual(game.stats.tier, 13)
        return game
    }

    private func outcome(_ steps: [BoardStep], for goal: SnackRunKind) -> (GridPos, Tile)? {
        for step in steps {
            if case .snackRunCompleted(goal, let at, let tile) = step { return (at, tile) }
        }
        return nil
    }

    private func pickMatch(_ ingredient: StandardTileKind, in game: CascadeResolver, matching: Bool) throws -> ValidMove {
        let moves = MoveValidator.findAllValidMoves(in: game.board)
        return try XCTUnwrap(moves.first { move in
            var simulated = game
            let steps = simulated.resolveSwap(from: move.from, to: move.to)
            return !simulated.isGameOver && SnackRunTurn(steps: steps).matchedKinds.contains(ingredient) == matching
        }, "Expected a valid swap \(matching ? "matching" : "avoiding") \(ingredient)")
    }

    func testPokeExpiresOnTheSixthSwapWithoutARewardOrScorePenalty() throws {
        var game = try tierThirteenOffer()
        XCTAssertTrue(game.acceptSnackRun(.pokeOrder))
        guard case .active(let run) = game.snackRun, case .pokeOrder(let ingredient) = run.goal
        else { return XCTFail("Expected the accepted order") }
        let position = GridPos(row: 0, col: 0)
        _ = game.performSwap(from: position, to: position)
        XCTAssertEqual(game.snackRun, .active(run))

        for used in 1...ActiveSnackRun.moveLimit {
            let move = try pickMatch(ingredient, in: game, matching: false)
            var plain = game
            let expected = plain.resolveSwap(from: move.from, to: move.to)
            let steps = play(move, in: &game)
            XCTAssertEqual(game.stats, plain.stats)
            XCTAssertEqual(game.board.grid, plain.board.grid)

            if used == ActiveSnackRun.moveLimit {
                XCTAssertEqual(game.snackRun, .idle)
                XCTAssertEqual(steps, expected + [.snackRunExpired(kind: .pokeOrder)])
            } else {
                guard case .active(let active) = game.snackRun else { return XCTFail("Order ended early") }
                XCTAssertEqual(active.movesRemaining, ActiveSnackRun.moveLimit - used)
                XCTAssertEqual(active.ingredientsMatched, 0)
                XCTAssertEqual(steps, expected)
            }
        }

        game.stats.movesMade = 34
        let next = try XCTUnwrap(MoveValidator.findBestHint(in: game.board))
        _ = play(next, in: &game)
        guard case .offered = game.snackRun else { return XCTFail("Next offer should still be at swap 35") }
    }

    func testLastAllowedSwapStillCompletesTheOrderAndPreservesTheRewardTile() throws {
        var game = try tierThirteenOffer()
        XCTAssertTrue(game.acceptSnackRun(.pokeOrder))
        guard case .active(let run) = game.snackRun, case .pokeOrder(let ingredient) = run.goal
        else { return XCTFail("Expected the accepted order") }
        let first = try pickMatch(ingredient, in: game, matching: true)
        _ = play(first, in: &game)
        for _ in 0..<4 {
            let move = try pickMatch(.partillePoke, in: game, matching: false)
            _ = play(move, in: &game)
        }
        guard case .active(let finishing) = game.snackRun else { return XCTFail("Expected one swap left") }
        XCTAssertEqual(finishing.movesRemaining, 1)
        XCTAssertEqual(finishing.ingredientsMatched, 1)
        let last = try pickMatch(.partillePoke, in: game, matching: true)
        var plain = game
        let normalSteps = plain.resolveSwap(from: last.from, to: last.to)
        let finalSteps = play(last, in: &game)
        let (position, reward) = try XCTUnwrap(outcome(finalSteps, for: .pokeOrder))
        let original = try XCTUnwrap(plain.board[position])
        XCTAssertEqual(original.special, .none)
        XCTAssertNil(original.snore)
        XCTAssertNotNil(original.kind.standardKind)
        XCTAssertEqual(reward, Tile(id: original.id, kind: original.kind, special: .fiestaBomb))
        XCTAssertEqual(game.board[position], reward)
        XCTAssertEqual(finalSteps, normalSteps + [.snackRunCompleted(kind: .pokeOrder, at: position, tile: reward)])
        XCTAssertEqual(game.stats.score, plain.stats.score)
        XCTAssertEqual(game.stats.fiestaBombsCreated, plain.stats.fiestaBombsCreated + 1)
        XCTAssertEqual(game.snackRun, .idle)
    }

    func testUnplayableBoardCannotOfferARunAndGameOverClearsAnAcceptedRun() throws {
        var game = try tierThirteenOffer()
        XCTAssertTrue(game.acceptSnackRun(.biltemaDash))
        for row in 0..<BoardState.rows {
            for col in 0..<BoardState.cols { game.board[row, col]?.snore = SnoreBubble() }
        }
        XCTAssertTrue(SnackRunPlanner.goals(for: game).isEmpty)
        game.stats.availableShuffles = 1
        let steps = game.triggerEmergencyShuffle()
        XCTAssertEqual(steps.last, .gameOver(reason: .noValidMoves))
        XCTAssertEqual(game.snackRun, .idle)
        XCTAssertFalse(game.acceptSnackRun(.biltemaDash))
    }

    func testBothSnackRunsChangeThePreferredSwapOnTheSameTierThirteenBoard() throws {
        let opening = try tierThirteenOffer()
        guard case .offered(let goals) = opening.snackRun else { return XCTFail("Expected the Tier 13 offer") }
        XCTAssertEqual(Set(goals.map(\.kind)), Set(SnackRunKind.allCases))
        func moves(in board: BoardState) -> [ValidMove] {
            MoveValidator.findAllValidMoves(in: board).flatMap { move in
                [move, ValidMove(from: move.to, to: move.from)]
            }
        }
        let openingMoves = moves(in: opening.board)
        let scoreFirst = try XCTUnwrap(openingMoves.map { move in
            var game = opening
            _ = play(move, in: &game)
            return (move, game.stats.score - opening.stats.score)
        }.max { $0.1 < $1.1 })
        func coordinates(_ move: ValidMove) -> String {
            "(\(move.from.row + 1), \(move.from.col + 1)) → (\(move.to.row + 1), \(move.to.col + 1))"
        }
        print("Tier 13 · seed 42 · score first: \(coordinates(scoreFirst.0)) +\(scoreFirst.1)")

        func pair(_ move: ValidMove) -> Set<GridPos> { [move.from, move.to] }
        var objectiveMoves = Set<Set<GridPos>>()
        for goal in goals {
            let kind = goal.kind
            var branch = opening
            XCTAssertTrue(branch.acceptSnackRun(kind))
            XCTAssertEqual(branch.board.grid, opening.board.grid)
            let paths = openingMoves.compactMap { first -> (move: ValidMove, moves: Int, points: Int, reward: Tile)? in
                var after = branch
                let firstSteps = play(first, in: &after)
                if let reward = outcome(firstSteps, for: kind) {
                    return (first, 1, after.stats.score - opening.stats.score, reward.1)
                }
                guard case .active(let active) = after.snackRun,
                      kind == .biltemaDash || active.ingredientsMatched > 0
                else { return nil }
                for second in moves(in: after.board) {
                    var finish = after
                    if let reward = outcome(play(second, in: &finish), for: kind) {
                        XCTAssertEqual(finish.board[reward.0], reward.1)
                        return (first, 2, after.stats.score - opening.stats.score, reward.1)
                    }
                }
                return nil
            }
            let goalFirst = try XCTUnwrap(paths.min { ($0.moves, -$0.points) < ($1.moves, -$1.points) })
            print("Tier 13 · \(kind.title): \(coordinates(goalFirst.move)) +\(goalFirst.points), finished in \(goalFirst.moves) swaps")
            XCTAssertNotEqual(pair(goalFirst.move), pair(scoreFirst.0), "\(kind) should favor a different opening swap on this fixture")
            XCTAssertFalse(paths.contains { pair($0.move) == pair(scoreFirst.0) }, "The score-first move should miss the two-swap route")
            objectiveMoves.insert(pair(goalFirst.move))
            switch kind {
            case .biltemaDash:
                guard case .korvRocket = goalFirst.reward.special else { return XCTFail("Expected a Korv Rocket") }
            case .pokeOrder:
                XCTAssertEqual(goalFirst.reward.special, .fiestaBomb)
            }
        }
        XCTAssertEqual(objectiveMoves.count, 2)
    }
}
