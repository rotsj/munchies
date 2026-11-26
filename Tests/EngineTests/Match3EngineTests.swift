import XCTest
@testable import Engine

final class Match3EngineTests: XCTestCase {

    private func makeCleanBoard(seed: UInt64 = 1) -> BoardState {
        var board = BoardState(seed: seed)
        let pattern: [StandardTileKind] = [.hermanosTaco, .partillePoke, .biltemaCombo, .teido]
        for r in 0..<BoardState.rows {
            for c in 0..<BoardState.cols {
                let kind = pattern[(r * 2 + c) % pattern.count]
                board[r, c] = board.makeTile(kind: .standard(kind))
            }
        }
        return board
    }

    func testInitialBoardHasZeroMatchesAndAtLeastThreeValidMoves() {
        for seed: UInt64 in [1, 42, 1337, 99999, 20261126] {
            var board = BoardState(seed: seed)
            TileSpawner.populateInitialBoard(board: &board, tier: 1)

            XCTAssertTrue(board.findMatches().isEmpty, "Seed \(seed) should have zero pre-existing matches")
            let moves = MoveValidator.findAllValidMoves(in: board)
            XCTAssertGreaterThanOrEqual(moves.count, 3, "Seed \(seed) must guarantee >= 3 opening swaps")
        }
    }

    func testSeededGenerationIsDeterministic() {
        var boardA = BoardState(seed: 777)
        TileSpawner.populateInitialBoard(board: &boardA)

        var boardB = BoardState(seed: 777)
        TileSpawner.populateInitialBoard(board: &boardB)

        for r in 0..<BoardState.rows {
            for c in 0..<BoardState.cols {
                XCTAssertEqual(boardA[r, c]?.kind, boardB[r, c]?.kind)
            }
        }
    }

    func testMatch4CreatesPerpendicularKorvRocket() {
        var resolver = CascadeResolver(seed: 10)
        resolver.board = makeCleanBoard(seed: 10)

        resolver.board[4, 0] = resolver.board.makeTile(kind: .standard(.bigMac))
        resolver.board[4, 1] = resolver.board.makeTile(kind: .standard(.bigMac))
        resolver.board[4, 3] = resolver.board.makeTile(kind: .standard(.bigMac))
        resolver.board[5, 2] = resolver.board.makeTile(kind: .standard(.bigMac))

        let steps = resolver.performSwap(from: GridPos(row: 5, col: 2), to: GridPos(row: 4, col: 2))

        let createdRocket = steps.contains { step in
            if case .specialCreated(_, let tile) = step {
                return tile.special == .korvRocket(.horizontal)
            }
            return false
        }
        XCTAssertTrue(createdRocket)
    }

    func testMatch5LShapeCreatesFiestaBomb() {
        var resolver = CascadeResolver(seed: 11)
        resolver.board = makeCleanBoard(seed: 11)

        resolver.board[0, 2] = resolver.board.makeTile(kind: .standard(.cupcake))
        resolver.board[1, 2] = resolver.board.makeTile(kind: .standard(.cupcake))
        resolver.board[2, 0] = resolver.board.makeTile(kind: .standard(.cupcake))
        resolver.board[2, 1] = resolver.board.makeTile(kind: .standard(.cupcake))
        resolver.board[2, 3] = resolver.board.makeTile(kind: .standard(.cupcake))

        let steps = resolver.performSwap(from: GridPos(row: 2, col: 3), to: GridPos(row: 2, col: 2))

        let createdBomb = steps.contains { step in
            if case .specialCreated(_, let tile) = step {
                return tile.special == .fiestaBomb
            }
            return false
        }
        XCTAssertTrue(createdBomb)
        XCTAssertEqual(resolver.stats.fiestaBombsCreated, 1)
    }

    func testMatch5StraightLineCreatesGoldenSwirl() {
        var resolver = CascadeResolver(seed: 12)
        resolver.board = makeCleanBoard(seed: 12)

        resolver.board[3, 1] = resolver.board.makeTile(kind: .standard(.teido))
        resolver.board[3, 2] = resolver.board.makeTile(kind: .standard(.teido))
        resolver.board[3, 4] = resolver.board.makeTile(kind: .standard(.teido))
        resolver.board[3, 5] = resolver.board.makeTile(kind: .standard(.teido))
        resolver.board[4, 3] = resolver.board.makeTile(kind: .standard(.teido))

        let steps = resolver.performSwap(from: GridPos(row: 4, col: 3), to: GridPos(row: 3, col: 3))

        let createdSwirl = steps.contains { step in
            if case .specialCreated(_, let tile) = step {
                return tile.special == .goldenSwirl
            }
            return false
        }
        XCTAssertTrue(createdSwirl)
    }

    func testKorvRocketPlusFiestaBombClearsThreeRowsAndThreeColumns() {
        var resolver = CascadeResolver(seed: 13)
        resolver.board = makeCleanBoard(seed: 13)

        let rocketPos = GridPos(row: 4, col: 3)
        let bombPos = GridPos(row: 4, col: 4)
        resolver.board[rocketPos] = resolver.board.makeTile(kind: .standard(.biltemaCombo), special: .korvRocket(.horizontal))
        resolver.board[bombPos] = resolver.board.makeTile(kind: .standard(.hermanosTaco), special: .fiestaBomb)

        let steps = resolver.performSwap(from: rocketPos, to: bombPos)

        let comboStep = steps.first { step in
            if case .specialTriggered(.rocketPlusBomb, _, _, _) = step { return true }
            return false
        }
        guard case .specialTriggered(.rocketPlusBomb, _, let affected, _) = comboStep else {
            XCTFail("Expected rocketPlusBomb trigger")
            return
        }
        XCTAssertEqual(affected.count, 42)
    }

    func testGoldenSwirlZapsAllMatchingStandardTiles() {
        var resolver = CascadeResolver(seed: 14)
        resolver.board = makeCleanBoard(seed: 14)

        let swirlPos = GridPos(row: 4, col: 3)
        let bigMacPos = GridPos(row: 4, col: 4)
        resolver.board[swirlPos] = resolver.board.makeTile(kind: .standard(.cupcake), special: .goldenSwirl)
        resolver.board[bigMacPos] = resolver.board.makeTile(kind: .standard(.bigMac))
        resolver.board[0, 0] = resolver.board.makeTile(kind: .standard(.bigMac))
        resolver.board[8, 7] = resolver.board.makeTile(kind: .standard(.bigMac))

        let steps = resolver.performSwap(from: swirlPos, to: bigMacPos)

        let swirlStep = steps.first { step in
            if case .specialTriggered(.goldenSwirl, _, _, _) = step { return true }
            return false
        }
        guard case .specialTriggered(.goldenSwirl, _, let affected, _) = swirlStep else {
            XCTFail("Expected goldenSwirl trigger")
            return
        }
        XCTAssertTrue(affected.contains(GridPos(row: 0, col: 0)))
        XCTAssertTrue(affected.contains(GridPos(row: 8, col: 7)))
        XCTAssertTrue(affected.contains(bigMacPos))
    }

    func testSnoreLockedTileCannotBeSwapped() {
        var resolver = CascadeResolver(seed: 15)
        resolver.board = makeCleanBoard(seed: 15)
        let pos = GridPos(row: 4, col: 4)
        let bubble = resolver.board.makeSnoreBubble(hits: 1)
        resolver.board[pos]?.snore = bubble

        XCTAssertFalse(MoveValidator.isValidSwap(from: pos, to: GridPos(row: 4, col: 5), in: resolver.board))
        let steps = resolver.performSwap(from: pos, to: GridPos(row: 4, col: 5))
        XCTAssertEqual(steps, [.swap(from: pos, to: GridPos(row: 4, col: 5), reverted: true)])
    }

    func testAdjacentMatchDamagesDoubleZzz() {
        var resolver = CascadeResolver(seed: 16)
        resolver.board = makeCleanBoard(seed: 16)

        let snorePos = GridPos(row: 3, col: 1)
        let doubleBubble = resolver.board.makeSnoreBubble(hits: 2)
        resolver.board[snorePos]?.snore = doubleBubble

        resolver.board[4, 0] = resolver.board.makeTile(kind: .standard(.bigMac))
        resolver.board[4, 1] = resolver.board.makeTile(kind: .standard(.bigMac))
        resolver.board[5, 2] = resolver.board.makeTile(kind: .standard(.bigMac))

        let steps = resolver.performSwap(from: GridPos(row: 5, col: 2), to: GridPos(row: 4, col: 2))

        let damaged = steps.contains { step in
            if case .snoreDamaged(let at, let remaining) = step {
                return at == snorePos && remaining == 1
            }
            return false
        }
        XCTAssertTrue(damaged)
    }

    func testCupcakePacifierPassivePopsOldestSnoreAnywhereOnBoard() {
        var resolver = CascadeResolver(seed: 17)
        resolver.board = makeCleanBoard(seed: 17)

        let oldestPos = GridPos(row: 0, col: 0)
        let newerPos = GridPos(row: 0, col: 7)
        let oldBubble = resolver.board.makeSnoreBubble(hits: 1)
        let newBubble = resolver.board.makeSnoreBubble(hits: 1)
        resolver.board[oldestPos]?.snore = oldBubble
        resolver.board[newerPos]?.snore = newBubble

        resolver.board[7, 0] = resolver.board.makeTile(kind: .standard(.cupcake))
        resolver.board[7, 1] = resolver.board.makeTile(kind: .standard(.cupcake))
        resolver.board[7, 3] = resolver.board.makeTile(kind: .standard(.cupcake))
        resolver.board[8, 2] = resolver.board.makeTile(kind: .standard(.cupcake))

        let steps = resolver.performSwap(from: GridPos(row: 8, col: 2), to: GridPos(row: 7, col: 2))

        let pacifierFired = steps.contains { step in
            if case .cupcakePacifierWave(_, let poppedAt) = step {
                return poppedAt == oldestPos
            }
            return false
        }
        XCTAssertTrue(pacifierFired)
        XCTAssertNil(resolver.board[oldestPos]?.snore)
        XCTAssertNotNil(resolver.board[newerPos]?.snore)
    }

    func testSnoreOverloadTriggersGameOverAt12Bubbles() {
        var resolver = CascadeResolver(seed: 18)
        resolver.board = makeCleanBoard(seed: 18)

        for r in 0..<2 {
            for c in 0..<6 {
                let bubble = resolver.board.makeSnoreBubble(hits: 1)
                resolver.board[r, c]?.snore = bubble
            }
        }
        XCTAssertEqual(resolver.board.activeSnoreCount, 12)

        resolver.board[7, 0] = resolver.board.makeTile(kind: .standard(.bigMac))
        resolver.board[7, 1] = resolver.board.makeTile(kind: .standard(.bigMac))
        resolver.board[8, 2] = resolver.board.makeTile(kind: .standard(.bigMac))

        let steps = resolver.performSwap(from: GridPos(row: 8, col: 2), to: GridPos(row: 7, col: 2))
        XCTAssertTrue(resolver.isGameOver)
        XCTAssertEqual(resolver.gameOverReason, .snoreOverload)
        XCTAssertTrue(steps.contains(.gameOver(reason: .snoreOverload)))
    }

    func testPuppyReachingBottomRowTriggersRescueAndBlast() {
        var resolver = CascadeResolver(seed: 19)
        resolver.board = makeCleanBoard(seed: 19)

        resolver.board[7, 1] = resolver.board.makeTile(kind: .puppy)
        resolver.board[8, 0] = resolver.board.makeTile(kind: .standard(.bigMac))
        resolver.board[8, 1] = resolver.board.makeTile(kind: .standard(.bigMac))
        resolver.board[7, 2] = resolver.board.makeTile(kind: .standard(.bigMac))

        let steps = resolver.performSwap(from: GridPos(row: 7, col: 2), to: GridPos(row: 8, col: 2))

        let rescued = steps.contains { step in
            if case .puppyRescued(let at, let blast, _) = step {
                return at == GridPos(row: 8, col: 1) && blast.count >= 4
            }
            return false
        }
        XCTAssertTrue(rescued)
        XCTAssertEqual(resolver.stats.puppiesRescued, 1)
    }

    func testCravingSurgeAlternatesEveryThreeTiers() {
        XCTAssertEqual(CravingSurge.forTier(1), .none)
        XCTAssertEqual(CravingSurge.forTier(3), .cupcake)
        XCTAssertEqual(CravingSurge.forTier(6), .teido)
        XCTAssertEqual(CravingSurge.forTier(9), .cupcake)
        XCTAssertEqual(CravingSurge.forTier(12), .teido)

        let tier2 = DifficultyConfig.forTier(2)
        let tier3 = DifficultyConfig.forTier(3)
        XCTAssertLessThan(tier3.basePuppyPointInterval, tier2.basePuppyPointInterval)

        let tier13 = DifficultyConfig.forTier(13)
        XCTAssertEqual(tier13.snoreSpawnCadence, 3)
        XCTAssertEqual(tier13.puppyBlastRadius, 2)
        XCTAssertEqual(tier13.baseScoreMultiplier, 2.25, accuracy: 0.001)
    }

    func testPadThaiSwapClearsCrossAndAwardsBonus() {
        var resolver = CascadeResolver(seed: 20, startingTier: 6)
        resolver.board = makeCleanBoard(seed: 20)

        let padPos = GridPos(row: 4, col: 4)
        let neighbor = GridPos(row: 4, col: 5)
        resolver.board[padPos] = resolver.board.makeTile(kind: .padThai)

        XCTAssertTrue(MoveValidator.isValidSwap(from: padPos, to: neighbor, in: resolver.board))
        let steps = resolver.performSwap(from: padPos, to: neighbor)

        let padTriggered = steps.contains { step in
            if case .specialTriggered(.padThaiCross, _, let affected, let pts) = step {
                return affected.count == 5 && pts > 0
            }
            return false
        }
        XCTAssertTrue(padTriggered)
    }

    func testSpawnDifficultyProfileMatchesSpecFormula() {
        let t1 = SpawnDifficultyProfile.forTier(1)
        XCTAssertEqual(t1.matchAssistBonus, 45)
        XCTAssertEqual(t1.clumpAffinity, 17)
        XCTAssertEqual(t1.cupcakeMercyThreshold, 3)
        XCTAssertEqual(t1.maxAutoCascadeDepth, 6)

        let t15 = SpawnDifficultyProfile.forTier(15)
        XCTAssertEqual(t15.matchAssistBonus, -20)
        XCTAssertEqual(t15.clumpAffinity, -25)
        XCTAssertEqual(t15.cupcakeMercyThreshold, 5)
    }

    func testTierUpPopsAllSnoresAndGrantsShuffleEveryThirdTier() {
        var resolver = CascadeResolver(seed: 21, startingTier: 3)
        resolver.board = makeCleanBoard(seed: 21)
        resolver.stats.availableShuffles = 1
        resolver.stats.tierProgress = resolver.currentConfig.tierTileTarget - 2

        let snoreA = resolver.board.makeSnoreBubble(hits: 1)
        let snoreB = resolver.board.makeSnoreBubble(hits: 2)
        resolver.board[0, 0]?.snore = snoreA
        resolver.board[0, 7]?.snore = snoreB

        resolver.board[7, 0] = resolver.board.makeTile(kind: .standard(.bigMac))
        resolver.board[7, 1] = resolver.board.makeTile(kind: .standard(.bigMac))
        resolver.board[8, 2] = resolver.board.makeTile(kind: .standard(.bigMac))

        let steps = resolver.performSwap(from: GridPos(row: 8, col: 2), to: GridPos(row: 7, col: 2))

        XCTAssertEqual(resolver.stats.tier, 4)
        XCTAssertEqual(resolver.board.activeSnoreCount, 0)
        XCTAssertEqual(resolver.stats.availableShuffles, 2)
        XCTAssertTrue(steps.contains { step in
            if case .tierUp(let newTier, _, _, let popped, _, let earnedShuffle) = step {
                return newTier == 4 && popped.count == 2 && earnedShuffle
            }
            return false
        })
    }
}
