/// Movement of an existing tile during gravity or shuffle.
public struct TileMove: Hashable, Codable, Sendable {
    public let tileId: Int
    public let from: GridPos
    public let to: GridPos

    public init(tileId: Int, from: GridPos, to: GridPos) {
        self.tileId = tileId
        self.from = from
        self.to = to
    }
}

/// Newly generated tile entering the board from above row 0.
public struct TileSpawn: Hashable, Codable, Sendable {
    public let tile: Tile
    public let at: GridPos
    public let spawnRowOffset: Int

    public init(tile: Tile, at: GridPos, spawnRowOffset: Int) {
        self.tile = tile
        self.at = at
        self.spawnRowOffset = spawnRowOffset
    }
}

/// Type of special detonation or combo for animations and audio/visual feedback.
public enum SpecialActivationKind: String, Hashable, Codable, Sendable {
    case korvRocketHorizontal
    case korvRocketVertical
    case fiestaBomb
    case goldenSwirl
    case rocketPlusRocket
    case rocketPlusBomb
    case bombPlusBomb
    case swirlPlusRocket
    case swirlPlusBomb
    case swirlPlusSwirl
    case padThaiCross
}

/// Dynamic avatar reaction cues emitted by the engine for the Co-op Corner HUD.
public enum AvatarReaction: Hashable, Codable, Sendable {
    case cupcakeCheerBigMac
    case cupcakeCheerPuppy
    case cupcakeSnoreAlert
    case teidoNoddingOff
    case teidoComboWakeUp(cascadeDepth: Int)
    case teidoAchievementUnlocked
    case calm
}

/// Reason a run ended.
public enum GameOverReason: String, Hashable, Codable, Sendable {
    case snoreOverload // 12+ tiles locked by Snore Bubbles simultaneously
    case noValidMoves  // 0 valid swaps and 0 emergency shuffles left

    public var headline: String {
        switch self {
        case .snoreOverload:
            return "Teido Woke the Whole Neighborhood!"
        case .noValidMoves:
            return "Out of Snack Moves!"
        }
    }
}

/// Ordered discrete events emitted by `CascadeResolver` for every player turn or shuffle.
public enum BoardStep: Hashable, Sendable {
    case swap(from: GridPos, to: GridPos, reverted: Bool)
    case matchCleared(positions: [GridPos], cascadeDepth: Int, pointsAwarded: Int, matchedKinds: [StandardTileKind])
    case specialCreated(at: GridPos, tile: Tile)
    case specialTriggered(kind: SpecialActivationKind, origin: GridPos, affectedPositions: [GridPos], pointsAwarded: Int)
    case cupcakePacifierWave(from: GridPos, poppedSnoreAt: GridPos)
    case snoreDamaged(at: GridPos, remainingHits: Int)
    case snorePopped(at: GridPos, pointsAwarded: Int)
    case snoreSpawned(at: GridPos, bubble: SnoreBubble)
    case snoreDrifted(from: GridPos, to: GridPos)
    case gravityApplied(moves: [TileMove])
    case tilesSpawned(spawns: [TileSpawn])
    case puppySpawned(at: GridPos, tile: Tile)
    case puppyRescued(at: GridPos, blastPositions: [GridPos], pointsAwarded: Int)
    case teidoComboAchievement(rocketSpawnedAt: GridPos, tile: Tile)
    case tierUp(newTier: Int, surge: CravingSurge, bannerText: String, poppedSnores: [GridPos], bonusPoints: Int, earnedShuffle: Bool)
    case boardShuffled(moves: [TileMove], usedEmergencyShuffle: Bool)
    case snackRunCompleted(kind: SnackRunKind, at: GridPos, tile: Tile)
    case snackRunExpired(kind: SnackRunKind)
    case avatarReaction(AvatarReaction)
    case gameOver(reason: GameOverReason)
}

/// Cumulative per-run stats tracked by the engine for HUD, GameOver, and StorageManager milestones.
public struct RunStats: Hashable, Codable, Sendable {
    public var score: Int = 0
    public var tier: Int = 1
    public var tierProgress: Int = 0
    public var movesMade: Int = 0
    public var puppiesRescued: Int = 0
    public var bigMacsMatched: Int = 0
    public var fiestaBombsCreated: Int = 0
    public var snoreBubblesPopped: Int = 0
    public var teidoSurgesTriggered: Int = 0
    public var maxCascadeReached: Int = 0
    public var availableShuffles: Int = DifficultyConfig.startingEmergencyShuffles

    public init() {}
}
