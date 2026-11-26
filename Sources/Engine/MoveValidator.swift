/// Represents a legal swap between two orthogonally adjacent positions.
public struct ValidMove: Hashable, Sendable {
    public let from: GridPos
    public let to: GridPos

    public init(from: GridPos, to: GridPos) {
        self.from = from
        self.to = to
    }
}

/// Validates player swaps, finds hints, and performs fair deadlock shuffles.
public enum MoveValidator {
    public static func isValidSwap(from a: GridPos, to b: GridPos, in board: BoardState) -> Bool {
        guard let tileA = board[a],
              let tileB = board[b],
              a.isAdjacent(to: b),
              tileA.isSwappable,
              tileB.isSwappable else {
            return false
        }

        if tileA.special.isSpecial && tileB.special.isSpecial {
            return true
        }

        if (tileA.special == .goldenSwirl && !tileB.kind.isPuppy) ||
           (tileB.special == .goldenSwirl && !tileA.kind.isPuppy) {
            return true
        }

        if (tileA.kind.isPadThai && !tileB.kind.isPuppy) ||
           (tileB.kind.isPadThai && !tileA.kind.isPuppy) {
            return true
        }

        let kindA = board.matchableStandardKind(at: a)
        let kindB = board.matchableStandardKind(at: b)
        guard kindA != kindB else { return false }
        var swapped = board
        swapped.swapTiles(at: a, and: b)
        return kindA.map { swapped.wouldCreateImmediateMatch(kind: $0, at: b) } == true
            || kindB.map { swapped.wouldCreateImmediateMatch(kind: $0, at: a) } == true
    }

    public static func findAllValidMoves(in board: BoardState) -> [ValidMove] {
        var moves: [ValidMove] = []
        for r in 0..<BoardState.rows {
            for c in 0..<BoardState.cols {
                let pos = GridPos(row: r, col: c)
                let right = GridPos(row: r, col: c + 1)
                if c + 1 < BoardState.cols, isValidSwap(from: pos, to: right, in: board) {
                    moves.append(ValidMove(from: pos, to: right))
                }
                let down = GridPos(row: r + 1, col: c)
                if r + 1 < BoardState.rows, isValidSwap(from: pos, to: down, in: board) {
                    moves.append(ValidMove(from: pos, to: down))
                }
            }
        }
        return moves
    }

    public static func findBestHint(in board: BoardState) -> ValidMove? {
        let moves = findAllValidMoves(in: board)
        guard !moves.isEmpty else { return nil }

        if let specialMove = moves.first(where: { move in
            guard let a = board[move.from], let b = board[move.to] else { return false }
            return (a.special.isSpecial && b.special.isSpecial) ||
                   a.special == .goldenSwirl || b.special == .goldenSwirl
        }) {
            return specialMove
        }

        return moves.max { lhs, rhs in
            var copyL = board
            copyL.swapTiles(at: lhs.from, and: lhs.to)
            let countL = copyL.findMatches().reduce(0) { $0 + $1.positions.count }

            var copyR = board
            copyR.swapTiles(at: rhs.from, and: rhs.to)
            let countR = copyR.findMatches().reduce(0) { $0 + $1.positions.count }

            return countL < countR
        }
    }

    public static func shuffleBoard(_ board: inout BoardState) -> [TileMove] {
        var movablePositions: [GridPos] = []
        var movableTiles: [(GridPos, Tile)] = []

        for r in 0..<BoardState.rows {
            for c in 0..<BoardState.cols {
                let pos = GridPos(row: r, col: c)
                if let tile = board[pos], !tile.isLockedBySnore, !tile.kind.isPuppy {
                    movablePositions.append(pos)
                    movableTiles.append((pos, tile))
                }
            }
        }

        guard movablePositions.count >= 2 else { return [] }

        for _ in 0..<24 {
            var candidate = board
            var shuffled = movableTiles
            for i in stride(from: shuffled.count - 1, through: 1, by: -1) {
                let j = board.rng.nextInt(upperBound: i + 1)
                shuffled.swapAt(i, j)
            }

            for dest in movablePositions { candidate[dest] = nil }
            var moves: [TileMove] = []
            for dest in movablePositions {
                guard let index = shuffled.firstIndex(where: { _, tile in
                    guard tile.special != .goldenSwirl, let kind = tile.kind.standardKind else { return true }
                    return !candidate.wouldCreateImmediateMatch(kind: kind, at: dest)
                }) else { break }
                let (start, tile) = shuffled.remove(at: index)
                candidate[dest] = tile
                if start != dest { moves.append(TileMove(tileId: tile.id, from: start, to: dest)) }
            }

            if shuffled.isEmpty && !moves.isEmpty && !findAllValidMoves(in: candidate).isEmpty {
                candidate.rng = board.rng
                board = candidate
                return moves
            }
        }

        return []
    }
}
