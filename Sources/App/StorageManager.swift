import Engine
import FoundationEssentials
import JavaScriptKit

/// The 8 Couple's Milestone Scrapbook Polaroids persisted in `localStorage`.
enum ScrapbookMilestone: String, CaseIterable, Codable {
    case korvDash
    case bigMacRun
    case padThaiPS5Night
    case tacoTuesday
    case pokeDate
    case firstPuppyAdopted
    case packLeader
    case survivedSnoring

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
        }
    }

    var rewardText: String {
        switch self {
        case .korvDash: return "Biltema blue-and-white board trim"
        case .bigMacRun: return "Golden sesame-seed tile border"
        case .padThaiPS5Night: return "Neon controller-glow backdrop"
        case .tacoTuesday: return "Warm fiesta sunset backdrop"
        case .pokeDate: return "Coastal pastel backdrop"
        case .firstPuppyAdopted: return "Sleeping puppy next to Cupcake"
        case .packLeader: return "Puppy Paw tile trail effect"
        case .survivedSnoring: return "Midnight-blue Light Sleeper theme"
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
        }
    }
}

enum BackdropTheme: String, CaseIterable, Codable {
    case cozyDefault
    case neonPS5
    case fiestaSunset
    case coastalPastel
    case midnightLightSleeper

    var displayName: String {
        switch self {
        case .cozyDefault: return "Cozy Night Owl"
        case .neonPS5: return "PS5 Neon Glow"
        case .fiestaSunset: return "Fiesta Sunset"
        case .coastalPastel: return "Partille Coastal"
        case .midnightLightSleeper: return "Light Sleeper"
        }
    }
}

struct PersistedProgress: Codable {
    var highScore: Int = 0
    var cumulativeScore: Int = 0
    var totalPuppiesRescued: Int = 0
    var totalBigMacsMatched: Int = 0
    var totalTeidoSurgesTriggered: Int = 0
    var totalFiestaBombsCreated: Int = 0
    var bestCascadeCombo: Int = 0
    var totalSnoreBubblesPopped: Int = 0
    var highestTierReached: Int = 1

    var soundEffectsEnabled: Bool = true
    var goofySnoreSoundsEnabled: Bool = true
    var screenShakeEnabled: Bool = true
    var selectedBackdrop: BackdropTheme = .cozyDefault
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
        switch milestone {
        case .korvDash: return data.cumulativeScore >= 10_000
        case .bigMacRun: return data.totalBigMacsMatched >= 100
        case .padThaiPS5Night: return data.totalTeidoSurgesTriggered >= 10
        case .tacoTuesday: return data.totalFiestaBombsCreated >= 15
        case .pokeDate: return data.bestCascadeCombo >= 5
        case .firstPuppyAdopted: return data.totalPuppiesRescued >= 1
        case .packLeader: return data.totalPuppiesRescued >= 25
        case .survivedSnoring: return data.totalSnoreBubblesPopped >= 50
        }
    }

    func progressPercent(for milestone: ScrapbookMilestone) -> Int {
        let ratio: Double
        switch milestone {
        case .korvDash: ratio = Double(data.cumulativeScore) / 10_000.0
        case .bigMacRun: ratio = Double(data.totalBigMacsMatched) / 100.0
        case .padThaiPS5Night: ratio = Double(data.totalTeidoSurgesTriggered) / 10.0
        case .tacoTuesday: ratio = Double(data.totalFiestaBombsCreated) / 15.0
        case .pokeDate: ratio = Double(data.bestCascadeCombo) / 5.0
        case .firstPuppyAdopted: ratio = Double(data.totalPuppiesRescued) / 1.0
        case .packLeader: ratio = Double(data.totalPuppiesRescued) / 25.0
        case .survivedSnoring: ratio = Double(data.totalSnoreBubblesPopped) / 50.0
        }
        return Int(min(100.0, max(0.0, ratio * 100.0)).rounded())
    }

    var unlockedCount: Int {
        ScrapbookMilestone.allCases.filter { isUnlocked($0) }.count
    }

    var cosmetics: BoardCosmetics {
        BoardCosmetics(
            biltemaTrimUnlocked: isUnlocked(.korvDash),
            goldenSesameBorderUnlocked: isUnlocked(.bigMacRun),
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
        }
    }

    func recordProgress(from previous: RunStats, to current: RunStats) {
        guard previous.movesMade != current.movesMade else { return }
        data.highScore = max(data.highScore, current.score)
        data.cumulativeScore += min(current.score - previous.score, Int.max - data.cumulativeScore)
        data.totalPuppiesRescued += current.puppiesRescued - previous.puppiesRescued
        data.totalBigMacsMatched += current.bigMacsMatched - previous.bigMacsMatched
        data.totalTeidoSurgesTriggered += current.teidoSurgesTriggered - previous.teidoSurgesTriggered
        data.totalFiestaBombsCreated += current.fiestaBombsCreated - previous.fiestaBombsCreated
        data.bestCascadeCombo = max(data.bestCascadeCombo, current.maxCascadeReached)
        data.totalSnoreBubblesPopped += current.snoreBubblesPopped - previous.snoreBubblesPopped
        data.highestTierReached = max(data.highestTierReached, current.tier)
        save()
    }
}
