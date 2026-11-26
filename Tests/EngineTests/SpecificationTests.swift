import XCTest
@testable import Engine

final class SpecificationTests: XCTestCase {
    private let cells = (0..<9).flatMap { row in (0..<8).map { GridPos(row: row, col: $0) } }

    private func at(_ row: Int, _ col: Int) -> GridPos { GridPos(row: row, col: col) }

    // All six standard tiles are valid, but this repeating layout has no matches or legal swaps.
    private func cleanBoard(seed: UInt64 = 1) -> BoardState {
        var board = BoardState(seed: seed)
        let pattern: [StandardTileKind] = [.hermanosTaco, .partillePoke, .biltemaCombo, .teido]
        for p in cells {
            board[p] = board.makeTile(kind: .standard(pattern[(p.row * 2 + p.col) % pattern.count]))
        }
        return board
    }

    private func put(_ kind: TileKind, at p: GridPos, on board: inout BoardState, special: SpecialModifier = .none) {
        board[p] = board.makeTile(kind: kind, special: special)
    }

    private func lock(_ p: GridPos, hits: Int = 1, on board: inout BoardState) {
        let bubble = board.makeSnoreBubble(hits: hits)
        board[p]?.snore = bubble
    }

    private func makeTriple(
        _ kind: StandardTileKind, row: Int = 7, col: Int = 0, in board: inout BoardState
    ) -> ValidMove {
        let from = at(row + 1, col + 2)
        let to = at(row, col + 2)
        if board[to]?.kind == .standard(kind) {
            put(.standard(kind == .cupcake ? .bigMac : .cupcake), at: to, on: &board)
        }
        for p in [at(row, col), at(row, col + 1), from] {
            put(.standard(kind), at: p, on: &board)
        }
        return ValidMove(from: from, to: to)
    }

    private func swap(_ move: ValidMove, in resolver: inout CascadeResolver) -> [BoardStep] {
        resolver.performSwap(from: move.from, to: move.to)
    }

    private func depths(_ steps: [BoardStep]) -> [Int] {
        steps.compactMap {
            guard case .matchCleared(_, let depth, _, _) = $0 else { return nil }
            return depth
        }
    }

    private func trigger(_ kind: SpecialActivationKind, in steps: [BoardStep]) throws -> (GridPos, Set<GridPos>, Int) {
        try XCTUnwrap(steps.lazy.compactMap { step in
            guard case .specialTriggered(kind, let origin, let cells, let score) = step else { return nil }
            return (origin, Set(cells), score)
        }.first)
    }

    private func matchPoints(_ steps: [BoardStep]) throws -> Int {
        try XCTUnwrap(steps.lazy.compactMap {
            guard case .matchCleared(_, _, let points, _) = $0 else { return nil }
            return points
        }.first)
    }

    func testOpeningBoardAcrossSeedCorpus() {
        XCTAssertEqual(BoardState.rows, 9)
        XCTAssertEqual(BoardState.cols, 8)
        XCTAssertEqual(Set(StandardTileKind.allCases.map(\.displayName)), [
            "Cupcake", "Teido", "Hermanos Taco", "Partille Poke Bowl", "Biltema Combo", "Big Mac"
        ])
        for seed in 0...127 {
            let board = CascadeResolver(seed: UInt64(seed)).board
            let tiles = board.grid.flatMap { $0 }.compactMap { $0 }
            XCTAssertEqual(tiles.count, 72, "seed \(seed)")
            XCTAssertEqual(Set(tiles.map(\.id)).count, 72, "seed \(seed)")
            XCTAssertTrue(tiles.allSatisfy { $0.kind.standardKind != nil && $0.special == .none && $0.snore == nil })
            XCTAssertTrue(board.findMatches().isEmpty, "seed \(seed)")
            let moves = MoveValidator.findAllValidMoves(in: board)
            XCTAssertGreaterThanOrEqual(moves.count, 3, "seed \(seed)")
            XCTAssertEqual(Set(moves).count, moves.count)
            XCTAssertTrue(moves.allSatisfy { $0.from < $0.to && $0.from.isAdjacent(to: $0.to) })
            XCTAssertTrue(moves.contains(MoveValidator.findBestHint(in: board)!))
        }
    }

    func testRevertedSwapsLeaveBoardScoreCadenceAndSeedUntouched() {
        var resolver = CascadeResolver()
        resolver.board = cleanBoard()
        let before = resolver
        for (a, b) in [(at(0, 0), at(0, 0)), (at(0, 0), at(1, 1)), (at(0, 0), at(-1, 0)),
                       (at(0, 7), at(0, 8)), (at(8, 0), at(9, 0)), (at(0, 0), at(0, 1))] {
            XCTAssertFalse(MoveValidator.isValidSwap(from: a, to: b, in: resolver.board))
            XCTAssertEqual(resolver.performSwap(from: a, to: b), [.swap(from: a, to: b, reverted: true)])
        }
        XCTAssertEqual(resolver.board.grid, before.board.grid)
        XCTAssertEqual(resolver.stats, before.stats)
        XCTAssertEqual(resolver.movesSinceLastSnore, before.movesSinceLastSnore)
        var original = before.board.rng
        XCTAssertEqual(resolver.board.rng.next(), original.next())
    }

    func testUnrelatedExistingMatchDoesNotLegalizeSwap() {
        var board = cleanBoard()
        for column in 0...2 { put(.standard(.bigMac), at: at(0, column), on: &board) }
        XCTAssertEqual(board.findMatches().count, 1)
        XCTAssertFalse(MoveValidator.isValidSwap(from: at(8, 6), to: at(8, 7), in: board))
        put(.standard(.bigMac), at: at(1, 1), on: &board)
        XCTAssertFalse(MoveValidator.isValidSwap(from: at(0, 1), to: at(1, 1), in: board))
    }

    func testMatchDetectorSeparatesRunsAndExcludesObstaclesAndDiagonals() {
        var board = cleanBoard()
        for row in 0...2 { put(.standard(.bigMac), at: at(row, 0), on: &board) }
        for column in 4...6 { put(.standard(.bigMac), at: at(5, column), on: &board) }
        for i in 0...2 { put(.standard(.cupcake), at: at(5 + i, i), on: &board) }
        XCTAssertEqual(board.findMatches().map(\.positions), [
            Set([at(0, 0), at(1, 0), at(2, 0)]), Set([at(5, 4), at(5, 5), at(5, 6)])
        ])
        lock(at(1, 0), on: &board)
        for obstacle in [TileKind.padThai, .puppy, .standard(.bigMac)] {
            put(obstacle, at: at(5, 5), on: &board, special: obstacle.standardKind == nil ? .none : .goldenSwirl)
            XCTAssertTrue(board.findMatches().isEmpty)
        }
    }

    func testHorizontalSwipeCreatesVerticalRocketAndTMatchCreatesBombAtIntersection() {
        var resolver = CascadeResolver()
        resolver.board = cleanBoard()
        for p in [at(1, 4), at(2, 4), at(4, 4), at(3, 5)] {
            put(.standard(.bigMac), at: p, on: &resolver.board)
        }
        let rocket = resolver.performSwap(from: at(3, 5), to: at(3, 4))
        XCTAssertTrue(rocket.contains {
            guard case .specialCreated(let pos, let tile) = $0 else { return false }
            return pos == at(3, 4) && tile.special == .korvRocket(.vertical)
        })

        resolver.board = cleanBoard()
        for p in [at(2, 4), at(3, 4), at(4, 3), at(4, 5), at(5, 4)] {
            put(.standard(.cupcake), at: p, on: &resolver.board)
        }
        let bomb = resolver.performSwap(from: at(5, 4), to: at(4, 4))
        XCTAssertTrue(bomb.contains {
            guard case .specialCreated(let pos, let tile) = $0 else { return false }
            return pos == at(4, 4) && tile.special == .fiestaBomb
        })
    }

    func testSingleSpecialGeometryAtBoardEdges() throws {
        let scenarios: [(SpecialModifier, SpecialActivationKind, Set<GridPos>)] = [
            (.korvRocket(.horizontal), .korvRocketHorizontal, Set(cells.filter { $0.row == 0 })),
            (.korvRocket(.vertical), .korvRocketVertical, Set(cells.filter { $0.col == 0 })),
            (.fiestaBomb, .fiestaBomb, Set([at(0, 0), at(0, 1), at(1, 0), at(1, 1)]))
        ]
        for (modifier, kind, expected) in scenarios {
            var resolver = CascadeResolver()
            resolver.board = cleanBoard()
            let move = makeTriple(.bigMac, row: 0, in: &resolver.board)
            resolver.board[0, 0]?.special = modifier
            let steps = swap(move, in: &resolver)
            let (origin, affected, _) = try trigger(kind, in: steps)
            XCTAssertEqual(origin, at(0, 0))
            // The three matched cells are already gone when the special fires.
            XCTAssertEqual(affected, expected.subtracting([at(0, 0), at(0, 1), at(0, 2)]))
        }
    }

    func testEveryPairOfSpecialsActivatesInBothSwapDirections() throws {
        let rocket = SpecialModifier.korvRocket(.horizontal)
        let bomb = SpecialModifier.fiestaBomb
        let swirl = SpecialModifier.goldenSwirl
        let pairs: [(SpecialModifier, SpecialModifier, SpecialActivationKind)] = [
            (rocket, rocket, .rocketPlusRocket), (rocket, bomb, .rocketPlusBomb),
            (bomb, bomb, .bombPlusBomb), (swirl, rocket, .swirlPlusRocket),
            (swirl, bomb, .swirlPlusBomb), (swirl, swirl, .swirlPlusSwirl)
        ]
        for (first, second, effect) in pairs {
            for reversed in [false, true] {
                var resolver = CascadeResolver()
                resolver.board = cleanBoard()
                let a = at(4, 3)
                let b = at(4, 4)
                put(.standard(.biltemaCombo), at: a, on: &resolver.board, special: first)
                put(.standard(.hermanosTaco), at: b, on: &resolver.board, special: second)
                let move = ValidMove(from: reversed ? b : a, to: reversed ? a : b)
                let steps = swap(move, in: &resolver)
                let (origin, affected, points) = try trigger(effect, in: steps)
                XCTAssertEqual(origin, move.to)
                XCTAssertTrue(affected.isSuperset(of: [a, b]))
                XCTAssertGreaterThan(points, 0)
                switch effect {
                case .rocketPlusRocket: XCTAssertEqual(affected, Set(cells.filter { $0.row == origin.row || $0.col == origin.col }))
                case .rocketPlusBomb: XCTAssertEqual(affected, Set(cells.filter {
                    abs($0.row - origin.row) <= 1 || abs($0.col - origin.col) <= 1
                }))
                case .bombPlusBomb: XCTAssertEqual(affected, Set(cells.filter {
                    abs($0.row - origin.row) <= 2 && abs($0.col - origin.col) <= 2
                }))
                case .swirlPlusSwirl: XCTAssertEqual(affected, Set(cells))
                default: XCTAssertGreaterThan(affected.count, 9)
                }
            }
        }
    }

    func testSpecialBlastChainsIntoAnotherSpecialAndRetainsPuppies() throws {
        var resolver = CascadeResolver()
        resolver.board = cleanBoard()
        put(.standard(.biltemaCombo), at: at(4, 3), on: &resolver.board, special: .korvRocket(.horizontal))
        put(.standard(.hermanosTaco), at: at(4, 4), on: &resolver.board, special: .fiestaBomb)
        put(.standard(.teido), at: at(4, 7), on: &resolver.board, special: .korvRocket(.vertical))
        put(.puppy, at: at(6, 7), on: &resolver.board)
        let steps = resolver.performSwap(from: at(4, 3), to: at(4, 4))
        XCTAssertEqual(try trigger(.korvRocketVertical, in: steps).0, at(4, 7))
        XCTAssertFalse(try trigger(.korvRocketVertical, in: steps).1.contains(at(6, 7)))
    }

    func testDoubleBubbleTakesOneHitPerAdjacentMatchAndNoDiagonalHit() {
        var resolver = CascadeResolver(seed: 1, startingTier: 4)
        resolver.board = cleanBoard()
        let bubble = at(5, 1)
        let diagonal = at(5, 3)
        lock(bubble, hits: 2, on: &resolver.board)
        lock(diagonal, on: &resolver.board)
        let move = makeTriple(.bigMac, row: 6, in: &resolver.board)
        let steps = swap(move, in: &resolver)
        XCTAssertTrue(steps.contains(.snoreDamaged(at: bubble, remainingHits: 1)))
        XCTAssertFalse(steps.contains { if case .snorePopped(diagonal, _) = $0 { return true }; return false })

        guard let remaining = resolver.board.snorePositionsOldestFirst.first else {
            return XCTFail("Expected the damaged bubble to survive")
        }
        // Recreate the second match next to the surviving bubble without resetting its hit count.
        let survivor = resolver.board[remaining]?.snore
        XCTAssertEqual(survivor?.hitsRemaining, 1)
        resolver.board = cleanBoard()
        resolver.board[bubble]?.snore = survivor
        let second = makeTriple(.bigMac, row: 6, in: &resolver.board)
        XCTAssertTrue(swap(second, in: &resolver).contains {
            if case .snorePopped(bubble, let bonus) = $0 { return bonus > 0 }
            return false
        })
    }

    func testOneSwapCanCompleteTwoIndependentMatchesNextToDoubleBubble() {
        var resolver = CascadeResolver(seed: 1, startingTier: 4)
        resolver.board = cleanBoard()
        // The vertical swap completes two horizontal runs bordering the bubble.
        let center = at(4, 3)
        lock(center, hits: 2, on: &resolver.board)
        for p in [at(4, 0), at(4, 1), at(5, 2)] { put(.standard(.bigMac), at: p, on: &resolver.board) }
        for p in [at(5, 3), at(5, 4), at(4, 2)] { put(.standard(.cupcake), at: p, on: &resolver.board) }
        let steps = resolver.performSwap(from: at(4, 2), to: at(5, 2))
        XCTAssertTrue(steps.contains(.snoreDamaged(at: center, remainingHits: 1)))
        XCTAssertTrue(steps.contains { if case .snorePopped(center, _) = $0 { return true }; return false })
    }

    func testLockedTilesFallAndDriftingSnoreMovesOnlyOnThirdTurn() throws {
        var resolver = CascadeResolver(seed: 1, startingTier: 8)
        let origin = at(4, 0)
        let target = at(3, 0)
        for turn in 1...3 {
            resolver.board = cleanBoard()
            resolver.board[origin]?.snore = SnoreBubble(isDrifting: true, turnsSinceDrift: turn - 1, spawnedOrder: 9)
            let move = makeTriple(.bigMac, col: 4, in: &resolver.board)
            let steps = swap(move, in: &resolver)
            XCTAssertEqual(steps.contains(.snoreDrifted(from: origin, to: target)), turn == 3)
            XCTAssertEqual(resolver.board[turn == 3 ? target : origin]?.snore?.turnsSinceDrift, turn % 3)
        }

        resolver.board = cleanBoard()
        lock(at(0, 0), hits: 2, on: &resolver.board)
        let id = try XCTUnwrap(resolver.board[0, 0]?.id)
        let move = makeTriple(.bigMac, in: &resolver.board)
        let steps = swap(move, in: &resolver)
        XCTAssertTrue(steps.contains {
            guard case .gravityApplied(let moves) = $0 else { return false }
            return moves.contains(TileMove(tileId: id, from: at(0, 0), to: at(1, 0)))
        })
        XCTAssertTrue(resolver.board.grid.flatMap { $0 }.contains { $0?.id == id && $0?.isLockedBySnore == true })
    }

    func testDrifterCannotLeaveTopEdgeOrDisplaceALockedOrPuppyTile() {
        for obstacle in [TileKind.puppy, .padThai, .standard(.teido), nil] {
            var resolver = CascadeResolver(startingTier: 8)
            resolver.board = cleanBoard()
            let origin = at(obstacle == nil ? 0 : 4, 0)
            if let obstacle {
                let above = at(3, 0)
                put(obstacle, at: above, on: &resolver.board)
                if obstacle.standardKind != nil { lock(above, on: &resolver.board) }
            }
            resolver.board[origin]?.snore = SnoreBubble(isDrifting: true, turnsSinceDrift: 2, spawnedOrder: 99)
            let move = makeTriple(.bigMac, col: 4, in: &resolver.board)
            let steps = swap(move, in: &resolver)
            XCTAssertFalse(steps.contains { if case .snoreDrifted = $0 { return true }; return false })
            XCTAssertEqual(resolver.board[origin]?.snore?.spawnedOrder, 99)
            XCTAssertEqual(resolver.board[origin]?.snore?.turnsSinceDrift, 0)
        }
    }

    func testSnoreCadenceAndAvatarWarningUsePlayerTurnsAndConfiguredVariants() throws {
        for (tier, cadence) in [(1, 6), (3, 6), (4, 5), (7, 5), (8, 4), (12, 4), (13, 3), (40, 3)] {
            var variants = Set<[Bool]>()
            for seed in 1...16 {
                var resolver = CascadeResolver(seed: UInt64(seed), startingTier: tier)
                resolver.board = cleanBoard(seed: UInt64(seed))
                let move = makeTriple(.bigMac, in: &resolver.board)
                resolver.movesSinceLastSnore = cadence - 2
                let warning = swap(move, in: &resolver)
                guard depths(warning) == [1] else { continue }
                XCTAssertEqual(resolver.snoreMeterProgress, Double(cadence - 1) / Double(cadence), accuracy: 0.0001)
                XCTAssertTrue(warning.contains(.avatarReaction(.teidoNoddingOff)))
                resolver.board = cleanBoard(seed: UInt64(seed))
                let spawn = swap(makeTriple(.bigMac, in: &resolver.board), in: &resolver)
                let bubble = try XCTUnwrap(spawn.lazy.compactMap { step -> SnoreBubble? in
                    guard case .snoreSpawned(let p, let bubble) = step else { return nil }
                    XCTAssertNotNil(resolver.board[p]?.kind.standardKind)
                    return bubble
                }.first)
                variants.insert([bubble.isDoubleZzz, bubble.isDrifting])
                XCTAssertEqual(resolver.snoreMeterProgress, 0)
            }
            XCTAssertTrue(variants.contains([false, false]))
            XCTAssertEqual(variants.contains { $0[0] }, tier >= 4)
            XCTAssertEqual(variants.contains { $0[1] }, tier >= 8)
        }
    }

    func testSnoreAlertAtFiveAndNaturalOverloadAtTwelve() {
        for startingLocks in [4, 10, 11] {
            var resolver = CascadeResolver()
            resolver.board = cleanBoard(seed: 2)
            for p in cells.prefix(startingLocks) { lock(p, on: &resolver.board) }
            resolver.movesSinceLastSnore = 5
            let move = makeTriple(.bigMac, in: &resolver.board)
            let steps = swap(move, in: &resolver)
            XCTAssertTrue(steps.contains(.avatarReaction(.cupcakeSnoreAlert)))
            XCTAssertEqual(resolver.board.activeSnoreCount, startingLocks + 1)
            XCTAssertEqual(resolver.isGameOver, startingLocks == 11)
            if startingLocks == 11 {
                XCTAssertEqual(steps.last, .gameOver(reason: .snoreOverload))
                let frozen = resolver.stats
                XCTAssertTrue(swap(move, in: &resolver).isEmpty)
                XCTAssertTrue(resolver.triggerEmergencyShuffle().isEmpty)
                XCTAssertEqual(resolver.stats, frozen)
            }
        }
    }

    func testPuppyBlastFootprintScoreAndFullBoardAtBothRadii() throws {
        for tier in [1, 12, 13, 25] {
            for col in [0, 4, 7] {
                var resolver = CascadeResolver(seed: 1, startingTier: tier)
                resolver.board = cleanBoard()
                let (matchCol, puppyCol) = (min(max(0, col - 1), 5), col)
                let move = ValidMove(from: at(7, matchCol + (col == 7 ? 0 : 2)), to: at(8, matchCol + (col == 7 ? 0 : 2)))
                for c in matchCol...matchCol + 2 where c != move.to.col {
                    put(.standard(.bigMac), at: at(8, c), on: &resolver.board)
                }
                put(.standard(.bigMac), at: move.from, on: &resolver.board)
                put(.puppy, at: at(7, puppyCol), on: &resolver.board)
                let before = resolver
                let steps = swap(move, in: &resolver)
                let rescue = try XCTUnwrap(steps.lazy.compactMap { step -> (GridPos, Set<GridPos>, Int)? in
                    guard case .puppyRescued(let position, let affected, let points) = step else { return nil }
                    return (position, Set(affected), points)
                }.first)
                let radius = tier < 13 ? 1 : 2
                XCTAssertEqual(rescue.0, at(8, col))
                XCTAssertEqual(rescue.1, Set(cells.filter { $0.row >= 8 - radius && abs($0.col - col) <= radius }))
                XCTAssertGreaterThan(rescue.2, try matchPoints(steps))
                XCTAssertEqual(resolver.stats.puppiesRescued, 1)
                XCTAssertTrue(steps.contains(.avatarReaction(.cupcakeCheerPuppy)))
                assertTurn(before: before, after: resolver, steps: steps)
            }
        }
    }

    func testPuppyScoreThresholdAndConcurrentLimits() {
        for (tier, active) in [(1, 0), (1, 1), (7, 1), (8, 1), (8, 2), (13, 2)] {
            for crossing in [false, true] {
                var resolver = CascadeResolver(startingTier: tier)
                resolver.board = cleanBoard()
                for col in 0..<active { put(.puppy, at: at(0, 7 - col), on: &resolver.board) }
                let move = makeTriple(.bigMac, in: &resolver.board)
                let points = Int((180 * resolver.currentConfig.baseScoreMultiplier).rounded())
                resolver.stats.score = resolver.nextPuppyScoreThreshold - points - (crossing ? 0 : 1)
                let steps = swap(move, in: &resolver)
                let shouldSpawn = crossing && active < resolver.currentConfig.maxSimultaneousPuppies
                XCTAssertEqual(steps.contains {
                    guard case .puppySpawned(let p, let tile) = $0 else { return false }
                    return p.row == 0 && tile.kind == .puppy
                }, shouldSpawn, "tier \(tier), puppies \(active), crossing \(crossing)")
                XCTAssertEqual(resolver.board.activePuppyCount, active + (shouldSpawn ? 1 : 0))
            }
        }
    }

    func testTwoPuppiesCanLandTogetherAndRescueBlastAwardsItsSnoreBonus() {
        var resolver = CascadeResolver(startingTier: 13)
        resolver.board = cleanBoard()
        for col in 0...1 {
            put(.puppy, at: at(7, col), on: &resolver.board)
            put(.standard(.bigMac), at: at(8, col), on: &resolver.board)
        }
        put(.standard(.bigMac), at: at(7, 2), on: &resolver.board)
        lock(at(7, 3), hits: 2, on: &resolver.board)
        let before = resolver
        let steps = resolver.performSwap(from: at(7, 2), to: at(8, 2))
        XCTAssertEqual(resolver.stats.puppiesRescued, 2)
        XCTAssertEqual(resolver.board.activePuppyCount, 0)
        XCTAssertEqual(resolver.stats.snoreBubblesPopped, 1)
        XCTAssertTrue(steps.contains {
            if case .snorePopped(let pos, let score) = $0 { return pos == at(7, 3) && score > 0 }
            return false
        })
        assertTurn(before: before, after: resolver, steps: steps)
    }

    func testDifficultyBoundariesAndAlternatingSurges() {
        let rows: [(Int, Int, Int, Double)] = [
            (1, 6, 12_000, 1), (3, 6, 9_231, 1), (4, 5, 20_000, 1.5), (7, 5, 20_000, 1.5),
            (8, 4, 30_000, 2), (9, 4, 23_077, 2), (12, 4, 30_000, 2),
            (13, 3, 40_000, 2.25), (14, 3, 40_000, 2.5), (15, 3, 30_769, 2.75), (40, 3, 40_000, 9)
        ]
        for (tier, cadence, interval, multiplier) in rows {
            let config = DifficultyConfig.forTier(tier)
            XCTAssertEqual(config.snoreSpawnCadence, cadence)
            XCTAssertEqual(config.basePuppyPointInterval, interval)
            XCTAssertEqual(config.baseScoreMultiplier, multiplier)
            XCTAssertEqual(config.allowsDoubleZzz, tier >= 4)
            XCTAssertEqual(config.allowsDriftingSnore, tier >= 8)
            XCTAssertEqual(config.maxSimultaneousPuppies, tier >= 8 ? 2 : 1)
            XCTAssertEqual(config.puppyBlastRadius, tier >= 13 ? 2 : 1)
            XCTAssertEqual(config.tierTileTarget, Int((45 * pow(1.18, Double(tier - 1))).rounded()))
        }
        for tier in 1...30 {
            XCTAssertEqual(CravingSurge.forTier(tier), tier % 6 == 3 ? .cupcake : tier % 6 == 0 ? .teido : .none)
        }
    }

    func testEndlessTierTargetsSaturateAtTheNumericLimit() {
        let config = DifficultyConfig.forTier(10_000)
        XCTAssertEqual(config.tier, 10_000)
        XCTAssertEqual(config.tierTileTarget, Int.max)
        XCTAssertEqual(config.baseScoreMultiplier, 2_499)
    }

    func testCupcakeSurgeOnlyBoostsHerTwoSnacksByExactly25Percent() throws {
        for kind in StandardTileKind.allCases {
            var points: [Int] = []
            for tier in [2, 3, 4, 5, 6] {
                var resolver = CascadeResolver(startingTier: tier)
                resolver.board = cleanBoard()
                points.append(try matchPoints(swap(makeTriple(kind, in: &resolver.board), in: &resolver)))
            }
            let isFavorite = kind == .cupcake || kind == .bigMac
            XCTAssertEqual(Double(points[1]), Double(points[0]) * (isFavorite ? 1.25 : 1.0))
            XCTAssertEqual(points[2], points[3])
            XCTAssertEqual(points[3], points[4])
        }
    }

    func testPadThaiAdjacentMatchClearsCrossAndBoostsMatchBy25Percent() throws {
        var natural = CascadeResolver(startingTier: 6)
        natural.board = cleanBoard()
        let move = makeTriple(.bigMac, row: 5, col: 1, in: &natural.board)
        var feast = natural
        let pad = at(4, 2)
        put(.padThai, at: pad, on: &feast.board)
        let untouched = swap(move, in: &natural)
        let boosted = swap(move, in: &feast)
        let (origin, cross, extra) = try trigger(.padThaiCross, in: boosted)
        XCTAssertEqual(origin, pad)
        XCTAssertEqual(cross, [pad, at(3, 2), at(4, 1), at(4, 3)])
        XCTAssertGreaterThan(extra, 0)
        XCTAssertEqual(try matchPoints(boosted), try Int((Double(matchPoints(untouched)) * 1.25).rounded()))
    }

    func testTierAdvanceCarriesProgressAndEarnsOnlyEveryThirdCompletionUpToTwo() {
        for (tier, shuffles) in [(2, 0), (3, 0), (3, 1), (3, 2), (5, 1), (6, 0), (6, 2)] {
            var resolver = CascadeResolver(startingTier: tier)
            resolver.board = cleanBoard()
            resolver.stats.availableShuffles = shuffles
            resolver.stats.tierProgress = resolver.currentConfig.tierTileTarget - 1
            lock(at(0, 7), hits: 2, on: &resolver.board)
            let move = makeTriple(.bigMac, in: &resolver.board)
            let before = resolver
            let steps = swap(move, in: &resolver)
            let earnsShuffle = tier % 3 == 0 && shuffles < 2
            XCTAssertEqual(resolver.stats.tier, tier + 1)
            let cleared = steps.reduce(0) { count, step in
                switch step {
                case .matchCleared(let positions, _, _, _), .specialTriggered(_, _, let positions, _):
                    return count + positions.count
                case .specialCreated: return count - 1
                default: return count
                }
            }
            XCTAssertEqual(resolver.stats.tierProgress, cleared - 1)
            XCTAssertEqual(resolver.stats.availableShuffles, shuffles + (earnsShuffle ? 1 : 0))
            XCTAssertEqual(resolver.stats.teidoSurgesTriggered, tier == 5 ? 1 : 0)
            XCTAssertEqual(resolver.board.activeSnoreCount, 0)
            XCTAssertTrue(steps.contains {
                guard case .tierUp(let newTier, let surge, let banner, let popped, let bonus, let earned) = $0 else { return false }
                return newTier == tier + 1 && surge == CravingSurge.forTier(newTier) && !banner.isEmpty
                    && popped == [at(0, 7)] && bonus > 0 && earned == earnsShuffle
            })
            assertTurn(before: before, after: resolver, steps: steps)
        }
    }

    func testPuppyCadenceUsesIntervalOfNewTier() {
        var resolver = CascadeResolver(startingTier: 2)
        resolver.board = cleanBoard()
        resolver.stats.tierProgress = resolver.currentConfig.tierTileTarget - 1
        let move = makeTriple(.bigMac, in: &resolver.board)
        _ = swap(move, in: &resolver)
        XCTAssertEqual(resolver.stats.tier, 3)
        XCTAssertEqual(resolver.nextPuppyScoreThreshold - resolver.stats.score, 9_231)
    }

    func testTierUpSettlesAMatchPreviouslyMaskedByALock() {
        var resolver = CascadeResolver(startingTier: 2)
        resolver.board = cleanBoard()
        resolver.stats.tierProgress = resolver.currentConfig.tierTileTarget - 1
        let masked = Set((4...6).map { at(0, $0) })
        for p in masked { put(.standard(.bigMac), at: p, on: &resolver.board) }
        lock(at(0, 5), on: &resolver.board)
        let move = makeTriple(.cupcake, in: &resolver.board)
        let before = resolver
        let steps = swap(move, in: &resolver)
        guard let tierUp = steps.firstIndex(where: { if case .tierUp = $0 { return true }; return false }) else {
            return XCTFail("Expected Tier 3")
        }
        XCTAssertTrue(steps.suffix(from: tierUp).contains {
            guard case .matchCleared(let cells, let depth, _, _) = $0 else { return false }
            return depth > 1 && Set(cells).isSuperset(of: masked)
        })
        assertTurn(before: before, after: resolver, steps: steps)
    }

    func testRefillBottomToTopPadThaiIsSurgeOnlyAndAntimatchAtSix() {
        for (tier, surge) in [(1, CravingSurge.none), (3, .cupcake), (6, .teido), (12, .teido), (13, .none)] {
            var sawPadThai = false
            for seed in 1...24 {
                var board = cleanBoard(seed: UInt64(seed))
                for p in cells where p.row < 3 { board[p] = nil }
                let spawns = TileSpawner.refillEmptySlots(board: &board, tier: tier, cascadeDepth: 6, surge: surge)
                XCTAssertEqual(spawns.count, 24)
                XCTAssertEqual(Set(spawns.map(\.at)), Set(cells.filter { $0.row < 3 }))
                XCTAssertTrue(board.findMatches().isEmpty)
                for col in 0..<8 {
                    XCTAssertEqual(spawns.filter { $0.at.col == col }.map { $0.at.row }, [2, 1, 0])
                }
                for spawn in spawns {
                    XCTAssertEqual(board[spawn.at], spawn.tile)
                    XCTAssertGreaterThan(spawn.spawnRowOffset, 0)
                    sawPadThai = sawPadThai || spawn.tile.kind == .padThai
                }
            }
            XCTAssertEqual(sawPadThai, surge == .teido)
        }
    }

    func testRefillWeightLiftsCupcakeAtEachMercyThreshold() {
        for tier in [1, 3, 4, 10, 15] {
            let threshold = tier <= 3 ? 3 : 5
            let baseWeight = tier <= 3 ? 125 : 105
            for snoreCount in [threshold - 1, threshold] {
                for seed in 0..<64 {
                    var board = BoardState(seed: UInt64(seed))
                    for p in cells.dropFirst(8).prefix(snoreCount) {
                        put(.standard(.teido), at: p, on: &board)
                        lock(p, on: &board)
                    }
                    // The first generated position is (8, 0), with no setup/clump modifiers.
                    var rng = board.rng
                    let cupcakeWeight = snoreCount == threshold ? baseWeight : 100
                    let kinds = StandardTileKind.allCases
                    let roll = rng.nextInt(upperBound: cupcakeWeight + 500)
                    let expected = roll < cupcakeWeight ? .cupcake : kinds[1 + (roll - cupcakeWeight) / 100]
                    let first = TileSpawner.refillEmptySlots(board: &board, tier: tier, cascadeDepth: 1, surge: .none).first
                    XCTAssertEqual(first?.at, at(8, 0))
                    XCTAssertEqual(first?.tile.kind, .standard(expected))
                }
            }
        }
    }

    func testWeightedRefillCountsOnlyOrthogonalNeighborsForAMatchSetup() {
        for tier in [1, 7, 10, 14, 15, 30] {
            let clampedTier = min(tier, 15)
            let assist = max(-20, 50 - clampedTier * 5)
            let affinity = max(-25, 20 - clampedTier * 3)
            let profile = SpawnDifficultyProfile.forTier(tier)
            XCTAssertEqual(profile.matchAssistBonus, assist)
            XCTAssertEqual(profile.clumpAffinity, affinity)
            for adjacent in [false, true] {
                for seed in 1...48 {
                    var board = BoardState(seed: UInt64(seed))
                    put(.standard(.cupcake), at: at(8, adjacent ? 1 : 2), on: &board)
                    let weight = adjacent ? 100 + assist + affinity : 100
                    var rng = board.rng
                    let roll = rng.nextInt(upperBound: weight + 500)
                    let kinds = StandardTileKind.allCases
                    let expected = roll < weight ? kinds[0] : kinds[1 + (roll - weight) / 100]
                    let first = TileSpawner.refillEmptySlots(board: &board, tier: tier, cascadeDepth: 1, surge: .none).first
                    XCTAssertEqual(first?.tile.kind, .standard(expected), "tier \(tier), seed \(seed), adjacent \(adjacent)")
                }
            }
        }
    }

    func testSilentRescueEditsOnlyRecentSpawnsAndIsAtomicOnFailure() throws {
        var board = cleanBoard()
        XCTAssertTrue(MoveValidator.findAllValidMoves(in: board).isEmpty)
        XCTAssertNil(MoveValidator.findBestHint(in: board))
        let positions = [at(0, 0), at(0, 1), at(1, 2)]
        let recent = positions.map { TileSpawn(tile: board[$0]!, at: $0, spawnRowOffset: 2) }
        let before = board
        let changes = try XCTUnwrap(TileSpawner.silentDeadlockRescue(board: &board, recentSpawns: recent))
        XCTAssertTrue(Set(changes.map(\.at)).isSubset(of: positions))
        XCTAssertTrue(board.findMatches().isEmpty)
        XCTAssertFalse(MoveValidator.findAllValidMoves(in: board).isEmpty)
        for p in cells where !positions.contains(p) { XCTAssertEqual(board[p], before[p]) }

        board = cleanBoard()
        let stale = TileSpawn(tile: before[0, 0]!, at: at(0, 0), spawnRowOffset: 1)
        put(.standard(.teido), at: stale.at, on: &board)
        let current = board
        XCTAssertNil(TileSpawner.silentDeadlockRescue(board: &board, recentSpawns: [stale]))
        XCTAssertEqual(board.grid, current.grid)
        XCTAssertEqual(board.nextTileId, current.nextTileId)
        var originalRNG = current.rng
        XCTAssertEqual(board.rng.next(), originalRNG.next())
    }

    func testEmergencyShufflePreservesLockedPuppiesAndInventoryAndEmitsMoves() {
        var resolver = CascadeResolver()
        resolver.board = cleanBoard()
        lock(at(2, 0), hits: 2, on: &resolver.board)
        put(.puppy, at: at(3, 1), on: &resolver.board)
        put(.standard(.cupcake), at: at(4, 1), on: &resolver.board, special: .fiestaBomb)
        let before = resolver
        XCTAssertEqual(resolver.stats.availableShuffles, 1)
        let steps = resolver.triggerEmergencyShuffle()
        guard case .boardShuffled(let moves, true) = steps.first else { return XCTFail("Expected one paid shuffle") }
        XCTAssertFalse(moves.isEmpty)
        XCTAssertEqual(resolver.stats.availableShuffles, 0)
        XCTAssertEqual(resolver.stats.movesMade, 0)
        XCTAssertEqual(resolver.board[2, 0], before.board[2, 0])
        XCTAssertEqual(resolver.board[3, 1], before.board[3, 1])
        XCTAssertEqual(Set(resolver.board.grid.flatMap { $0 }), Set(before.board.grid.flatMap { $0 }))
        XCTAssertTrue(resolver.triggerEmergencyShuffle().isEmpty)
        assertTurn(before: before, after: resolver, steps: steps)
    }

    func testDeadlockTriesRefillThenShuffleAndEndsOnlyAfterLifelinesAreGone() {
        for (snoreDue, shuffles) in [(false, 0), (false, 1), (true, 1), (true, 0)] {
            var resolver = CascadeResolver()
            resolver.board = cleanBoard(seed: snoreDue ? 47 : 1)
            // A bubble at (1, 2) walls off the three new cells. With the
            // passage open, the refill can be rerolled to allow a legal swap.
            for p in [at(0, 3), at(1, 0), at(1, 1), at(1, 3)] {
                lock(p, hits: 2, on: &resolver.board)
            }
            put(.standard(.hermanosTaco), at: at(0, 2), on: &resolver.board)
            for p in [at(0, 0), at(0, 1), at(1, 2)] { put(.standard(.bigMac), at: p, on: &resolver.board) }
            resolver.movesSinceLastSnore = snoreDue ? 5 : 0
            resolver.stats.availableShuffles = shuffles
            let before = resolver
            let steps = resolver.performSwap(from: at(1, 2), to: at(0, 2))
            XCTAssertEqual(resolver.gameOverReason, snoreDue && shuffles == 0 ? .noValidMoves : nil)
            XCTAssertEqual(resolver.stats.availableShuffles, snoreDue ? 0 : shuffles)
            let spawns = steps.compactMap { step -> [TileSpawn]? in
                if case .tilesSpawned(let spawns) = step { return spawns }
                return nil
            }
            if snoreDue {
                XCTAssertEqual(spawns.count, 1)
                XCTAssertEqual(steps.contains {
                    if case .boardShuffled(let moves, true) = $0 { return !moves.isEmpty }
                    return false
                }, shuffles == 1)
            } else {
                XCTAssertEqual(spawns.count, 2)
                if let rescue = spawns.last {
                    XCTAssertTrue(rescue.allSatisfy { $0.at.row == 0 && $0.at.col <= 2 })
                }
            }
            assertTurn(before: before, after: resolver, steps: steps)
        }
    }

    func testSeededPlayWithCascadesSettlesAndEveryStepReplays() {
        var witnessedDeepCascade = false
        var witnessedTeidoAchievement = false
        var witnessedComboPuppy = false
        for seed in 1...16 {
            var resolver = CascadeResolver(seed: UInt64(seed), startingTier: seed % 2 == 0 ? 6 : 1)
            var mirror = resolver
            for turn in 0..<12 {
                guard !resolver.isGameOver else { break }
                let chosen = MoveValidator.findAllValidMoves(in: resolver.board)
                guard !chosen.isEmpty else { return XCTFail("Seed \(seed), turn \(turn) was stranded") }
                let move = chosen[(seed * 7 + turn * 3) % chosen.count]
                let before = resolver
                let steps = swap(move, in: &resolver)
                let location = "seed \(seed), turn \(turn)"
                XCTAssertEqual(steps, swap(move, in: &mirror), location)
                assertTurn(before: before, after: resolver, steps: steps, message: location)
                let depth = depths(steps).last ?? 1
                witnessedDeepCascade = witnessedDeepCascade || depth >= 5
                XCTAssertLessThanOrEqual(depth, 6, location)
                if depth > 1 { XCTAssertEqual(resolver.movesSinceLastSnore, before.movesSinceLastSnore, location) }
                if depth >= 4 {
                    XCTAssertTrue(steps.contains(.avatarReaction(.teidoComboWakeUp(cascadeDepth: depth))), location)
                    if before.board.activePuppyCount == 0 && resolver.stats.score < before.nextPuppyScoreThreshold {
                        XCTAssertTrue(steps.contains { if case .puppySpawned = $0 { return true }; return false }, location)
                        witnessedComboPuppy = true
                    }
                }
                if depth >= 3 && before.currentConfig.surge == .teido {
                    let rockets = steps.filter {
                        guard case .teidoComboAchievement(_, let tile) = $0 else { return false }
                        if case .korvRocket = tile.special { return true }
                        return false
                    }
                    XCTAssertEqual(rockets.count, 1, location)
                    XCTAssertTrue(steps.contains(.avatarReaction(.teidoAchievementUnlocked)), location)
                    witnessedTeidoAchievement = true
                }
            }
        }
        XCTAssertTrue(witnessedDeepCascade)
        XCTAssertTrue(witnessedTeidoAchievement)
        XCTAssertTrue(witnessedComboPuppy)
    }

    func testSixAutomaticWavesUseAntiMatchRefillToReturnControl() {
        var resolver = CascadeResolver(seed: 2)
        let count = 8
        var witnessed = false
        for turn in 0..<count {
            let moves = MoveValidator.findAllValidMoves(in: resolver.board)
            guard !moves.isEmpty else { return XCTFail("Seed 2 was stranded") }
            let move = moves[(2 * 7 + turn * 3) % moves.count]
            let before = resolver
            let steps = swap(move, in: &resolver)
            if depths(steps).last == 6 {
                XCTAssertEqual(depths(steps), Array(1...6))
                XCTAssertEqual(resolver.stats.maxCascadeReached, 6)
                assertTurn(before: before, after: resolver, steps: steps)
                witnessed = true
                break
            }
        }
        XCTAssertTrue(witnessed, "Seed 2 must exercise Anti-Match Mode")
    }

    private func assertTurn(
        before: CascadeResolver, after: CascadeResolver, steps: [BoardStep], message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var replay = before.board
        var points = 0
        func moveTiles(_ moves: [TileMove]) {
            let moving = moves.map { replay[$0.from] }
            for (move, tile) in zip(moves, moving) {
                XCTAssertEqual(tile?.id, move.tileId, "\(message) movement source \(move.from)", file: file, line: line)
                replay[move.from] = nil
            }
            for (move, tile) in zip(moves, moving) { replay[move.to] = tile }
        }
        for step in steps {
            switch step {
            case .swap(let a, let b, false): replay.swapTiles(at: a, and: b)
            case .matchCleared(let positions, _, let score, _), .specialTriggered(_, _, let positions, let score),
                 .puppyRescued(_, let positions, let score):
                for p in positions { replay[p] = nil }
                points += score
            case .specialCreated(let p, let tile), .puppySpawned(let p, let tile), .teidoComboAchievement(let p, let tile),
                 .snackRunCompleted(_, let p, let tile):
                replay[p] = tile
            case .gravityApplied(let moves), .boardShuffled(let moves, _): moveTiles(moves)
            case .tilesSpawned(let spawns):
                for spawn in spawns { replay[spawn.at] = spawn.tile }
            case .snoreSpawned(let p, let bubble): replay[p]?.snore = bubble
            case .snoreDrifted(let from, let to):
                let drifting = replay[from]?.snore
                replay[to]?.snore = drifting
                replay[from]?.snore = nil
            case .snoreDamaged(let p, let hits): replay[p]?.snore?.hitsRemaining = hits
            case .snorePopped(let p, let score):
                replay[p]?.snore = nil
                points += score
            case .tierUp(_, _, _, let popped, let score, _):
                for p in popped { replay[p]?.snore = nil }
                points += score
            default: break
            }
        }
        let mismatch = cells.first { p in
            var expected = after.board[p]
            var observed = replay[p]
            expected?.snore?.turnsSinceDrift = 0
            observed?.snore?.turnsSinceDrift = 0
            return expected != observed
        }
        XCTAssertNil(mismatch, "\(message) replay differs from board", file: file, line: line)
        XCTAssertEqual(after.stats.score - before.stats.score, points, message, file: file, line: line)
        XCTAssertTrue(cells.allSatisfy { after.board[$0] != nil }, "\(message) holes in settled board", file: file, line: line)
        XCTAssertTrue(after.board.findMatches().isEmpty, "\(message) unresolved matches", file: file, line: line)
        XCTAssertTrue(after.isGameOver || !MoveValidator.findAllValidMoves(in: after.board).isEmpty,
                      "\(message) no playable moves", file: file, line: line)
    }
}
