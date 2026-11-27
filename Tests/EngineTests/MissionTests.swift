import XCTest
@testable import Engine

final class MissionTests: XCTestCase {
    func testMissionBoardsAreRepeatableAndPlayByTheirOwnMoveBudget() throws {
        var layouts: Set<[[Tile?]]> = []
        for mission in MiniMission.allCases {
            var game = CascadeResolver(mission: mission)
            let retry = CascadeResolver(mission: mission)
            XCTAssertTrue(layouts.insert(game.board.grid).inserted)
            XCTAssertEqual(game.board.grid, retry.board.grid)
            XCTAssertEqual(game.mission?.movesRemaining, mission.moveLimit)
            XCTAssertTrue(game.board.findMatches().isEmpty)

            let move = try XCTUnwrap(MoveValidator.findBestHint(in: game.board))
            _ = game.performSwap(from: move.from, to: move.from)
            XCTAssertEqual(game.mission?.movesRemaining, mission.moveLimit)
            XCTAssertTrue(game.triggerEmergencyShuffle().isEmpty)
            let steps = game.performSwap(from: move.from, to: move.to)
            XCTAssertEqual(game.mission?.movesRemaining, mission.moveLimit - 1)
            XCTAssertGreaterThan(game.stats.score, 0)
            XCTAssertEqual(game.stats.tier, 1)
            XCTAssertEqual(game.snackRun, .idle)
            XCTAssertFalse(steps.contains { step in
                switch step {
                case .puppySpawned, .snoreSpawned, .tierUp: true
                default: false
                }
            })
        }
    }

    func testPuppyPickupRequiresBothRescuesWithinTheBudget() {
        var attempt = MissionAttempt(.puppyPickup)
        let pos = GridPos(row: 8, col: 0)
        let rescue = BoardStep.puppyRescued(at: pos, blastPositions: [pos], pointsAwarded: 1_000)
        attempt.finishTurn([rescue], deadlocked: false)
        XCTAssertEqual(attempt.puppiesHome, 1)
        XCTAssertNil(attempt.result)
        while attempt.movesRemaining > 1 { attempt.finishTurn([], deadlocked: false) }
        attempt.finishTurn([rescue], deadlocked: true)
        XCTAssertEqual(attempt.puppiesHome, 2)
        XCTAssertEqual(attempt.result, .cleared)
        XCTAssertEqual(attempt.movesRemaining, 0)
    }

    func testBiltemaDeliveryRequiresARocketBlastThatReachesTheCounter() throws {
        var attempt = MissionAttempt(.biltemaDelivery)
        let counter = try XCTUnwrap(attempt.definition.counter)
        let away = GridPos(row: 0, col: 0)
        attempt.finishTurn([.matchCleared(positions: [counter], cascadeDepth: 1, pointsAwarded: 900, matchedKinds: [.biltemaCombo])], deadlocked: false)
        attempt.finishTurn([.specialTriggered(kind: .fiestaBomb, origin: away, affectedPositions: [counter], pointsAwarded: 900)], deadlocked: false)
        attempt.finishTurn([.specialTriggered(kind: .korvRocketHorizontal, origin: away, affectedPositions: [away], pointsAwarded: 900)], deadlocked: false)
        XCTAssertNil(attempt.result)
        attempt.finishTurn([.specialTriggered(kind: .korvRocketHorizontal, origin: counter, affectedPositions: [counter], pointsAwarded: 900)], deadlocked: false)
        XCTAssertEqual(attempt.result, .cleared)
    }

    func testCouchCoopRequiresCombiningThePowerUpsAndCanFail() {
        var attempt = MissionAttempt(.couchCoop)
        let at = GridPos(row: 2, col: 2)
        let rocket = BoardStep.specialTriggered(kind: .korvRocketVertical, origin: at, affectedPositions: [at], pointsAwarded: 900)
        let bomb = BoardStep.specialTriggered(kind: .fiestaBomb, origin: at, affectedPositions: [at], pointsAwarded: 900)
        while attempt.movesRemaining > 1 { attempt.finishTurn([rocket, bomb], deadlocked: false) }
        XCTAssertNil(attempt.result)
        var winning = attempt
        winning.finishTurn([.specialTriggered(kind: .rocketPlusBomb, origin: at, affectedPositions: [at], pointsAwarded: 900)], deadlocked: false)
        XCTAssertEqual(winning.result, .cleared)
        attempt.finishTurn([rocket, bomb], deadlocked: false)
        XCTAssertEqual(attempt.result, .outOfSwaps)
    }

    func testTheSameMissionBoardsRewardGoalFocusedSwapsOverScoreChasing() throws {
        let solutions: [(MiniMission, [[Int]])] = [
            (.puppyPickup, [[6, 0, 7, 0], [3, 5, 3, 6], [5, 0, 5, 1], [7, 1, 8, 1]]),
            (.biltemaDelivery, [[7, 5, 7, 6], [1, 5, 2, 5], [8, 6, 8, 7]]),
            (.couchCoop, [[7, 1, 7, 2], [5, 2, 6, 2], [4, 2, 5, 2], [4, 2, 4, 3]]),
        ]
        for (definition, path) in solutions {
            var directed = CascadeResolver(mission: definition)
            var greedy = directed
            for swap in path {
                let from = GridPos(row: swap[0], col: swap[1])
                let to = GridPos(row: swap[2], col: swap[3])
                XCTAssertTrue(MoveValidator.isValidSwap(from: from, to: to, in: directed.board), "\(definition): \(swap)")
                _ = directed.performSwap(from: from, to: to)
            }
            XCTAssertEqual(directed.mission?.result, .cleared, definition.title)
            XCTAssertEqual(directed.stats.movesMade, path.count)
            XCTAssertTrue(directed.isGameOver)
            let finished = directed.board.grid
            _ = directed.performSwap(from: GridPos(row: 0, col: 0), to: GridPos(row: 0, col: 1))
            XCTAssertEqual(directed.board.grid, finished)

            while !greedy.isGameOver {
                let moves = MoveValidator.findAllValidMoves(in: greedy.board)
                greedy = try XCTUnwrap(moves.flatMap { [$0, ValidMove(from: $0.to, to: $0.from)] }.map { move in
                    var candidate = greedy
                    _ = candidate.performSwap(from: move.from, to: move.to)
                    return candidate
                }.max { $0.stats.score < $1.stats.score })
            }
            XCTAssertEqual(greedy.mission?.result, .outOfSwaps, definition.title)
            XCTAssertGreaterThan(greedy.stats.score, 0)
        }
    }
}
