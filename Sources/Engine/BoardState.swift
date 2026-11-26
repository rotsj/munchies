/// A detected match group of 3 or more identical standard tiles.
public struct MatchGroup: Hashable, Sendable {
    public let kind: StandardTileKind
    public let positions: Set<GridPos>
    public let maxHorizontalRun: Int
    public let maxVerticalRun: Int
    public let intersection: GridPos?

    public init(
        kind: StandardTileKind,
        positions: Set<GridPos>,
        maxHorizontalRun: Int,
        maxVerticalRun: Int,
        intersection: GridPos?
    ) {
        self.kind = kind
        self.positions = positions
        self.maxHorizontalRun = maxHorizontalRun
        self.maxVerticalRun = maxVerticalRun
        self.intersection = intersection
    }

    /// Determines the special modifier earned by this match group.
    public func earnedSpecial(swipeDirection: SwipeAxis?) -> SpecialModifier {
        if maxHorizontalRun >= 5 || maxVerticalRun >= 5 {
            return .goldenSwirl
        }
        if maxHorizontalRun >= 3 && maxVerticalRun >= 3 {
            return .fiestaBomb
        }
        if maxHorizontalRun == 4 || maxVerticalRun == 4 {
            if let axis = swipeDirection {
                return .korvRocket(axis == .horizontal ? .vertical : .horizontal)
            }
            return .korvRocket(maxHorizontalRun == 4 ? .vertical : .horizontal)
        }
        return .none
    }
}

public enum SwipeAxis: Sendable {
    case horizontal
    case vertical
}

/// Pure-Swift representation of the 8x9 Munchies game board and its deterministic RNG.
public struct BoardState: Sendable {
    public static let rows: Int = 9
    public static let cols: Int = 8

    public var grid: [[Tile?]]
    public var rng: SeededRNG
    public var nextTileId: Int
    public var nextSnoreOrder: Int

    public init(seed: UInt64 = 42) {
        self.grid = Array(repeating: Array(repeating: nil, count: Self.cols), count: Self.rows)
        self.rng = SeededRNG(seed: seed)
        self.nextTileId = 1
        self.nextSnoreOrder = 1
    }

    public func isValid(_ pos: GridPos) -> Bool {
        pos.row >= 0 && pos.row < Self.rows && pos.col >= 0 && pos.col < Self.cols
    }

    public subscript(_ pos: GridPos) -> Tile? {
        get {
            guard isValid(pos) else { return nil }
            return grid[pos.row][pos.col]
        }
        set {
            guard isValid(pos) else { return }
            grid[pos.row][pos.col] = newValue
        }
    }

    public subscript(row: Int, col: Int) -> Tile? {
        get { self[GridPos(row: row, col: col)] }
        set { self[GridPos(row: row, col: col)] = newValue }
    }

    public mutating func makeTile(
        kind: TileKind,
        special: SpecialModifier = .none,
        snore: SnoreBubble? = nil
    ) -> Tile {
        let tile = Tile(id: nextTileId, kind: kind, special: special, snore: snore)
        nextTileId += 1
        return tile
    }

    public mutating func makeSnoreBubble(hits: Int = 1, isDrifting: Bool = false) -> SnoreBubble {
        let bubble = SnoreBubble(
            hitsRemaining: hits,
            isDrifting: isDrifting,
            turnsSinceDrift: 0,
            spawnedOrder: nextSnoreOrder
        )
        nextSnoreOrder += 1
        return bubble
    }

    public mutating func swapTiles(at a: GridPos, and b: GridPos) {
        guard isValid(a), isValid(b) else { return }
        let temp = grid[a.row][a.col]
        grid[a.row][a.col] = grid[b.row][b.col]
        grid[b.row][b.col] = temp
    }

    public var activeSnoreCount: Int {
        var count = 0
        for r in 0..<Self.rows {
            for c in 0..<Self.cols where grid[r][c]?.isLockedBySnore == true {
                count += 1
            }
        }
        return count
    }

    public var snorePositionsOldestFirst: [GridPos] {
        var list: [(GridPos, Int)] = []
        for r in 0..<Self.rows {
            for c in 0..<Self.cols {
                if let snore = grid[r][c]?.snore {
                    list.append((GridPos(row: r, col: c), snore.spawnedOrder))
                }
            }
        }
        return list.sorted { $0.1 < $1.1 }.map(\.0)
    }

    public var activePuppyCount: Int {
        var count = 0
        for r in 0..<Self.rows {
            for c in 0..<Self.cols where grid[r][c]?.kind.isPuppy == true {
                count += 1
            }
        }
        return count
    }

    public func mostCommonStandardKind() -> StandardTileKind {
        var counts: [StandardTileKind: Int] = [:]
        for r in 0..<Self.rows {
            for c in 0..<Self.cols {
                if let tile = grid[r][c], !tile.isLockedBySnore, let std = tile.kind.standardKind {
                    counts[std, default: 0] += 1
                }
            }
        }
        return StandardTileKind.allCases.max(by: { counts[$0, default: 0] < counts[$1, default: 0] }) ?? .cupcake
    }

    public func matchableStandardKind(at pos: GridPos) -> StandardTileKind? {
        guard let tile = self[pos], !tile.isLockedBySnore else { return nil }
        if tile.special == .goldenSwirl { return nil }
        return tile.kind.standardKind
    }

    public func findMatches() -> [MatchGroup] {
        struct Run {
            let kind: StandardTileKind
            let positions: [GridPos]
            let isHorizontal: Bool
        }

        var runs: [Run] = []

        for r in 0..<Self.rows {
            var c = 0
            while c < Self.cols {
                guard let kind = matchableStandardKind(at: GridPos(row: r, col: c)) else {
                    c += 1
                    continue
                }
                var end = c + 1
                while end < Self.cols, matchableStandardKind(at: GridPos(row: r, col: end)) == kind {
                    end += 1
                }
                if end - c >= 3 {
                    runs.append(Run(kind: kind, positions: (c..<end).map { GridPos(row: r, col: $0) }, isHorizontal: true))
                }
                c = end
            }
        }

        for c in 0..<Self.cols {
            var r = 0
            while r < Self.rows {
                guard let kind = matchableStandardKind(at: GridPos(row: r, col: c)) else {
                    r += 1
                    continue
                }
                var end = r + 1
                while end < Self.rows, matchableStandardKind(at: GridPos(row: end, col: c)) == kind {
                    end += 1
                }
                if end - r >= 3 {
                    runs.append(Run(kind: kind, positions: (r..<end).map { GridPos(row: $0, col: c) }, isHorizontal: false))
                }
                r = end
            }
        }

        guard !runs.isEmpty else { return [] }

        var visited = Array(repeating: false, count: runs.count)
        var groups: [MatchGroup] = []

        for i in 0..<runs.count where !visited[i] {
            var queue = [i]
            visited[i] = true
            var clusterIndices: [Int] = []

            while let idx = queue.first {
                queue.removeFirst()
                clusterIndices.append(idx)
                let setA = Set(runs[idx].positions)
                for j in 0..<runs.count where !visited[j] && runs[j].kind == runs[idx].kind {
                    if !setA.isDisjoint(with: runs[j].positions) {
                        visited[j] = true
                        queue.append(j)
                    }
                }
            }

            let kind = runs[i].kind
            var allPositions = Set<GridPos>()
            var hPositions = Set<GridPos>()
            var vPositions = Set<GridPos>()
            var maxH = 0
            var maxV = 0

            for idx in clusterIndices {
                let run = runs[idx]
                allPositions.formUnion(run.positions)
                if run.isHorizontal {
                    hPositions.formUnion(run.positions)
                    maxH = max(maxH, run.positions.count)
                } else {
                    vPositions.formUnion(run.positions)
                    maxV = max(maxV, run.positions.count)
                }
            }

            let intersection = hPositions.intersection(vPositions).sorted().first
            groups.append(
                MatchGroup(
                    kind: kind,
                    positions: allPositions,
                    maxHorizontalRun: maxH,
                    maxVerticalRun: maxV,
                    intersection: intersection
                )
            )
        }

        return groups.sorted { lhs, rhs in
            let lMin = lhs.positions.min() ?? GridPos(row: 0, col: 0)
            let rMin = rhs.positions.min() ?? GridPos(row: 0, col: 0)
            return lMin < rMin
        }
    }

    public func wouldCreateImmediateMatch(kind: StandardTileKind, at pos: GridPos) -> Bool {
        let r = pos.row
        let c = pos.col

        func isKind(_ row: Int, _ col: Int) -> Bool {
            matchableStandardKind(at: GridPos(row: row, col: col)) == kind
        }

        if (isKind(r, c - 2) && isKind(r, c - 1)) ||
           (isKind(r, c - 1) && isKind(r, c + 1)) ||
           (isKind(r, c + 1) && isKind(r, c + 2)) {
            return true
        }
        if (isKind(r - 2, c) && isKind(r - 1, c)) ||
           (isKind(r - 1, c) && isKind(r + 1, c)) ||
           (isKind(r + 1, c) && isKind(r + 2, c)) {
            return true
        }
        return false
    }
}
