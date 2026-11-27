import Engine
import JavaScriptKit

private struct RunMoment {
    enum Art: String {
        case puppy, rescue, snore, biltema, cupcake, teido, taco, poke, snack, schedule, gemini, couch
    }

    let title: String
    let detail: String
    let art: Art
    var resultCaption: String?

    var priority: Int {
        switch art {
        case .rescue: 5
        case .puppy: 4
        case .biltema, .taco, .poke, .cupcake, .couch: 3
        case .snore: 2
        default: 1
        }
    }

    static let schedule = Self(title: "Cupcake's 60% Rule", detail: "60% work · 60% study", art: .schedule)
    static let gemini = Self(title: "Gemini Mode", detail: "Cupcake + Big Mac in one turn.", art: .gemini)

    static func from(_ step: BoardStep) -> Self? {
        switch step {
        case .puppySpawned:
            Self(title: "Stray puppy spotted", detail: "Guide it to the bottom row.", art: .puppy)
        case .puppyRescued(_, _, let points):
            Self(title: "Puppy rescued!", detail: "+\(points) points", art: .rescue)
        case .snoreSpawned(_, let bubble):
            Self(title: "Teido nodded off", detail: bubble.isDoubleZzz ? "The bubble takes two hits." : "Match beside a snore bubble to pop it.", art: .snore)
        case .tierUp(let tier, let surge, let banner, _, _, let earnedShuffle):
            Self(title: banner, detail: "Tier \(tier)" + (earnedShuffle ? " · +1 shuffle" : ""),
                 art: tierArt(surge, banner: banner))
        case .teidoComboAchievement:
            Self(title: "Combo achievement!", detail: "Teido added a Korv Rocket.", art: .teido)
        case .snackRunCompleted(let kind, _, _):
            Self(title: "\(kind.title) complete!", detail: "\(kind.rewardName) added to the board.",
                 art: kind == .biltemaDash ? .biltema : .poke, resultCaption: "\(kind.rewardName) earned")
        case .snackRunExpired(let kind):
            Self(title: "\(kind.title) expired", detail: "Six swaps used.",
                 art: kind == .biltemaDash ? .biltema : .poke, resultCaption: "Six swaps used")
        default:
            nil
        }
    }

    private static func tierArt(_ surge: CravingSurge, banner: String) -> Art {
        switch surge {
        case .cupcake: .cupcake
        case .teido: .couch
        case .none:
            switch banner {
            case "Afternoon Biltema Run!", "Pre-17:00 Korv Dash!": .biltema
            case "Hermanos Taco Feast!": .taco
            case "Partille Poke Craving!": .poke
            default: .snack
            }
        }
    }
}

/// Pins one moment at a time. The journal keeps the other highlights in reading order.
final class RunJournal {
    private let document = JSObject.global.document.object!
    private lazy var pinned = document.getElementById?("run-moment").object
    private lazy var journal = document.getElementById?("run-journal").object
    private lazy var empty = document.getElementById?("journal-empty").object
    private var moments: [RunMoment] = []
    private var oncePerRun: Set<RunMoment.Art> = []
    private var snacks: Set<StandardTileKind> = []
    private var lastMomentSwap: Int?

    func reset() {
        moments.removeAll()
        oncePerRun.removeAll()
        snacks.removeAll()
        lastMomentSwap = nil
        pinned?.textContent = .string("")
        journal?.textContent = .string("")
        empty?.hidden = .boolean(false)
    }

    func record(_ step: BoardStep) {
        switch step {
        case .matchCleared(_, _, _, let kinds):
            snacks.formUnion(kinds)
        case .avatarReaction(.teidoComboWakeUp(let depth)):
            recordOnce(RunMoment(title: "PS5 Couch Mode", detail: "\(depth)× cascade. Controller on!", art: .couch))
        case .snoreSpawned, .teidoComboAchievement:
            if let moment = RunMoment.from(step) { recordOnce(moment) }
        default:
            if let moment = RunMoment.from(step) { moments.append(moment) }
        }
    }

    func finishTurn(stats: RunStats, tierProgressFraction: Double) {
        if stats.tier > 1 || tierProgressFraction >= 0.60 { recordOnce(.schedule) }
        if snacks.contains(.cupcake) && snacks.contains(.bigMac) { recordOnce(.gemini) }
        snacks.removeAll()
        if moments.isEmpty { return }
        for moment in moments {
            _ = journal?.prepend?(makeCard(moment, tag: "li"))
            if (journal?.childElementCount.number ?? 0) > 24 { _ = journal?.lastElementChild.object?.remove?() }
        }
        empty?.hidden = .boolean(true)

        let canPinStory = lastMomentSwap.map { stats.movesMade - $0 >= 6 } ?? true
        let chosen = moments.last { $0.resultCaption != nil }
            ?? (canPinStory ? moments.max { $0.priority < $1.priority } : nil)
        if let chosen {
            pinned?.textContent = .string("")
            _ = pinned?.appendChild?(makeCard(chosen, tag: "div", isPinned: true))
            lastMomentSwap = stats.movesMade
        }
        moments.removeAll()
    }

    private func recordOnce(_ moment: RunMoment) {
        if oncePerRun.insert(moment.art).inserted { moments.append(moment) }
    }

    private func makeCard(_ moment: RunMoment, tag: String, isPinned: Bool = false) -> JSObject {
        let card = element(tag, "event-card")
        card.dataset.art = .string(moment.art.rawValue)
        let copy = element("div", "event-copy")
        _ = copy.appendChild?(element("strong", "event-title", text: moment.title))
        if let detail = isPinned ? moment.resultCaption : moment.detail {
            _ = copy.appendChild?(element("span", "event-detail", text: detail))
        }
        let art = element("span", "event-art")
        _ = art.setAttribute?("aria-hidden", "true")
        let travel = element("span", "event-travel")
        _ = travel.appendChild?(element("span", "event-sprite"))
        _ = art.appendChild?(travel)
        _ = card.appendChild?(copy)
        _ = card.appendChild?(art)
        return card
    }

    private func element(_ tag: String, _ className: String, text: String? = nil) -> JSObject {
        let node = document.createElement!(tag).object!
        node.className = .string(className)
        if let text { node.textContent = .string(text) }
        return node
    }
}
