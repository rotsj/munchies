public enum SnackRunKind: CaseIterable, Hashable, Sendable {
    case biltemaDash
    case pokeOrder

    public var title: String {
        switch self {
        case .biltemaDash: "Biltema Dash"
        case .pokeOrder: "Partille Poke Order"
        }
    }

    public var rewardName: String {
        switch self {
        case .biltemaDash: "Korv Rocket"
        case .pokeOrder: "Fiesta Bomb"
        }
    }

    var reward: SpecialModifier {
        switch self {
        case .biltemaDash: .korvRocket(.horizontal)
        case .pokeOrder: .fiestaBomb
        }
    }
}

public enum SnackRunGoal: Hashable, Sendable {
    case biltemaDash(receipts: [GridPos])
    case pokeOrder(first: StandardTileKind)

    public var kind: SnackRunKind {
        switch self {
        case .biltemaDash: .biltemaDash
        case .pokeOrder: .pokeOrder
        }
    }
}

public enum SnackRunState: Hashable, Sendable {
    case idle
    case offered([SnackRunGoal])
    case active(ActiveSnackRun)
}

public struct ActiveSnackRun: Hashable, Sendable {
    static let moveLimit = 6

    public let goal: SnackRunGoal
    public private(set) var movesRemaining = Self.moveLimit
    public private(set) var remainingReceipts: Set<GridPos> = []
    public private(set) var ingredientsMatched = 0

    init(goal: SnackRunGoal) {
        self.goal = goal
        if case .biltemaDash(let receipts) = goal { remainingReceipts = Set(receipts) }
    }

    var isComplete: Bool {
        switch goal {
        case .biltemaDash: remainingReceipts.isEmpty
        case .pokeOrder: ingredientsMatched == 2
        }
    }

    mutating func apply(_ turn: SnackRunTurn) {
        movesRemaining -= 1
        switch goal {
        case .biltemaDash:
            remainingReceipts.subtract(turn.clearedPositions)
        case .pokeOrder(let first):
            let required = ingredientsMatched == 0 ? first : .partillePoke
            if turn.matchedKinds.contains(required) { ingredientsMatched += 1 }
        }
    }
}

struct SnackRunTurn {
    var clearedPositions: Set<GridPos> = []
    var matchedKinds: Set<StandardTileKind> = []
    var openingMatchPositions: Set<GridPos> = []
    var openingMatchKinds: Set<StandardTileKind> = []

    init(steps: [BoardStep]) {
        for step in steps {
            switch step {
            case .matchCleared(let positions, let depth, _, let kinds):
                clearedPositions.formUnion(positions)
                matchedKinds.formUnion(kinds)
                if depth == 1 {
                    openingMatchPositions.formUnion(positions)
                    openingMatchKinds.formUnion(kinds)
                }
            case .specialTriggered(_, _, let positions, _), .puppyRescued(_, let positions, _):
                clearedPositions.formUnion(positions)
            default:
                break
            }
        }
    }
}

enum SnackRunPlanner {
    static func isOfferTurn(_ moves: Int) -> Bool {
        moves >= 10 && (moves - 10).isMultiple(of: 25)
    }

    static func goals(for game: CascadeResolver) -> [SnackRunGoal] {
        let moves = MoveValidator.findAllValidMoves(in: game.board)
        let tacoMoves = moves.filter { makesMatch(.hermanosTaco, with: $0, in: game.board) }
        // The real resolver proves two-swap routes on copies. Start with visible matches,
        // so a player can pursue the goal without needing to predict a random refill.
        let firstMoves = moves.prefix(12)
        let openings = Array(firstMoves) + tacoMoves.prefix(6).filter { !firstMoves.contains($0) }
        var dash: SnackRunGoal?
        var ingredient: StandardTileKind?

        for first in openings {
            var afterFirst = game
            let firstTurn = SnackRunTurn(steps: afterFirst.resolveSwap(from: first.from, to: first.to))
            guard !afterFirst.isGameOver, !firstTurn.openingMatchPositions.isEmpty else { continue }
            let firstReceipt = firstTurn.openingMatchPositions.sorted().first { canMark($0, in: game.board) }
            let firstIngredient = firstTurn.openingMatchKinds.contains(.hermanosTaco) ? .hermanosTaco
                : StandardTileKind.allCases.first { $0 != .partillePoke && firstTurn.openingMatchKinds.contains($0) }

            let replies = MoveValidator.findAllValidMoves(in: afterFirst.board)
            let pokeMoves = firstIngredient == nil || ingredient == .hermanosTaco ? []
                : replies.filter { makesMatch(.partillePoke, with: $0, in: afterFirst.board) }
            let dashMoves = dash == nil && firstReceipt != nil ? replies.prefix(4).filter { !pokeMoves.prefix(2).contains($0) } : []
            for second in Array(pokeMoves.prefix(2)) + dashMoves {
                var afterSecond = afterFirst
                let secondTurn = SnackRunTurn(steps: afterSecond.resolveSwap(from: second.from, to: second.to))
                guard !afterSecond.isGameOver else { continue }

                if dash == nil, let firstReceipt {
                    let others = secondTurn.openingMatchPositions.subtracting(firstTurn.clearedPositions)
                        .filter { canMark($0, in: game.board) }.sorted()
                    if others.count >= 2, let earliest = others.first, let latest = others.last {
                        dash = .biltemaDash(receipts: [firstReceipt, earliest, latest].sorted())
                    }
                }
                if (ingredient == nil || firstIngredient == .hermanosTaco),
                   let firstIngredient, secondTurn.openingMatchKinds.contains(.partillePoke) {
                    ingredient = firstIngredient
                }
                if let dash, ingredient == .hermanosTaco { return [dash, .pokeOrder(first: .hermanosTaco)] }
            }
        }

        return [dash, ingredient.map { .pokeOrder(first: $0) }].compactMap { $0 }
    }

    private static func canMark(_ position: GridPos, in board: BoardState) -> Bool {
        guard let tile = board[position] else { return false }
        return tile.kind.standardKind != nil && !tile.isLockedBySnore
    }

    private static func makesMatch(_ kind: StandardTileKind, with move: ValidMove, in board: BoardState) -> Bool {
        let fromKind = board.matchableStandardKind(at: move.from)
        let toKind = board.matchableStandardKind(at: move.to)
        guard fromKind == kind || toKind == kind else { return false }
        var swapped = board
        swapped.swapTiles(at: move.from, and: move.to)
        return (fromKind == kind && swapped.wouldCreateImmediateMatch(kind: kind, at: move.to))
            || (toKind == kind && swapped.wouldCreateImmediateMatch(kind: kind, at: move.from))
    }
}
