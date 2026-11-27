import Engine
import FoundationEssentials
import JavaScriptKit

/// The tiered Polaroids in the Couple's Milestone Scrapbook.
enum ScrapbookMilestone: String, CaseIterable, Codable {
    case korvDash
    case bigMacRun
    case padThaiPS5Night
    case tacoTuesday
    case pokeDate
    case firstPuppyAdopted
    case packLeader
    case survivedSnoring
    case cravingTrail

    var title: String {
        switch self {
        case .korvDash: return "Pre-17:00 Korv Dash"
        case .bigMacRun: return "Cupcake's Big Mac Run"
        case .padThaiPS5Night: return "Teido's Pad Thai & PS5 Night"
        case .tacoTuesday: return "Hermanos Taco Tuesday"
        case .pokeDate: return "Partille Poke Date"
        case .firstPuppyAdopted: return "First Puppy Adopted"
        case .packLeader: return "Pack Leader"
        case .survivedSnoring: return "Survived Teido's Snoring"
        case .cravingTrail: return "Craving Trail Postcards"
        }
    }

    var requirementText: String {
        switch self {
        case .korvDash: return "Score 10,000 cumulative points"
        case .bigMacRun: return "Match 100 Big Mac tiles"
        case .padThaiPS5Night: return "Trigger 10 Teido Craving Surges"
        case .tacoTuesday: return "Create 15 Fiesta Bombs"
        case .pokeDate: return "Trigger a 5x cascade combo"
        case .firstPuppyAdopted: return "Rescue 1 Puppy"
        case .packLeader: return "Rescue 25 Puppies"
        case .survivedSnoring: return "Pop 50 Snore Bubbles"
        case .cravingTrail: return "Clear a chapter finale"
        }
    }

    var firstGoal: UInt64 {
        switch self {
        case .korvDash: return 10_000
        case .bigMacRun: return 100
        case .padThaiPS5Night: return 10
        case .tacoTuesday: return 15
        case .pokeDate, .firstPuppyAdopted, .cravingTrail: return 1
        case .packLeader: return 25
        case .survivedSnoring: return 50
        }
    }

    var progressUnit: String {
        switch self {
        case .korvDash: return "points"
        case .bigMacRun: return "Big Macs"
        case .padThaiPS5Night: return "Teido surges"
        case .tacoTuesday: return "Fiesta Bombs"
        case .pokeDate: return "5×+ cascades"
        case .firstPuppyAdopted, .packLeader: return "puppies"
        case .survivedSnoring: return "snore bubbles"
        case .cravingTrail: return "chapter finales"
        }
    }

    func total(in data: PersistedProgress) -> UInt64 {
        switch self {
        case .korvDash: return data.cumulativeScore
        case .bigMacRun: return data.totalBigMacsMatched
        case .padThaiPS5Night: return data.totalTeidoSurgesTriggered
        case .tacoTuesday: return data.totalFiestaBombsCreated
        case .pokeDate: return data.fivePlusCascades
        case .firstPuppyAdopted, .packLeader: return data.totalPuppiesRescued
        case .survivedSnoring: return data.totalSnoreBubblesPopped
        case .cravingTrail: return UInt64(data.cravingsCleared / CravingStage.stagesPerChapter)
        }
    }

    var rewardText: String {
        switch self {
        case .korvDash: return "Biltema blue-and-white board trim"
        case .bigMacRun: return "Golden sparkles on Big Mac matches"
        case .padThaiPS5Night: return "Neon controller-glow backdrop"
        case .tacoTuesday: return "Warm fiesta sunset backdrop"
        case .pokeDate: return "Coastal pastel backdrop"
        case .firstPuppyAdopted: return "Sleeping puppy next to Cupcake"
        case .packLeader: return "Puppy Paw tile trail effect"
        case .survivedSnoring: return "Midnight-blue Light Sleeper theme"
        case .cravingTrail: return "Trail Dusk backdrop"
        }
    }

    var emoji: String {
        switch self {
        case .korvDash: return "🌭🍦"
        case .bigMacRun: return "🍔✨"
        case .padThaiPS5Night: return "🎮🍜"
        case .tacoTuesday: return "🌮🎉"
        case .pokeDate: return "🥗🌊"
        case .firstPuppyAdopted: return "🐶💤"
        case .packLeader: return "🐾👑"
        case .survivedSnoring: return "🌙😴"
        case .cravingTrail: return "🗺️🌙"
        }
    }
}

enum BackdropTheme: String, CaseIterable, Codable {
    case cozyDefault
    case neonPS5
    case fiestaSunset
    case coastalPastel
    case midnightLightSleeper
    case trailDusk

    var displayName: String {
        switch self {
        case .cozyDefault: return "Cozy Night Owl"
        case .neonPS5: return "PS5 Neon Glow"
        case .fiestaSunset: return "Fiesta Sunset"
        case .coastalPastel: return "Partille Coastal"
        case .midnightLightSleeper: return "Light Sleeper"
        case .trailDusk: return "Trail Dusk"
        }
    }
}

struct PersistedProgress: Codable {
    var highScore: Int = 0
    var cumulativeScore: UInt64 = 0
    var totalPuppiesRescued: UInt64 = 0
    var totalBigMacsMatched: UInt64 = 0
    var totalTeidoSurgesTriggered: UInt64 = 0
    var totalFiestaBombsCreated: UInt64 = 0
    var bestCascadeCombo: Int = 0
    var totalFivePlusCascades: UInt64?
    var totalSnoreBubblesPopped: UInt64 = 0
    var highestTierReached: Int = 1
    var highestMissionCleared: Int? // Retained when rewriting a save from the earlier Missions release.
    var highestCravingCleared: Int?
    var cravingStars: UInt64?

    var soundEffectsEnabled: Bool = true
    var backgroundMusicEnabled: Bool?
    var goofySnoreSoundsEnabled: Bool = true
    var screenShakeEnabled: Bool = true
    var selectedBackdrop: BackdropTheme = .cozyDefault

    var musicEnabled: Bool { backgroundMusicEnabled ?? true }

    var cravingsCleared: Int { max(0, highestCravingCleared ?? 0) }
    var nextCraving: Int { cravingsCleared == Int.max ? Int.max : cravingsCleared + 1 }

    var fivePlusCascades: UInt64 {
        // Older saves only kept the best cascade, which proves at least one qualifying turn.
        max(totalFivePlusCascades ?? 0, bestCascadeCombo >= 5 ? 1 : 0)
    }
}

/// Browser `localStorage` JSON persistence wrapper for Munchies.
final class StorageManager {
    private let storageKey = "munchies.pwa.progress.v1"
    var data: PersistedProgress

    init() {
        if let storage = JSObject.global.localStorage.object,
           let json = storage.getItem?(storageKey).string,
           let decoded = try? JSONDecoder().decode(PersistedProgress.self, from: Data(json.utf8)) {
            self.data = decoded
        } else {
            self.data = PersistedProgress()
        }
    }

    func save() {
        guard let encoded = try? JSONEncoder().encode(data),
              let storage = JSObject.global.localStorage.object else { return }
        _ = storage.setItem?(storageKey, String(decoding: encoded, as: UTF8.self))
    }

    func isUnlocked(_ milestone: ScrapbookMilestone) -> Bool {
        milestone.total(in: data) >= milestone.firstGoal
    }

    func progress(for milestone: ScrapbookMilestone) -> MilestoneProgress {
        MilestoneProgress(total: milestone.total(in: data), firstGoal: milestone.firstGoal)
    }

    var tiersEarned: UInt64 {
        ScrapbookMilestone.allCases.reduce(0) { $0 + progress(for: $1).tiersEarned }
    }

    var cosmetics: BoardCosmetics {
        BoardCosmetics(
            biltemaTrimUnlocked: isUnlocked(.korvDash),
            goldenSesameSparklesUnlocked: isUnlocked(.bigMacRun),
            puppyPawTrailUnlocked: isUnlocked(.packLeader)
        )
    }

    func isThemeUnlocked(_ theme: BackdropTheme) -> Bool {
        switch theme {
        case .cozyDefault: return true
        case .neonPS5: return isUnlocked(.padThaiPS5Night)
        case .fiestaSunset: return isUnlocked(.tacoTuesday)
        case .coastalPastel: return isUnlocked(.pokeDate)
        case .midnightLightSleeper: return isUnlocked(.survivedSnoring)
        case .trailDusk: return isUnlocked(.cravingTrail)
        }
    }

    func recordProgress(from previous: RunStats, to current: RunStats, steps: [BoardStep], stage: CravingAttempt?) {
        guard previous.movesMade != current.movesMade else { return }
        data.highScore = max(data.highScore, current.score)
        data.cumulativeScore = adding(current.score - previous.score, to: data.cumulativeScore)
        data.totalPuppiesRescued = adding(current.puppiesRescued - previous.puppiesRescued, to: data.totalPuppiesRescued)
        data.totalBigMacsMatched = adding(current.bigMacsMatched - previous.bigMacsMatched, to: data.totalBigMacsMatched)
        data.totalTeidoSurgesTriggered = adding(current.teidoSurgesTriggered - previous.teidoSurgesTriggered, to: data.totalTeidoSurgesTriggered)
        data.totalFiestaBombsCreated = adding(current.fiestaBombsCreated - previous.fiestaBombsCreated, to: data.totalFiestaBombsCreated)
        if steps.contains(where: { step in
            if case .matchCleared(_, let depth, _, _) = step { return depth >= 5 }
            return false
        }) {
            data.totalFivePlusCascades = adding(1, to: data.fivePlusCascades)
        }
        data.bestCascadeCombo = max(data.bestCascadeCombo, current.maxCascadeReached)
        data.totalSnoreBubblesPopped = adding(current.snoreBubblesPopped - previous.snoreBubblesPopped, to: data.totalSnoreBubblesPopped)
        data.highestTierReached = max(data.highestTierReached, current.tier)
        if let stage, case .cleared(let stars, _) = stage.result,
           stage.definition.number == data.nextCraving, stage.definition.number > data.cravingsCleared {
            data.highestCravingCleared = stage.definition.number
            data.cravingStars = adding(stars, to: data.cravingStars ?? 0)
            if stage.definition.spotlight == .teido {
                data.totalTeidoSurgesTriggered = adding(1, to: data.totalTeidoSurgesTriggered)
            }
        }
        save()
    }

    private func adding(_ increase: Int, to total: UInt64) -> UInt64 {
        total + min(UInt64(clamping: increase), UInt64.max - total)
    }
}
