/// Prepares objectives using the normal generator, then keeps the first swap readable.
enum CravingBoardSetup {
    static func makeBoard(stage: CravingStage, seed: UInt64) -> BoardState {
        var seeds = SeededRNG(seed: seed)
        var board = BoardState(seed: seed)
        while true {
            TileSpawner.populateInitialBoard(board: &board, tier: stage.difficultyTier)
            if MoveValidator.findAllValidMoves(in: board).count >= 3 && prepare(stage, on: &board) {
                return board
            }
            board = BoardState(seed: seeds.next())
        }
    }

    private static func prepare(_ stage: CravingStage, on board: inout BoardState) -> Bool {
        for goal in stage.goals {
            switch goal {
            case .puppies:
                guard placePuppy(on: &board) else { return false }
            case .snores(let count):
                for index in 0..<count {
                    let hits = stage.difficultyTier >= 8 && index.isMultiple(of: 2) ? 2 : 1
                    guard placeSnore(hits: hits, on: &board) else { return false }
                }
            case .specials(let special, _):
                guard placeSpecial(special, on: &board) else { return false }
            case .snacks, .favorites:
                break
            }
        }
        if stage.spotlight == .teido {
            guard let position = matchingPositions(in: board).first(where: { board[$0]?.special == SpecialModifier.none }) else { return false }
            // Pad Thai is itself legal to swap and doesn't introduce prematches.
            board[position]?.kind = .padThai
        }
        return MoveValidator.findAllValidMoves(in: board).count >= 3
    }

    private static func placePuppy(on board: inout BoardState) -> Bool {
        // Give the puppy two visible exits on the opening board. This avoids
        // depending on the refill to create a second setup in a single column.
        let moves = MoveValidator.findAllValidMoves(in: board)
        let start = board.rng.nextInt(upperBound: BoardState.cols)
        let bottom = BoardState.rows - 1
        for offset in 0..<BoardState.cols {
            let col = (start + offset) % BoardState.cols
            let position = GridPos(row: bottom - 1, col: col)
            let beneath = GridPos(row: bottom, col: col)
            var candidate = board
            candidate[position]?.kind = .puppy
            var exits = 0
            for move in moves where move.from != position && move.to != position {
                if matched(after: move, in: candidate).contains(beneath) { exits += 1 }
                if exits == 2 { break }
            }
            if exits == 2 && MoveValidator.findAllValidMoves(in: candidate).count >= 3 {
                board = candidate
                return true
            }
        }
        return false
    }

    private static func placeSnore(hits: Int, on board: inout BoardState) -> Bool {
        var open: Set<GridPos> = []
        for move in MoveValidator.findAllValidMoves(in: board) {
            let positions = matched(after: move, in: board)
            let match = Set(positions)
            let neighbors = Set(positions.flatMap { $0.orthogonalNeighbors(rows: BoardState.rows, cols: BoardState.cols) })
            for position in neighbors where !match.contains(position) && position != move.from && position != move.to {
                if board[position]?.snore == nil { open.insert(position) }
            }
        }
        let placed = board.snorePositionsOldestFirst
        func distance(_ position: GridPos) -> Int {
            placed.map { abs($0.row - position.row) + abs($0.col - position.col) }.min() ?? 0
        }
        let spread = open.sorted { lhs, rhs in
            let left = distance(lhs), right = distance(rhs)
            return left == right ? lhs < rhs : left > right
        }
        for position in spread {
            var candidate = board
            let bubble = candidate.makeSnoreBubble(hits: hits, isDrifting: false)
            candidate[position]?.snore = bubble
            if MoveValidator.findAllValidMoves(in: candidate).count >= 3 {
                board = candidate
                return true
            }
        }
        return false
    }

    private static func placeSpecial(_ special: CravingSpecial, on board: inout BoardState) -> Bool {
        guard let position = matchingPositions(in: board).first else { return false }
        switch special {
        case .rockets:
            board[position]?.special = .korvRocket(.horizontal)
        case .bombs:
            board[position]?.special = .fiestaBomb
        case .combinations:
            guard let neighbor = position.orthogonalNeighbors(rows: BoardState.rows, cols: BoardState.cols).first else { return false }
            board[position]?.special = .korvRocket(.horizontal)
            board[neighbor]?.special = .fiestaBomb
        }
        return true
    }

    private static func matchingPositions(in board: BoardState) -> [GridPos] {
        for move in MoveValidator.findAllValidMoves(in: board) {
            let positions = matched(after: move, in: board)
            if !positions.isEmpty {
                return positions.map { $0 == move.from ? move.to : ($0 == move.to ? move.from : $0) }
            }
        }
        return []
    }

    private static func matched(after move: ValidMove, in board: BoardState) -> [GridPos] {
        var after = board
        after.swapTiles(at: move.from, and: move.to)
        return after.findMatches().flatMap { $0.positions.sorted() }
    }
}
