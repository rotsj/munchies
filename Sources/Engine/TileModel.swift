/// Grid coordinate on the 8x9 Munchies board.
/// `row == 0` is the top row (spawn edge); `row == 8` is the bottom row (puppy rescue edge).
public struct GridPos: Hashable, Codable, Sendable, Comparable {
    public let row: Int
    public let col: Int

    public init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }

    public static func < (lhs: GridPos, rhs: GridPos) -> Bool {
        if lhs.row != rhs.row { return lhs.row < rhs.row }
        return lhs.col < rhs.col
    }

    public func isAdjacent(to other: GridPos) -> Bool {
        let dr = abs(row - other.row)
        let dc = abs(col - other.col)
        return (dr == 1 && dc == 0) || (dr == 0 && dc == 1)
    }

    public func orthogonalNeighbors(rows: Int, cols: Int) -> [GridPos] {
        let candidates = [
            GridPos(row: row - 1, col: col),
            GridPos(row: row + 1, col: col),
            GridPos(row: row, col: col - 1),
            GridPos(row: row, col: col + 1)
        ]
        return candidates.filter { $0.row >= 0 && $0.row < rows && $0.col >= 0 && $0.col < cols }
    }
}

/// The 6 standard snack tile types.
public enum StandardTileKind: String, CaseIterable, Hashable, Codable, Sendable {
    case cupcake
    case teido
    case hermanosTaco
    case partillePoke
    case biltemaCombo
    case bigMac

    public var displayName: String {
        switch self {
        case .cupcake: return "Cupcake"
        case .teido: return "Teido"
        case .hermanosTaco: return "Hermanos Taco"
        case .partillePoke: return "Partille Poke Bowl"
        case .biltemaCombo: return "Biltema Combo"
        case .bigMac: return "Big Mac"
        }
    }
}

/// All tile kinds that can occupy a cell on the board.
public enum TileKind: Hashable, Codable, Sendable {
    case standard(StandardTileKind)
    case puppy
    case padThai

    public var standardKind: StandardTileKind? {
        if case .standard(let kind) = self { return kind }
        return nil
    }

    public var isPuppy: Bool {
        if case .puppy = self { return true }
        return false
    }

    public var isPadThai: Bool {
        if case .padThai = self { return true }
        return false
    }
}

/// Orientation for the Biltema Korv Rocket power-up.
public enum RocketOrientation: String, Hashable, Codable, Sendable {
    case horizontal
    case vertical
}

/// Special power-up modifiers earned via 4-in-a-line, L/T 5-match, or straight 5-match.
public enum SpecialModifier: Hashable, Codable, Sendable {
    case none
    case korvRocket(RocketOrientation)
    case fiestaBomb
    case goldenSwirl

    public var isSpecial: Bool {
        if case .none = self { return false }
        return true
    }
}

/// State of a Teido Snore Bubble locking a tile in a drowsy haze.
public struct SnoreBubble: Hashable, Codable, Sendable {
    public var hitsRemaining: Int
    public var isDrifting: Bool
    public var turnsSinceDrift: Int
    public let spawnedOrder: Int

    public init(
        hitsRemaining: Int = 1,
        isDrifting: Bool = false,
        turnsSinceDrift: Int = 0,
        spawnedOrder: Int = 0
    ) {
        self.hitsRemaining = hitsRemaining
        self.isDrifting = isDrifting
        self.turnsSinceDrift = turnsSinceDrift
        self.spawnedOrder = spawnedOrder
    }

    public var isDoubleZzz: Bool {
        hitsRemaining >= 2
    }
}

/// A single tile occupying a cell on the board.
public struct Tile: Identifiable, Hashable, Codable, Sendable {
    public let id: Int
    public var kind: TileKind
    public var special: SpecialModifier
    public var snore: SnoreBubble?

    public init(
        id: Int,
        kind: TileKind,
        special: SpecialModifier = .none,
        snore: SnoreBubble? = nil
    ) {
        self.id = id
        self.kind = kind
        self.special = special
        self.snore = snore
    }

    public var isLockedBySnore: Bool {
        snore != nil
    }

    public var isSwappable: Bool {
        !isLockedBySnore
    }
}

/// Deterministic SplitMix64 PRNG for 100% reproducible boards and tests.
public struct SeededRNG: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func nextInt(upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return Int(next() % UInt64(upperBound))
    }

    public mutating func nextDouble() -> Double {
        Double(next() >> 11) * (1.0 / Double(1 << 53))
    }
}
