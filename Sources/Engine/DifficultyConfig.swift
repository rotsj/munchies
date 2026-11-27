#if os(WASI)
import WASILibc
#else
import Foundation
#endif

/// Alternating character spotlights active every 3rd Night Owl Tier.
public enum CravingSurge: String, Hashable, Codable, Sendable {
    case none
    case cupcake // Tiers 3, 9, 15...
    case teido   // Tiers 6, 12, 18...

    public static func forTier(_ tier: Int) -> CravingSurge {
        guard tier > 0 else { return .none }
        if tier % 6 == 3 { return .cupcake }
        if tier % 6 == 0 { return .teido }
        return .none
    }

    public var title: String? {
        switch self {
        case .none: return nil
        case .cupcake: return "Cupcake's Craving Surge!"
        case .teido: return "Teido's Craving Surge!"
        }
    }
}

/// Multi-layered difficulty configuration for a given Night Owl Tier.
public struct DifficultyConfig: Sendable, Equatable {
    public let tier: Int
    public let surge: CravingSurge
    public let snoreSpawnCadence: Int
    public let allowsDoubleZzz: Bool
    public let allowsDriftingSnore: Bool
    public let basePuppyPointInterval: Int
    public let maxSimultaneousPuppies: Int
    public let puppyBlastRadius: Int // 1 => 3x3, 2 => 5x5
    public let baseScoreMultiplier: Double
    public let tierTileTarget: Int

    public static let baseTierTarget: Double = 45.0
    public static let snoreLoseThreshold: Int = 12
    public static let maxEmergencyShuffles: Int = 2
    public static let startingEmergencyShuffles: Int = 1

    public static func forTier(_ tier: Int, spotlight: CravingSurge? = nil) -> DifficultyConfig {
        let safeTier = max(1, tier)
        let surge = spotlight ?? CravingSurge.forTier(safeTier)

        let snoreCadence: Int
        let basePuppyInterval: Int
        let baseMultiplier: Double

        switch safeTier {
        case 1...3:
            snoreCadence = 6
            basePuppyInterval = 12_000
            baseMultiplier = 1.0
        case 4...7:
            snoreCadence = 5
            basePuppyInterval = 20_000
            baseMultiplier = 1.5
        case 8...12:
            snoreCadence = 4
            basePuppyInterval = 30_000
            baseMultiplier = 2.0
        default:
            snoreCadence = 3
            basePuppyInterval = 40_000
            baseMultiplier = 2.0 + Double(safeTier - 12) * 0.25
        }

        // Cupcake's Craving Surge increases puppy spawn frequency by 30%.
        let effectivePuppyInterval: Int
        if surge == .cupcake {
            effectivePuppyInterval = Int((Double(basePuppyInterval) / 1.30).rounded())
        } else {
            effectivePuppyInterval = basePuppyInterval
        }

        let scaledTarget = (baseTierTarget * pow(1.18, Double(safeTier - 1))).rounded()
        let target = scaledTarget < Double(Int.max) ? Int(scaledTarget) : Int.max

        return DifficultyConfig(
            tier: safeTier,
            surge: surge,
            snoreSpawnCadence: snoreCadence,
            allowsDoubleZzz: safeTier >= 4,
            allowsDriftingSnore: safeTier >= 8,
            basePuppyPointInterval: effectivePuppyInterval,
            maxSimultaneousPuppies: safeTier >= 8 ? 2 : 1,
            puppyBlastRadius: safeTier >= 13 ? 2 : 1,
            baseScoreMultiplier: baseMultiplier,
            tierTileTarget: max(15, target)
        )
    }

    public static func tierUpBanner(forTier tier: Int) -> String {
        switch CravingSurge.forTier(tier) {
        case .cupcake:
            return "Cupcake's Big Mac & Puppy Surge!"
        case .teido:
            return "Teido's Pad Thai & PS5 Surge!"
        case .none:
            let banners = [
                "Afternoon Biltema Run!",
                "Pre-17:00 Korv Dash!",
                "Hermanos Taco Feast!",
                "Partille Poke Craving!",
                "Midnight Snack Attack!"
            ]
            return banners[(max(1, tier) - 1) % banners.count]
        }
    }
}
