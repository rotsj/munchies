/// Pure-Swift Match-3 Engine & step-by-step Cascade Resolver.
/// Zero browser/JS imports — runs identically on macOS XCTest and SwiftWasm.
public struct CascadeResolver: Sendable {
    public var board: BoardState
    public var stats: RunStats
    public var movesSinceLastSnore: Int
    public var nextPuppyScoreThreshold: Int
    public var isGameOver: Bool
    public var gameOverReason: GameOverReason?

    public init(seed: UInt64 = 42, startingTier: Int = 1) {
        var initialBoard = BoardState(seed: seed)
        TileSpawner.populateInitialBoard(board: &initialBoard, tier: startingTier)
        self.board = initialBoard
        var initialStats = RunStats()
        initialStats.tier = max(1, startingTier)
        self.stats = initialStats
        self.movesSinceLastSnore = 0
        let cfg = DifficultyConfig.forTier(startingTier)
        self.nextPuppyScoreThreshold = cfg.basePuppyPointInterval
        self.isGameOver = false
        self.gameOverReason = nil
    }

    public var currentConfig: DifficultyConfig {
        DifficultyConfig.forTier(stats.tier)
    }

    public var snoreMeterProgress: Double {
        let cadence = max(1, currentConfig.snoreSpawnCadence)
        return min(1.0, Double(movesSinceLastSnore) / Double(cadence))
    }

    public var tierProgressFraction: Double {
        let target = max(1, currentConfig.tierTileTarget)
        return min(1.0, Double(stats.tierProgress) / Double(target))
    }

    public mutating func performSwap(from a: GridPos, to b: GridPos) -> [BoardStep] {
        guard !isGameOver else { return [] }
        guard MoveValidator.isValidSwap(from: a, to: b, in: board) else {
            return [.swap(from: a, to: b, reverted: true)]
        }

        var steps: [BoardStep] = []
        let swipeAxis: SwipeAxis = (a.row == b.row) ? .horizontal : .vertical

        board.swapTiles(at: a, and: b)
        steps.append(.swap(from: a, to: b, reverted: false))
        stats.movesMade += 1

        var totalTilesClearedThisTurn = 0
        var rescuedPuppyThisTurn = false
        var matchedBigMacThisTurn = false
        var matchedCupcakesThisTurn = 0
        var teidoAchievementTriggered = false

        let swappedA = board[a]
        let swappedB = board[b]
        let handledDirectActivation = resolveDirectSwapActivation(
            posA: a,
            tileA: swappedA,
            posB: b,
            tileB: swappedB,
            steps: &steps,
            tilesCleared: &totalTilesClearedThisTurn,
            matchedBigMac: &matchedBigMacThisTurn
        )

        var cascadeDepth = handledDirectActivation ? 1 : 0
        var lastSpawns = handledDirectActivation ? applyGravityAndRefill(cascadeDepth: 1, steps: &steps) : []
        var hazardUpdated = false
        var progressApplied = 0
        var puppyIntervalCrossed = false
        let maxDepth = SpawnDifficultyProfile.forTier(stats.tier).maxAutoCascadeDepth

        while true {
            if checkAndRescuePuppies(
                steps: &steps, rescuedFlag: &rescuedPuppyThisTurn, tilesCleared: &totalTilesClearedThisTurn
            ) {
                lastSpawns = applyGravityAndRefill(cascadeDepth: cascadeDepth, steps: &steps)
                continue
            }

            var groups = board.findMatches()
            if groups.isEmpty {
                if !hazardUpdated {
                    updateDriftingSnores(steps: &steps)
                    hazardUpdated = true
                }
                if board.activeSnoreCount >= DifficultyConfig.snoreLoseThreshold {
                    stats.maxCascadeReached = max(stats.maxCascadeReached, cascadeDepth)
                    steps.append(.avatarReaction(.cupcakeSnoreAlert))
                    endRun(.snoreOverload, steps: &steps)
                    return steps
                }
                if totalTilesClearedThisTurn > progressApplied {
                    puppyIntervalCrossed = puppyIntervalCrossed || reachedPuppyScoreThreshold
                    advanceTierProgress(tilesCleared: totalTilesClearedThisTurn - progressApplied, steps: &steps)
                    progressApplied = totalTilesClearedThisTurn
                }
                groups = board.findMatches()
                if groups.isEmpty { break }
            }
            if cascadeDepth == maxDepth {
                // A bubble can expose a match by leaving a cell after the final refill.
                // Neutralize those runs at the cap while preserving the affected tiles.
                let changes = TileSpawner.settleMatchesAtCascadeLimit(board: &board, groups: groups)
                steps.append(.tilesSpawned(spawns: changes))
                continue
            }

            cascadeDepth += 1

            resolveMatchWave(
                groups: groups,
                cascadeDepth: cascadeDepth,
                swipeAxis: cascadeDepth == 1 ? swipeAxis : nil,
                preferredSwapPositions: cascadeDepth == 1 ? [b, a] : [],
                steps: &steps,
                tilesCleared: &totalTilesClearedThisTurn,
                matchedBigMac: &matchedBigMacThisTurn,
                matchedCupcakes: &matchedCupcakesThisTurn
            )

            if currentConfig.surge == .teido && cascadeDepth >= 3 && !teidoAchievementTriggered {
                teidoAchievementTriggered = true
                spawnTeidoAchievementRocket(steps: &steps)
            }

            lastSpawns = applyGravityAndRefill(cascadeDepth: cascadeDepth, steps: &steps)
        }
        stats.maxCascadeReached = max(stats.maxCascadeReached, cascadeDepth)
        advanceSnoreMeter(cascadeDepth: cascadeDepth, steps: &steps)
        if board.activeSnoreCount >= DifficultyConfig.snoreLoseThreshold {
            steps.append(.avatarReaction(.cupcakeSnoreAlert))
            endRun(.snoreOverload, steps: &steps)
            return steps
        }

        if rescuedPuppyThisTurn {
            steps.append(.avatarReaction(.cupcakeCheerPuppy))
        } else if matchedBigMacThisTurn {
            steps.append(.avatarReaction(.cupcakeCheerBigMac))
        }
        if cascadeDepth >= 4 {
            steps.append(.avatarReaction(.teidoComboWakeUp(cascadeDepth: cascadeDepth)))
        }

        checkAndSpawnPuppy(maxCascadeDepth: cascadeDepth, intervalCrossed: puppyIntervalCrossed, steps: &steps)

        if board.activeSnoreCount >= 5 {
            steps.append(.avatarReaction(.cupcakeSnoreAlert))
        }
        if movesSinceLastSnore >= currentConfig.snoreSpawnCadence - 1 {
            steps.append(.avatarReaction(.teidoNoddingOff))
        }

        if MoveValidator.findAllValidMoves(in: board).isEmpty {
            if let rescuedSpawns = TileSpawner.silentDeadlockRescue(board: &board, recentSpawns: lastSpawns) {
                steps.append(.tilesSpawned(spawns: rescuedSpawns))
            } else {
                while stats.availableShuffles > 0 && MoveValidator.findAllValidMoves(in: board).isEmpty {
                    steps.append(contentsOf: triggerEmergencyShuffle())
                }
                if !isGameOver && MoveValidator.findAllValidMoves(in: board).isEmpty {
                    endRun(.noValidMoves, steps: &steps)
                }
            }
        }

        return steps
    }

    public mutating func triggerEmergencyShuffle() -> [BoardStep] {
        guard !isGameOver, stats.availableShuffles > 0 else { return [] }
        let moves = MoveValidator.shuffleBoard(&board)
        if moves.isEmpty && !MoveValidator.findAllValidMoves(in: board).isEmpty { return [] }
        stats.availableShuffles -= 1
        var steps: [BoardStep] = [.boardShuffled(moves: moves, usedEmergencyShuffle: true)]
        if moves.isEmpty && stats.availableShuffles == 0 { endRun(.noValidMoves, steps: &steps) }
        return steps
    }

    private mutating func endRun(_ reason: GameOverReason, steps: inout [BoardStep]) {
        isGameOver = true
        gameOverReason = reason
        steps.append(.gameOver(reason: reason))
    }

    // MARK: - Direct Special & Pad Thai Activations

    private mutating func resolveDirectSwapActivation(
        posA: GridPos,
        tileA: Tile?,
        posB: GridPos,
        tileB: Tile?,
        steps: inout [BoardStep],
        tilesCleared: inout Int,
        matchedBigMac: inout Bool
    ) -> Bool {
        guard let tA = tileA, let tB = tileB else { return false }
        var detonated: Set<GridPos> = []

        if tA.special.isSpecial && tB.special.isSpecial {
            detonated = [posA, posB]
            let (kind, affected) = computeSpecialComboArea(
                specA: tA.special,
                specB: tB.special,
                posA: posA,
                posB: posB,
                kindA: tA.kind.standardKind,
                kindB: tB.kind.standardKind
            )
            detonateBlast(
                positions: affected,
                activationKind: kind,
                origin: posB,
                cascadeDepth: 1,
                detonated: &detonated,
                steps: &steps,
                tilesCleared: &tilesCleared,
                matchedBigMac: &matchedBigMac
            )
            return true
        }

        if tA.special == .goldenSwirl || tB.special == .goldenSwirl {
            let swirlPos = tA.special == .goldenSwirl ? posA : posB
            detonated.insert(swirlPos)
            let otherTile = tA.special == .goldenSwirl ? tB : tA
            let targetKind = otherTile.kind.standardKind ?? board.mostCommonStandardKind()

            var affected = Set<GridPos>([posA, posB])
            for r in 0..<BoardState.rows {
                for c in 0..<BoardState.cols {
                    let p = GridPos(row: r, col: c)
                    if board[p]?.kind.standardKind == targetKind {
                        affected.insert(p)
                    }
                }
            }

            if otherTile.kind.isPadThai {
                affected.formUnion(padThaiCrossPositions(centeredAt: tA.kind.isPadThai ? posA : posB))
            }

            detonateBlast(
                positions: affected,
                activationKind: .goldenSwirl,
                origin: swirlPos,
                cascadeDepth: 1,
                bonusMultiplier: otherTile.kind.isPadThai ? 1.25 : 1,
                detonated: &detonated,
                steps: &steps,
                tilesCleared: &tilesCleared,
                matchedBigMac: &matchedBigMac
            )
            return true
        }

        if tA.kind.isPadThai || tB.kind.isPadThai {
            let padPos = tA.kind.isPadThai ? posA : posB
            let affected = padThaiCrossPositions(centeredAt: padPos)
            detonateBlast(
                positions: affected,
                activationKind: .padThaiCross,
                origin: padPos,
                cascadeDepth: 1,
                bonusMultiplier: 1.25,
                detonated: &detonated,
                steps: &steps,
                tilesCleared: &tilesCleared,
                matchedBigMac: &matchedBigMac
            )
            return true
        }

        return false
    }

    private func computeSpecialComboArea(
        specA: SpecialModifier,
        specB: SpecialModifier,
        posA: GridPos,
        posB: GridPos,
        kindA: StandardTileKind?,
        kindB: StandardTileKind?
    ) -> (SpecialActivationKind, Set<GridPos>) {
        var area = Set<GridPos>([posA, posB])
        let center = posB

        switch (specA, specB) {
        case (.goldenSwirl, .goldenSwirl):
            for r in 0..<BoardState.rows {
                for c in 0..<BoardState.cols {
                    area.insert(GridPos(row: r, col: c))
                }
            }
            return (.swirlPlusSwirl, area)

        case (.goldenSwirl, .korvRocket), (.korvRocket, .goldenSwirl):
            let targetKind = (specA == .goldenSwirl ? kindB : kindA) ?? board.mostCommonStandardKind()
            var toggle = true
            for r in 0..<BoardState.rows {
                for c in 0..<BoardState.cols {
                    let p = GridPos(row: r, col: c)
                    if board[p]?.kind.standardKind == targetKind {
                        if toggle {
                            for col in 0..<BoardState.cols { area.insert(GridPos(row: r, col: col)) }
                        } else {
                            for row in 0..<BoardState.rows { area.insert(GridPos(row: row, col: c)) }
                        }
                        toggle.toggle()
                    }
                }
            }
            return (.swirlPlusRocket, area)

        case (.goldenSwirl, .fiestaBomb), (.fiestaBomb, .goldenSwirl):
            let targetKind = (specA == .goldenSwirl ? kindB : kindA) ?? board.mostCommonStandardKind()
            for r in 0..<BoardState.rows {
                for c in 0..<BoardState.cols {
                    let p = GridPos(row: r, col: c)
                    if board[p]?.kind.standardKind == targetKind {
                        area.formUnion(squareArea(around: p, radius: 1))
                    }
                }
            }
            return (.swirlPlusBomb, area)

        case (.korvRocket, .fiestaBomb), (.fiestaBomb, .korvRocket):
            for dr in -1...1 {
                let rr = center.row + dr
                if rr >= 0 && rr < BoardState.rows {
                    for c in 0..<BoardState.cols { area.insert(GridPos(row: rr, col: c)) }
                }
            }
            for dc in -1...1 {
                let cc = center.col + dc
                if cc >= 0 && cc < BoardState.cols {
                    for r in 0..<BoardState.rows { area.insert(GridPos(row: r, col: cc)) }
                }
            }
            return (.rocketPlusBomb, area)

        case (.korvRocket, .korvRocket):
            for c in 0..<BoardState.cols { area.insert(GridPos(row: center.row, col: c)) }
            for r in 0..<BoardState.rows { area.insert(GridPos(row: r, col: center.col)) }
            return (.rocketPlusRocket, area)

        case (.fiestaBomb, .fiestaBomb):
            area.formUnion(squareArea(around: center, radius: 2))
            return (.bombPlusBomb, area)

        default:
            return (.fiestaBomb, area)
        }
    }

    // MARK: - Match Wave Resolution

    private mutating func resolveMatchWave(
        groups: [MatchGroup],
        cascadeDepth: Int,
        swipeAxis: SwipeAxis?,
        preferredSwapPositions: [GridPos],
        steps: inout [BoardStep],
        tilesCleared: inout Int,
        matchedBigMac: inout Bool,
        matchedCupcakes: inout Int
    ) {
        var allMatchedPositions = Set<GridPos>()
        var matchedKinds: [StandardTileKind] = []
        var createdSpecials: [(GridPos, StandardTileKind, SpecialModifier)] = []
        var cupcakePacifierOrigin: GridPos?

        for group in groups {
            allMatchedPositions.formUnion(group.positions)
            matchedKinds.append(group.kind)

            if group.kind == .bigMac {
                matchedBigMac = true
                stats.bigMacsMatched += group.positions.count
            }

            if group.kind == .cupcake {
                let previousCount = matchedCupcakes
                matchedCupcakes += group.positions.count
                if previousCount < 4 && matchedCupcakes >= 4 {
                    cupcakePacifierOrigin = group.intersection ?? group.positions.min()
                }
            }

            let special = group.earnedSpecial(swipeDirection: swipeAxis)
            if special != .none {
                let spawnPos = preferredSwapPositions.first(where: { group.positions.contains($0) })
                    ?? group.intersection
                    ?? group.positions.sorted()[group.positions.count / 2]
                createdSpecials.append((spawnPos, group.kind, special))
                if special == .fiestaBomb {
                    stats.fiestaBombsCreated += 1
                }
            }
        }

        var triggeredSpecialQueue: [(GridPos, SpecialModifier)] = []
        var triggeredPadThai: Set<GridPos> = []

        for pos in allMatchedPositions.sorted() {
            if let tile = board[pos], tile.special.isSpecial {
                triggeredSpecialQueue.append((pos, tile.special))
            }
            for neighbor in pos.orthogonalNeighbors(rows: BoardState.rows, cols: BoardState.cols) {
                if board[neighbor]?.kind.isPadThai == true {
                    triggeredPadThai.insert(neighbor)
                }
            }
        }

        let points = awardPoints(computeMatchPoints(groups: groups, tileCount: allMatchedPositions.count, cascadeDepth: cascadeDepth))

        for group in groups {
            damageAdjacentSnores(near: group.positions, steps: &steps)
        }

        let specialSpawnPositions = Set(createdSpecials.map(\.0))
        for pos in allMatchedPositions {
            board[pos] = nil
            if !specialSpawnPositions.contains(pos) { tilesCleared += 1 }
        }

        steps.append(.matchCleared(
            positions: allMatchedPositions.sorted(),
            cascadeDepth: cascadeDepth,
            pointsAwarded: points,
            matchedKinds: matchedKinds
        ))

        if let origin = cupcakePacifierOrigin, let oldestSnore = board.snorePositionsOldestFirst.first {
            board[oldestSnore]?.snore = nil
            stats.snoreBubblesPopped += 1
            let bonus = awardPoints(250 * currentConfig.baseScoreMultiplier)
            steps.append(.cupcakePacifierWave(from: origin, poppedSnoreAt: oldestSnore))
            steps.append(.snorePopped(at: oldestSnore, pointsAwarded: bonus))
        }

        var detonated = Set(triggeredSpecialQueue.map(\.0))
        for (pos, mod) in triggeredSpecialQueue {
            detonateSingleSpecial(
                at: pos,
                modifier: mod,
                cascadeDepth: cascadeDepth,
                detonated: &detonated,
                steps: &steps,
                tilesCleared: &tilesCleared,
                matchedBigMac: &matchedBigMac
            )
        }

        for padPos in triggeredPadThai.sorted() where board[padPos]?.kind.isPadThai == true {
            let cross = padThaiCrossPositions(centeredAt: padPos)
            detonateBlast(
                positions: cross,
                activationKind: .padThaiCross,
                origin: padPos,
                cascadeDepth: cascadeDepth,
                bonusMultiplier: 1.25,
                detonated: &detonated,
                steps: &steps,
                tilesCleared: &tilesCleared,
                matchedBigMac: &matchedBigMac
            )
        }

        for (pos, kind, modifier) in createdSpecials {
            let newTile = board.makeTile(kind: .standard(kind), special: modifier)
            board[pos] = newTile
            steps.append(.specialCreated(at: pos, tile: newTile))
        }
    }

    private mutating func detonateSingleSpecial(
        at origin: GridPos,
        modifier: SpecialModifier,
        cascadeDepth: Int,
        detonated: inout Set<GridPos>,
        steps: inout [BoardStep],
        tilesCleared: inout Int,
        matchedBigMac: inout Bool
    ) {
        var area = Set<GridPos>([origin])
        let activationKind: SpecialActivationKind

        switch modifier {
        case .korvRocket(.horizontal):
            activationKind = .korvRocketHorizontal
            for c in 0..<BoardState.cols { area.insert(GridPos(row: origin.row, col: c)) }
        case .korvRocket(.vertical):
            activationKind = .korvRocketVertical
            for r in 0..<BoardState.rows { area.insert(GridPos(row: r, col: origin.col)) }
        case .fiestaBomb:
            activationKind = .fiestaBomb
            area.formUnion(squareArea(around: origin, radius: 1))
        case .goldenSwirl:
            activationKind = .goldenSwirl
            let target = board.mostCommonStandardKind()
            for r in 0..<BoardState.rows {
                for c in 0..<BoardState.cols {
                    let p = GridPos(row: r, col: c)
                    if board[p]?.kind.standardKind == target {
                        area.insert(p)
                    }
                }
            }
        case .none:
            return
        }

        detonateBlast(
            positions: area,
            activationKind: activationKind,
            origin: origin,
            cascadeDepth: cascadeDepth,
            detonated: &detonated,
            steps: &steps,
            tilesCleared: &tilesCleared,
            matchedBigMac: &matchedBigMac
        )
    }

    private mutating func detonateBlast(
        positions: Set<GridPos>,
        activationKind: SpecialActivationKind,
        origin: GridPos,
        cascadeDepth: Int,
        bonusMultiplier: Double = 1,
        detonated: inout Set<GridPos>,
        steps: inout [BoardStep],
        tilesCleared: inout Int,
        matchedBigMac: inout Bool
    ) {
        var chained: [(GridPos, SpecialModifier)] = []
        for pos in positions.sorted() where !detonated.contains(pos) {
            if let tile = board[pos], tile.special.isSpecial, !tile.isLockedBySnore {
                detonated.insert(pos)
                chained.append((pos, tile.special))
            }
        }

        clearBlastArea(
            positions: positions, activationKind: activationKind, origin: origin,
            cascadeDepth: cascadeDepth, bonusMultiplier: bonusMultiplier, steps: &steps,
            tilesCleared: &tilesCleared, matchedBigMac: &matchedBigMac
        )

        for (nextPos, nextMod) in chained {
            detonateSingleSpecial(
                at: nextPos,
                modifier: nextMod,
                cascadeDepth: cascadeDepth,
                detonated: &detonated,
                steps: &steps,
                tilesCleared: &tilesCleared,
                matchedBigMac: &matchedBigMac
            )
        }
    }

    private mutating func clearBlastArea(
        positions: Set<GridPos>,
        activationKind: SpecialActivationKind,
        origin: GridPos,
        cascadeDepth: Int,
        bonusMultiplier: Double = 1.0,
        steps: inout [BoardStep],
        tilesCleared: inout Int,
        matchedBigMac: inout Bool
    ) {
        var clearedPositions: [GridPos] = []
        for pos in positions.sorted() {
            guard let tile = board[pos] else { continue }
            if tile.kind.isPuppy { continue }

            if tile.isLockedBySnore {
                damageSnore(at: pos, steps: &steps)
                continue
            }

            if tile.kind.standardKind == .bigMac {
                matchedBigMac = true
                stats.bigMacsMatched += 1
            }

            board[pos] = nil
            tilesCleared += 1
            clearedPositions.append(pos)
        }

        let basePoints = Double(clearedPositions.count * 85) * currentConfig.baseScoreMultiplier * Double(max(1, cascadeDepth)) * bonusMultiplier
        let points = awardPoints(basePoints)

        steps.append(.specialTriggered(
            kind: activationKind,
            origin: origin,
            affectedPositions: clearedPositions,
            pointsAwarded: points
        ))
    }

    // MARK: - Gravity & Refill

    @discardableResult
    private mutating func applyGravityAndRefill(cascadeDepth: Int, steps: inout [BoardStep]) -> [TileSpawn] {
        var moves: [TileMove] = []

        for c in 0..<BoardState.cols {
            var writeRow = BoardState.rows - 1
            for r in stride(from: BoardState.rows - 1, through: 0, by: -1) {
                if let tile = board[r, c] {
                    if writeRow != r {
                        board[writeRow, c] = tile
                        board[r, c] = nil
                        moves.append(TileMove(tileId: tile.id, from: GridPos(row: r, col: c), to: GridPos(row: writeRow, col: c)))
                    }
                    writeRow -= 1
                }
            }
        }

        if !moves.isEmpty {
            steps.append(.gravityApplied(moves: moves))
        }

        let spawns = TileSpawner.refillEmptySlots(
            board: &board,
            tier: stats.tier,
            cascadeDepth: cascadeDepth,
            surge: currentConfig.surge
        )
        if !spawns.isEmpty {
            steps.append(.tilesSpawned(spawns: spawns))
        }
        return spawns
    }

    // MARK: - Puppies

    @discardableResult
    private mutating func checkAndRescuePuppies(
        steps: inout [BoardStep],
        rescuedFlag: inout Bool,
        tilesCleared: inout Int
    ) -> Bool {
        var rescuedAny = false
        let bottomRow = BoardState.rows - 1

        for c in 0..<BoardState.cols {
            let pos = GridPos(row: bottomRow, col: c)
            guard board[pos]?.kind.isPuppy == true else { continue }

            rescuedAny = true
            rescuedFlag = true
            board[pos] = nil
            stats.puppiesRescued += 1

            let blastRadius = currentConfig.puppyBlastRadius
            let blastArea = squareArea(around: pos, radius: blastRadius)
            var clearedBlast: [GridPos] = [pos]

            for bp in blastArea.sorted() where bp != pos {
                guard let tile = board[bp], !tile.kind.isPuppy else { continue }
                if tile.isLockedBySnore {
                    board[bp]?.snore = nil
                    stats.snoreBubblesPopped += 1
                    steps.append(.snorePopped(at: bp, pointsAwarded: awardPoints(200)))
                }
                board[bp] = nil
                tilesCleared += 1
                clearedBlast.append(bp)
            }

            let reward = awardPoints(1_500 * currentConfig.baseScoreMultiplier)
            steps.append(.puppyRescued(at: pos, blastPositions: clearedBlast, pointsAwarded: reward))
        }

        return rescuedAny
    }

    private mutating func checkAndSpawnPuppy(maxCascadeDepth: Int, intervalCrossed: Bool, steps: inout [BoardStep]) {
        let cfg = currentConfig
        guard board.activePuppyCount < cfg.maxSimultaneousPuppies else { return }

        let scoreTriggered = reachedPuppyScoreThreshold
        guard intervalCrossed || scoreTriggered || maxCascadeDepth >= 4 else { return }

        var candidates: [GridPos] = []
        for c in 0..<BoardState.cols {
            let pos = GridPos(row: 0, col: c)
            if let tile = board[pos], !tile.kind.isPuppy, !tile.isLockedBySnore, !tile.special.isSpecial {
                candidates.append(pos)
            }
        }
        guard !candidates.isEmpty else { return }
        if scoreTriggered {
            let interval = cfg.basePuppyPointInterval
            let gap = interval - ((stats.score - nextPuppyScoreThreshold) % interval)
            setPuppyThreshold(gap: gap)
        }

        let spawnPos = candidates[board.rng.nextInt(upperBound: candidates.count)]
        let puppyTile = board.makeTile(kind: .puppy)
        board[spawnPos] = puppyTile
        steps.append(.puppySpawned(at: spawnPos, tile: puppyTile))
    }

    // MARK: - Snore Hazard

    private mutating func damageAdjacentSnores(near matchedPositions: Set<GridPos>, steps: inout [BoardStep]) {
        var adjacentSnores = Set<GridPos>()
        for pos in matchedPositions {
            for neighbor in pos.orthogonalNeighbors(rows: BoardState.rows, cols: BoardState.cols) {
                if board[neighbor]?.isLockedBySnore == true {
                    adjacentSnores.insert(neighbor)
                }
            }
        }

        for pos in adjacentSnores.sorted() {
            damageSnore(at: pos, steps: &steps)
        }
    }

    private mutating func damageSnore(at pos: GridPos, steps: inout [BoardStep]) {
        guard var snore = board[pos]?.snore else { return }
        snore.hitsRemaining -= 1
        if snore.hitsRemaining <= 0 {
            board[pos]?.snore = nil
            stats.snoreBubblesPopped += 1
            let bonus = awardPoints(200 * currentConfig.baseScoreMultiplier)
            steps.append(.snorePopped(at: pos, pointsAwarded: bonus))
        } else {
            board[pos]?.snore = snore
            steps.append(.snoreDamaged(at: pos, remainingHits: snore.hitsRemaining))
        }
    }

    private mutating func updateDriftingSnores(steps: inout [BoardStep]) {
        for r in 0..<BoardState.rows {
            for c in 0..<BoardState.cols {
                let pos = GridPos(row: r, col: c)
                guard var snore = board[pos]?.snore, snore.isDrifting else { continue }

                snore.turnsSinceDrift += 1
                if snore.turnsSinceDrift >= 3 {
                    snore.turnsSinceDrift = 0
                    let target = GridPos(row: r - 1, col: c)
                    if r > 0,
                       let above = board[target],
                       !above.isLockedBySnore,
                       above.kind.standardKind != nil, above.special == .none {
                        board[pos]?.snore = nil
                        board[target]?.snore = snore
                        steps.append(.snoreDrifted(from: pos, to: target))
                    } else {
                        board[pos]?.snore = snore
                    }
                } else {
                    board[pos]?.snore = snore
                }
            }
        }
    }

    private mutating func advanceSnoreMeter(cascadeDepth: Int, steps: inout [BoardStep]) {
        guard cascadeDepth <= 1 else { return }
        movesSinceLastSnore += 1

        let cfg = currentConfig
        if movesSinceLastSnore >= cfg.snoreSpawnCadence {
            movesSinceLastSnore = 0
            spawnSnoreBubble(config: cfg, steps: &steps)
        }
    }

    private mutating func spawnSnoreBubble(config: DifficultyConfig, steps: inout [BoardStep]) {
        var candidates: [GridPos] = []
        for r in 0..<BoardState.rows {
            for c in 0..<BoardState.cols {
                let pos = GridPos(row: r, col: c)
                if let tile = board[pos],
                   !tile.isLockedBySnore,
                   tile.special == .none,
                   tile.kind.standardKind != nil {
                    candidates.append(pos)
                }
            }
        }
        guard !candidates.isEmpty else { return }

        let target = candidates[board.rng.nextInt(upperBound: candidates.count)]
        let isDouble = config.allowsDoubleZzz && board.rng.nextDouble() < 0.35
        let isDrifting = config.allowsDriftingSnore && board.rng.nextDouble() < 0.30
        let bubble = board.makeSnoreBubble(hits: isDouble ? 2 : 1, isDrifting: isDrifting)
        board[target]?.snore = bubble
        steps.append(.snoreSpawned(at: target, bubble: bubble))
    }

    // MARK: - Teido Surge Achievement & Tier Progression

    private mutating func spawnTeidoAchievementRocket(steps: inout [BoardStep]) {
        var candidates: [GridPos] = []
        for r in 0..<BoardState.rows {
            for c in 0..<BoardState.cols {
                let pos = GridPos(row: r, col: c)
                if let tile = board[pos], !tile.isLockedBySnore, tile.special == .none, tile.kind.standardKind != nil {
                    candidates.append(pos)
                }
            }
        }
        guard !candidates.isEmpty else { return }

        let target = candidates[board.rng.nextInt(upperBound: candidates.count)]
        let kind = board[target]?.kind.standardKind ?? .biltemaCombo
        let orientation: RocketOrientation = board.rng.nextInt(upperBound: 2) == 0 ? .horizontal : .vertical
        let rocketTile = board.makeTile(kind: .standard(kind), special: .korvRocket(orientation))
        board[target] = rocketTile
        steps.append(.teidoComboAchievement(rocketSpawnedAt: target, tile: rocketTile))
        steps.append(.avatarReaction(.teidoAchievementUnlocked))
    }

    private mutating func advanceTierProgress(tilesCleared: Int, steps: inout [BoardStep]) {
        var remaining = tilesCleared
        while remaining >= currentConfig.tierTileTarget - stats.tierProgress && stats.tier < Int.max {
            let completedTier = stats.tier
            remaining -= currentConfig.tierTileTarget - stats.tierProgress
            stats.tierProgress = 0
            stats.tier += 1

            let newConfig = currentConfig
            if newConfig.surge == .teido {
                stats.teidoSurgesTriggered += 1
            }

            let snorePositions = board.snorePositionsOldestFirst
            for pos in snorePositions {
                board[pos]?.snore = nil
                stats.snoreBubblesPopped += 1
            }
            let bonus = awardPoints(Double(snorePositions.count) * 300 * newConfig.baseScoreMultiplier)
            setPuppyThreshold(gap: newConfig.basePuppyPointInterval)

            var earnedShuffle = false
            if completedTier % 3 == 0 && stats.availableShuffles < DifficultyConfig.maxEmergencyShuffles {
                stats.availableShuffles += 1
                earnedShuffle = true
            }

            let banner = DifficultyConfig.tierUpBanner(forTier: stats.tier)
            steps.append(.tierUp(
                newTier: stats.tier,
                surge: newConfig.surge,
                bannerText: banner,
                poppedSnores: snorePositions,
                bonusPoints: bonus,
                earnedShuffle: earnedShuffle
            ))
        }
        stats.tierProgress += min(remaining, Int.max - stats.tierProgress)
    }

    // MARK: - Scoring & Geometry Helpers

    private func computeMatchPoints(groups: [MatchGroup], tileCount: Int, cascadeDepth: Int) -> Double {
        let cfg = currentConfig
        var total: Double = 0
        for group in groups {
            let cupcakeBonus = cfg.surge == .cupcake && (group.kind == .bigMac || group.kind == .cupcake)
            let padThaiBonus = group.positions.contains { pos in
                pos.orthogonalNeighbors(rows: BoardState.rows, cols: BoardState.cols).contains {
                    board[$0]?.kind.isPadThai == true
                }
            }
            total += Double(group.positions.count * 60) * (cupcakeBonus || padThaiBonus ? 1.25 : 1)
        }
        if tileCount >= 4 {
            total *= 1.0 + Double(tileCount - 3) * 0.20
        }
        let cascadeMult = 1.0 + Double(max(0, cascadeDepth - 1)) * 0.5
        return total * cfg.baseScoreMultiplier * cascadeMult
    }

    private mutating func awardPoints(_ amount: Double) -> Int {
        let budget = Int.max - stats.score
        let rounded = amount.rounded()
        let awarded = rounded < Double(budget) ? Int(rounded) : budget
        stats.score += awarded
        return awarded
    }

    private var reachedPuppyScoreThreshold: Bool {
        nextPuppyScoreThreshold < Int.max && stats.score >= nextPuppyScoreThreshold
    }

    private mutating func setPuppyThreshold(gap: Int) {
        nextPuppyScoreThreshold = stats.score + min(gap, Int.max - stats.score)
    }

    private func padThaiCrossPositions(centeredAt center: GridPos) -> Set<GridPos> {
        var result = Set<GridPos>([center])
        for n in center.orthogonalNeighbors(rows: BoardState.rows, cols: BoardState.cols) {
            result.insert(n)
        }
        return result
    }

    private func squareArea(around center: GridPos, radius: Int) -> Set<GridPos> {
        var result = Set<GridPos>()
        for dr in -radius...radius {
            for dc in -radius...radius {
                let p = GridPos(row: center.row + dr, col: center.col + dc)
                if board.isValid(p) {
                    result.insert(p)
                }
            }
        }
        return result
    }
}
