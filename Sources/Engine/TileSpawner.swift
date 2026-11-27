/// Tier-scaled dynamic spawn weighting profile ("The Craving Director").
public struct SpawnDifficultyProfile: Sendable, Equatable {
    public let tier: Int
    public let matchAssistBonus: Int
    public let clumpAffinity: Int
    public let cupcakeMercyThreshold: Int  // Snore count needed to boost Cupcake spawns
    public let maxAutoCascadeDepth: Int    // Caps runaway auto-cascades at 6

    public init(
        tier: Int,
        matchAssistBonus: Int,
        clumpAffinity: Int,
        cupcakeMercyThreshold: Int,
        maxAutoCascadeDepth: Int
    ) {
        self.tier = tier
        self.matchAssistBonus = matchAssistBonus
        self.clumpAffinity = clumpAffinity
        self.cupcakeMercyThreshold = cupcakeMercyThreshold
        self.maxAutoCascadeDepth = maxAutoCascadeDepth
    }

    public static func forTier(_ tier: Int) -> SpawnDifficultyProfile {
        let clamped = min(max(tier, 1), 15)
        return SpawnDifficultyProfile(
            tier: tier,
            matchAssistBonus: max(-20, 50 - (clamped * 5)),
            clumpAffinity: max(-25, 20 - (clamped * 3)),
            cupcakeMercyThreshold: tier <= 3 ? 3 : 5,
            maxAutoCascadeDepth: 6
        )
    }
}

/// Constraint-aware weighted board generator and refill director.
public enum TileSpawner {
    private static let baseWeight: Int = 100

    public static func populateInitialBoard(board: inout BoardState, tier: Int = 1) {
        let allKinds = StandardTileKind.allCases

        for r in 0..<BoardState.rows {
            for c in 0..<BoardState.cols {
                var excluded = Set<StandardTileKind>()
                if c >= 2,
                   let k1 = board[r, c - 1]?.kind.standardKind,
                   let k2 = board[r, c - 2]?.kind.standardKind,
                   k1 == k2 {
                    excluded.insert(k1)
                }
                if r >= 2,
                   let k1 = board[r - 1, c]?.kind.standardKind,
                   let k2 = board[r - 2, c]?.kind.standardKind,
                   k1 == k2 {
                    excluded.insert(k1)
                }

                let candidates = allKinds.filter { !excluded.contains($0) }
                let chosen = candidates[board.rng.nextInt(upperBound: candidates.count)]
                board[r, c] = board.makeTile(kind: .standard(chosen))
            }
        }

        ensureMinimumOpeningMoves(board: &board, minMoves: 3)
    }

    public static func refillEmptySlots(
        board: inout BoardState,
        tier: Int,
        cascadeDepth: Int,
        surge: CravingSurge,
        targetBias: (kind: StandardTileKind, extraWeight: Int)? = nil
    ) -> [TileSpawn] {
        let profile = SpawnDifficultyProfile.forTier(tier)
        let antiMatchMode = cascadeDepth >= profile.maxAutoCascadeDepth
        let activeSnores = board.activeSnoreCount
        var spawns: [TileSpawn] = []

        let existingPadThaiCount = countPadThai(in: board)
        var spawnedPadThaiThisRefill = 0

        for c in 0..<BoardState.cols {
            var emptyRows: [Int] = []
            for r in stride(from: BoardState.rows - 1, through: 0, by: -1) {
                if board[r, c] == nil {
                    emptyRows.append(r)
                }
            }
            guard !emptyRows.isEmpty else { continue }

            for (idx, r) in emptyRows.enumerated() {
                let pos = GridPos(row: r, col: c)
                let spawnOffset = emptyRows.count - idx

                if surge == .teido &&
                   (existingPadThaiCount + spawnedPadThaiThisRefill) < 2 &&
                   board.rng.nextDouble() < 0.06 {
                    let tile = board.makeTile(kind: .padThai)
                    board[pos] = tile
                    spawns.append(TileSpawn(tile: tile, at: pos, spawnRowOffset: spawnOffset))
                    spawnedPadThaiThisRefill += 1
                    continue
                }

                let chosenKind = pickWeightedStandardKind(
                    for: pos,
                    in: &board,
                    profile: profile,
                    activeSnoreCount: activeSnores,
                    antiMatchMode: antiMatchMode,
                    targetBias: targetBias
                )
                let tile = board.makeTile(kind: .standard(chosenKind))
                board[pos] = tile
                spawns.append(TileSpawn(tile: tile, at: pos, spawnRowOffset: spawnOffset))
            }
        }

        return spawns
    }

    public static func silentDeadlockRescue(
        board: inout BoardState,
        recentSpawns: [TileSpawn]
    ) -> [TileSpawn]? {
        let recentTiles = Set(recentSpawns.map(\.tile.id))
        guard !recentTiles.isEmpty else { return nil }
        let editable = Set(board.grid.enumerated().flatMap { row, tiles in
            tiles.enumerated().compactMap { col, entry -> GridPos? in
                guard let tile = entry, recentTiles.contains(tile.id), !tile.isLockedBySnore,
                      tile.special == .none, tile.kind.standardKind != nil else { return nil }
                return GridPos(row: row, col: col)
            }
        })
        guard !editable.isEmpty else { return nil }

        // Search possible three-in-a-line swaps. A candidate must use the existing tiles
        // wherever a cell was not part of the refill.
        for row in 0..<BoardState.rows {
            for col in 0..<BoardState.cols {
                let destination = GridPos(row: row, col: col)
                guard let destinationKind = board.matchableStandardKind(at: destination) else { continue }
                let neighbors = destination.orthogonalNeighbors(rows: BoardState.rows, cols: BoardState.cols)
                for (dr, dc) in [(0, 1), (1, 0)] {
                    for offset in 0..<3 {
                        let anchors = (0..<3).filter { $0 != offset }.map {
                            GridPos(row: row + ($0 - offset) * dr, col: col + ($0 - offset) * dc)
                        }
                        guard anchors.allSatisfy({ board.matchableStandardKind(at: $0) != nil }) else { continue }
                        for source in neighbors where !anchors.contains(source) {
                            guard board.matchableStandardKind(at: source) != nil else { continue }
                            let needed = anchors + [source]
                            guard needed.contains(where: editable.contains) else { continue }
                            for kind in StandardTileKind.allCases {
                                let changes = needed.filter { board.matchableStandardKind(at: $0) != kind }
                                guard changes.allSatisfy(editable.contains),
                                      kind != destinationKind || editable.contains(destination) else { continue }
                                let alternatives = kind == destinationKind ? StandardTileKind.allCases.filter { $0 != kind } : [destinationKind]
                                for replacement in alternatives {
                                    var candidate = board
                                    var spawns: [TileSpawn] = []
                                    for pos in changes + (kind == destinationKind ? [destination] : []) {
                                        let tile = candidate.makeTile(kind: .standard(pos == destination ? replacement : kind))
                                        candidate[pos] = tile
                                        spawns.append(TileSpawn(tile: tile, at: pos, spawnRowOffset: 1))
                                    }
                                    if !spawns.isEmpty && candidate.findMatches().isEmpty {
                                        board = candidate
                                        return spawns
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return nil
    }

    static func settleMatchesAtCascadeLimit(board: inout BoardState, groups: [MatchGroup]) -> [TileSpawn] {
        var changes: [TileSpawn] = []
        for group in groups {
            for pos in group.positions.sorted() {
                guard var tile = board[pos], let oldKind = board.matchableStandardKind(at: pos),
                      board.wouldCreateImmediateMatch(kind: oldKind, at: pos) else { continue }
                let kind = pickWeightedStandardKind(
                    for: pos, in: &board, profile: .forTier(1), activeSnoreCount: 0, antiMatchMode: true
                )
                tile.kind = .standard(kind)
                board[pos] = tile
                changes.append(TileSpawn(tile: tile, at: pos, spawnRowOffset: 0))
            }
        }
        return changes
    }

    private static func pickWeightedStandardKind(
        for pos: GridPos,
        in board: inout BoardState,
        profile: SpawnDifficultyProfile,
        activeSnoreCount: Int,
        antiMatchMode: Bool,
        targetBias: (kind: StandardTileKind, extraWeight: Int)? = nil
    ) -> StandardTileKind {
        let allKinds = StandardTileKind.allCases
        var candidates: [(StandardTileKind, Int)] = []

        for kind in allKinds {
            if antiMatchMode && board.wouldCreateImmediateMatch(kind: kind, at: pos) {
                continue
            }

            var weight = baseWeight

            if kind == .cupcake && activeSnoreCount >= profile.cupcakeMercyThreshold {
                weight = profile.tier <= 3 ? 125 : 105
            }
            if let targetBias, kind == targetBias.kind {
                weight += targetBias.extraWeight
            }

            if createsTwoInARowSetup(kind: kind, at: pos, in: board) {
                weight += profile.matchAssistBonus
            }

            let adjacentSame = countAdjacentSame(kind: kind, at: pos, in: board)
            if adjacentSame > 0 {
                weight += profile.clumpAffinity * adjacentSame
            }

            candidates.append((kind, max(5, weight)))
        }

        if candidates.isEmpty {
            return allKinds[board.rng.nextInt(upperBound: allKinds.count)]
        }

        let totalWeight = candidates.reduce(0) { $0 + $1.1 }
        var roll = board.rng.nextInt(upperBound: totalWeight)
        for (kind, w) in candidates {
            if roll < w { return kind }
            roll -= w
        }
        return candidates[candidates.count - 1].0
    }

    private static func createsTwoInARowSetup(kind: StandardTileKind, at pos: GridPos, in board: BoardState) -> Bool {
        let r = pos.row
        let c = pos.col
        let checks: [(GridPos, GridPos)] = [
            (GridPos(row: r, col: c - 1), GridPos(row: r, col: c + 1)),
            (GridPos(row: r + 1, col: c), GridPos(row: r - 1, col: c)),
            (GridPos(row: r + 1, col: c), GridPos(row: r + 2, col: c)),
            (GridPos(row: r, col: c - 1), GridPos(row: r, col: c - 2)),
            (GridPos(row: r, col: c + 1), GridPos(row: r, col: c + 2))
        ]
        for (a, b) in checks {
            let matchA = board.matchableStandardKind(at: a) == kind
            let matchB = board.matchableStandardKind(at: b) == kind
            if (matchA && !matchB && pos.isAdjacent(to: a)) || (matchB && !matchA && pos.isAdjacent(to: b)) {
                return true
            }
        }
        return false
    }

    private static func countAdjacentSame(kind: StandardTileKind, at pos: GridPos, in board: BoardState) -> Int {
        pos.orthogonalNeighbors(rows: BoardState.rows, cols: BoardState.cols)
            .filter { board.matchableStandardKind(at: $0) == kind }
            .count
    }

    private static func countPadThai(in board: BoardState) -> Int {
        var count = 0
        for r in 0..<BoardState.rows {
            for c in 0..<BoardState.cols where board[r, c]?.kind.isPadThai == true {
                count += 1
            }
        }
        return count
    }

    private static func ensureMinimumOpeningMoves(board: inout BoardState, minMoves: Int) {
        var attempts = 0
        while MoveValidator.findAllValidMoves(in: board).count < minMoves && attempts < 20 {
            attempts += 1
            let r = board.rng.nextInt(upperBound: BoardState.rows - 1)
            let c = board.rng.nextInt(upperBound: BoardState.cols - 2)
            let allKinds = StandardTileKind.allCases
            let kindA = allKinds[board.rng.nextInt(upperBound: allKinds.count)]

            let targets = [
                GridPos(row: r, col: c),
                GridPos(row: r, col: c + 1),
                GridPos(row: r + 1, col: c + 2)
            ]

            let backup = targets.map { ($0, board[$0]) }
            for pos in targets {
                board[pos] = board.makeTile(kind: .standard(kindA))
            }
            if !board.findMatches().isEmpty {
                for (pos, oldTile) in backup {
                    board[pos] = oldTile
                }
            }
        }
        guard MoveValidator.findAllValidMoves(in: board).count < minMoves else { return }

        // A match-free baseline with three independent, spaced-out swap patterns.
        let background: [StandardTileKind] = [.teido, .hermanosTaco, .partillePoke, .biltemaCombo]
        for row in 0..<BoardState.rows {
            for col in 0..<BoardState.cols {
                let kind = background[(row * 2 + col) % background.count]
                board[row, col] = board.makeTile(kind: .standard(kind))
            }
        }
        for row in [0, 3, 6] {
            for pos in [GridPos(row: row, col: 0), GridPos(row: row, col: 1), GridPos(row: row + 1, col: 2)] {
                board[pos] = board.makeTile(kind: .standard(.cupcake))
            }
        }
    }
}
