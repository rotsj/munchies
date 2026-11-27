/// The campaign's fixed starting boards and objectives.
public enum MiniMission: Int, CaseIterable, Sendable {
    case puppyPickup = 1
    case biltemaDelivery = 2
    case couchCoop = 3

    public var title: String {
        switch self {
        case .puppyPickup: "Puppy Pickup"
        case .biltemaDelivery: "Biltema Delivery"
        case .couchCoop: "Couch Co-op"
        }
    }

    public var instruction: String {
        switch self {
        case .puppyPickup: "Guide both puppies to the bottom row."
        case .biltemaDelivery: "Make a line of 4 for a Korv Rocket. Blast the blue flag."
        case .couchCoop: "Make an L or T of 5 for a Fiesta Bomb. Swap it with a Korv Rocket."
        }
    }

    public var moveLimit: Int {
        switch self {
        case .puppyPickup: 5
        case .biltemaDelivery: 6
        case .couchCoop: 7
        }
    }

    public var next: MiniMission? { MiniMission(rawValue: rawValue + 1) }

    public var counter: GridPos? {
        self == .biltemaDelivery ? GridPos(row: 4, col: 7) : nil
    }

    func makeBoard() -> BoardState {
        let seed: UInt64
        switch self {
        case .puppyPickup: seed = 42
        case .biltemaDelivery: seed = 127
        case .couchCoop: seed = 79
        }
        var board = BoardState(seed: seed)
        TileSpawner.populateInitialBoard(board: &board, tier: 1)
        switch self {
        case .puppyPickup:
            board[3, 1]?.kind = .puppy
            board[4, 6]?.kind = .puppy
        case .biltemaDelivery:
            break
        case .couchCoop:
            board[5, 3]?.special = .korvRocket(.horizontal)
        }
        return board
    }
}

public enum MissionResult: Equatable, Sendable {
    case cleared
    case outOfSwaps
    case noValidMoves
}

public struct MissionAttempt: Sendable {
    public let definition: MiniMission
    public private(set) var movesRemaining: Int
    public private(set) var puppiesHome = 0
    public private(set) var result: MissionResult?

    init(_ definition: MiniMission) {
        self.definition = definition
        self.movesRemaining = definition.moveLimit
    }

    mutating func finishTurn(_ steps: [BoardStep], deadlocked: Bool) {
        movesRemaining -= 1
        if reachedGoal(steps) { result = .cleared }
        else if movesRemaining == 0 { result = .outOfSwaps }
        else if deadlocked { result = .noValidMoves }
    }

    private mutating func reachedGoal(_ steps: [BoardStep]) -> Bool {
        switch definition {
        case .puppyPickup:
            for case .puppyRescued in steps { puppiesHome += 1 }
            return puppiesHome >= 2
        case .biltemaDelivery:
            guard let counter = definition.counter else { return false }
            for case .specialTriggered(let kind, _, let affected, _) in steps where affected.contains(counter) {
                switch kind {
                case .korvRocketHorizontal, .korvRocketVertical, .rocketPlusRocket, .rocketPlusBomb, .swirlPlusRocket:
                    return true
                default:
                    break
                }
            }
            return false
        case .couchCoop:
            return steps.contains { step in
                if case .specialTriggered(.rocketPlusBomb, _, _, _) = step { return true }
                return false
            }
        }
    }
}
