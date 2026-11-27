public enum CravingSpecial: Hashable, Sendable {
    case rockets, bombs, combinations

    func counts(_ activation: SpecialActivationKind) -> Bool {
        switch (self, activation) {
        case (.rockets, .korvRocketHorizontal), (.rockets, .korvRocketVertical),
             (.rockets, .rocketPlusRocket), (.rockets, .rocketPlusBomb), (.rockets, .swirlPlusRocket),
             (.bombs, .fiestaBomb), (.bombs, .bombPlusBomb), (.bombs, .rocketPlusBomb), (.bombs, .swirlPlusBomb),
             (.combinations, .rocketPlusRocket), (.combinations, .rocketPlusBomb), (.combinations, .bombPlusBomb),
             (.combinations, .swirlPlusRocket), (.combinations, .swirlPlusBomb), (.combinations, .swirlPlusSwirl):
            true
        default:
            false
        }
    }
}

public enum CravingGoal: Hashable, Sendable {
    case snacks(StandardTileKind, Int)
    case favorites(Int)
    case puppies(Int)
    case snores(Int)
    case specials(CravingSpecial, Int)

    public var target: Int {
        switch self {
        case .snacks(_, let target), .favorites(let target), .puppies(let target),
             .snores(let target), .specials(_, let target): target
        }
    }

    func collectionCredit(_ kind: StandardTileKind) -> Int {
        switch self {
        case .snacks(let targetKind, _) where targetKind == kind: 1
        case .favorites where kind == .cupcake || kind == .bigMac: 2
        default: 0
        }
    }
}

/// Numbered stages form four themed chapters that repeat at gently increasing difficulty.
public struct CravingStage: Hashable, Sendable {
    public static let stagesPerChapter = 5

    public let number: Int
    public let chapterTheme: String
    public let chapterSnack: StandardTileKind
    public let encore: Int
    public let stageInChapter: Int
    public let difficultyTier: Int
    public let moveLimit: Int
    public let goals: [CravingGoal]
    public let spotlight: CravingSurge

    public var isFinale: Bool { stageInChapter == Self.stagesPerChapter }

    public init(number: Int) {
        self.number = max(1, number)
        let index = self.number - 1
        let chapter = index / Self.stagesPerChapter
        let themes: [(String, StandardTileKind)] = [
            ("Biltema Run", .biltemaCombo), ("Hermanos Taco Night", .hermanosTaco),
            ("Partille Poke Date", .partillePoke), ("PS5 After Dark", .teido)
        ]
        let themeIndex = chapter % themes.count
        let (theme, snack) = themes[themeIndex]
        chapterTheme = theme
        chapterSnack = snack
        encore = chapter / themes.count
        stageInChapter = index % Self.stagesPerChapter + 1
        difficultyTier = 1 + min(14, index / 4)
        let growth = min(3, index / 15)
        let late = difficultyTier >= 8

        switch stageInChapter {
        case 1:
            moveLimit = late ? 16 : 13
            goals = [.snacks(snack, 12 + growth)]
            spotlight = .none
        case 2:
            moveLimit = late ? 9 : 8
            goals = [.snores(4)]
            spotlight = .none
        case 3:
            moveLimit = 6
            goals = [.puppies(1)]
            spotlight = .none
        case 4 where chapter.isMultiple(of: 2):
            moveLimit = late ? 12 : 10
            goals = [.favorites(28 + growth * 2)]
            spotlight = .cupcake
        case 4:
            moveLimit = late ? 12 : 10
            goals = [.specials(.rockets, 2)]
            spotlight = .teido
        default:
            let comboFinale = themeIndex == 3
            moveLimit = late ? (comboFinale ? 13 : 17) : (comboFinale ? 11 : 15)
            let finaleGoals: [CravingGoal] = [.snores(3), .specials(.bombs, 1), .puppies(1), .specials(.combinations, 1)]
            goals = [.snacks(snack, (comboFinale ? 18 : 16) + growth), finaleGoals[themeIndex]]
            spotlight = .none
        }
    }
}

public enum CravingStageResult: Hashable, Sendable {
    case cleared(stars: Int, bonusMoves: Int)
    case outOfSwaps
    case blocked(GameOverReason)
}

public struct CravingObjective: Hashable, Sendable {
    public let goal: CravingGoal
    public private(set) var progress = 0

    public var remaining: Int { goal.target - progress }

    mutating func add(_ amount: Int) {
        progress += min(remaining, amount)
    }
}

public struct CravingAttempt: Hashable, Sendable {
    public let definition: CravingStage
    public private(set) var movesRemaining: Int
    public private(set) var objectives: [CravingObjective]
    public private(set) var result: CravingStageResult?

    public var progressFraction: Double {
        objectives.reduce(0.0) { $0 + Double($1.progress) / Double($1.goal.target) } / Double(objectives.count)
    }

    init(_ definition: CravingStage) {
        self.definition = definition
        movesRemaining = definition.moveLimit
        objectives = definition.goals.map { CravingObjective(goal: $0) }
    }

    mutating func spendSwap() { movesRemaining -= 1 }

    mutating func collect(_ kind: StandardTileKind?) {
        guard let kind else { return }
        for index in objectives.indices {
            let count = objectives[index].goal.collectionCredit(kind)
            objectives[index].add(count)
        }
    }

    var refillBias: (kind: StandardTileKind, extraWeight: Int)? {
        for objective in objectives where objective.remaining > 0 {
            let kind: StandardTileKind
            switch objective.goal {
            case .snacks(let target, _): kind = target
            case .favorites: kind = .bigMac
            default: continue
            }
            let close = movesRemaining <= 3 && objective.remaining <= 6
            let weight = 16 + min(14, definition.difficultyTier)
            return (kind, close ? weight + 26 : weight)
        }
        return nil
    }

    mutating func finishSwap(_ steps: [BoardStep], blocked reason: GameOverReason?) {
        for index in objectives.indices {
            let goal = objectives[index].goal
            switch goal {
            case .snacks, .favorites: break
            case .puppies:
                for case .puppyRescued in steps { objectives[index].add(1) }
            case .snores:
                for case .snorePopped in steps { objectives[index].add(1) }
            case .specials(let special, _):
                for case .specialTriggered(let kind, _, _, _) in steps where special.counts(kind) {
                    objectives[index].add(1)
                }
            }
        }
        if objectives.allSatisfy({ $0.remaining == 0 }) {
            let stars = movesRemaining >= 5 ? 3 : (movesRemaining >= 2 ? 2 : 1)
            result = .cleared(stars: stars, bonusMoves: movesRemaining)
        } else if let reason {
            result = .blocked(reason)
        } else if movesRemaining == 0 {
            result = .outOfSwaps
        }
    }

    mutating func block(_ reason: GameOverReason) { result = .blocked(reason) }

    /// Prefer visible progress toward an unfinished goal without predicting the refill.
    func hint(in board: BoardState) -> ValidMove? {
        let moves = MoveValidator.findAllValidMoves(in: board)
        let puppies = board.grid.enumerated().flatMap { row, tiles in
            tiles.indices.compactMap { col in
                tiles[col]?.kind.isPuppy == true ? GridPos(row: row, col: col) : nil
            }
        }
        var preferred: ValidMove?
        var best = Int.min
        for move in moves {
            var swapped = board
            swapped.swapTiles(at: move.from, and: move.to)
            let groups = swapped.findMatches()
            let hits = Set(groups.flatMap(\.positions))
            let pair = [swapped[move.from], swapped[move.to]].compactMap { $0 }
            let combo = pair.filter { $0.special.isSpecial }.count == 2
            let axis: SwipeAxis = move.from.row == move.to.row ? .horizontal : .vertical
            var value = hits.count + (combo ? 12 : 0)
            for objective in objectives where objective.remaining > 0 {
                switch objective.goal {
                case .snacks, .favorites:
                    for group in groups { value += group.positions.count * objective.goal.collectionCredit(group.kind) * 4 }
                case .snores:
                    let adjacent = Set(hits.flatMap { $0.orthogonalNeighbors(rows: BoardState.rows, cols: BoardState.cols) })
                    value += adjacent.filter { swapped[$0]?.isLockedBySnore == true }.count * 12
                case .puppies:
                    for puppy in puppies {
                        let after = puppy == move.from ? move.to : (puppy == move.to ? move.from : puppy)
                        value += hits.filter { $0.col == after.col && $0.row > after.row }.count * 12
                        value += (after.row - puppy.row) * 12
                    }
                case .specials(let special, _):
                    if combo && special == .combinations { value += 28 }
                    for tile in pair where combo && special.matches(tile.special) { value += 18 }
                    for cell in hits where swapped[cell].map({ special.matches($0.special) }) == true { value += 18 }
                    for group in groups where special.matches(group.earnedSpecial(swipeDirection: axis)) { value += 10 }
                }
            }
            if value > best {
                best = value
                preferred = move
            }
        }
        return preferred
    }
}

private extension CravingSpecial {
    func matches(_ modifier: SpecialModifier) -> Bool {
        switch (self, modifier) {
        case (.rockets, .korvRocket), (.bombs, .fiestaBomb): true
        default: false
        }
    }
}
