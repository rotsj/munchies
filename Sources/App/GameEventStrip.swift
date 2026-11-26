import Engine
import JavaScriptKit

private struct GameEvent {
    enum Art: String {
        case puppy, rescue, biltema, snore, cleared, cupcake, teido, taco, poke, shuffle, rocket, burst, swirl, padThai, snack
        case schedule, gemini, couch
    }

    let title: String
    let detail: String
    let art: Art

    static let schedule = GameEvent(title: "Cupcake's 60% Rule", detail: "60% work · 60% study", art: .schedule)
    static let gemini = GameEvent(title: "Gemini Mode", detail: "Cupcake + Big Mac in one turn.", art: .gemini)

    static func couchCombo(depth: Int) -> GameEvent {
        GameEvent(title: "PS5 Couch Mode", detail: "\(depth)× cascade. Controller on!", art: .couch)
    }

    static func from(_ step: BoardStep) -> GameEvent? {
        switch step {
        case .puppySpawned:
            return GameEvent(title: "Stray puppy spotted", detail: "Clear snacks below it to guide it home.", art: .puppy)
        case .puppyRescued(_, _, let points):
            return GameEvent(title: "Puppy rescued!", detail: "+\(points) points", art: .rescue)
        case .snoreSpawned(_, let bubble):
            var detail = bubble.isDoubleZzz ? "Takes two nearby matches." : "Match beside it to pop it."
            if bubble.isDrifting { detail += " Rises every 3 turns." }
            return GameEvent(title: bubble.isDrifting ? "Drifting snore" : "Teido nodded off", detail: detail, art: .snore)
        case .cupcakePacifierWave:
            return GameEvent(title: "Cupcake calmed Teido", detail: "The oldest snore bubble popped.", art: .cupcake)
        case .tierUp(let tier, let surge, let banner, _, _, let earnedShuffle):
            let detail = "Tier \(tier)" + (earnedShuffle ? " · +1 shuffle" : "")
            return GameEvent(title: banner, detail: detail, art: tierArt(surge: surge, banner: banner))
        case .teidoComboAchievement:
            return GameEvent(title: "Combo achievement!", detail: "Teido added a Korv Rocket.", art: .teido)
        case .boardShuffled(_, let usedEmergency):
            return GameEvent(title: "Korv Shuffle", detail: usedEmergency ? "Used an emergency shuffle." : "New moves opened up.", art: .shuffle)
        case .snackRunCompleted(let kind, _, _):
            return GameEvent(title: "\(kind.title) complete!", detail: "\(kind.rewardName) added to the board.",
                             art: kind == .biltemaDash ? .biltema : .poke)
        case .snackRunExpired(let kind):
            return GameEvent(title: "\(kind.title) expired", detail: "Six swaps used.",
                             art: kind == .biltemaDash ? .biltema : .poke)
        case .specialCreated(_, let tile):
            switch tile.special {
            case .korvRocket:
                return GameEvent(title: "Korv Rocket", detail: "Match it to clear its marked line.", art: .rocket)
            case .fiestaBomb:
                return GameEvent(title: "Fiesta Bomb", detail: "Match it to clear a 3 × 3 area.", art: .burst)
            case .goldenSwirl:
                return GameEvent(title: "Golden Soft-Ice Swirl", detail: "Swap with a snack to clear its type.", art: .swirl)
            case .none:
                return nil
            }
        case .specialTriggered(.padThaiCross, _, _, _):
            return GameEvent(title: "Pad Thai Feast", detail: "A cross of snacks cleared.", art: .padThai)
        default:
            return nil
        }
    }

    private static func tierArt(surge: CravingSurge, banner: String) -> Art {
        switch surge {
        case .cupcake: return .cupcake
        case .teido: return .couch
        case .none:
            switch banner {
            case "Afternoon Biltema Run!", "Pre-17:00 Korv Dash!": return .biltema
            case "Hermanos Taco Feast!": return .taco
            case "Partille Poke Craving!": return .poke
            default: return .snack
            }
        }
    }
}

/// Stores recent run events and keeps each automatic card in view long enough to read.
final class GameEventStrip {
    private let document = JSObject.global.document.object!
    private lazy var viewport = document.getElementById?("event-viewport").object
    private lazy var history = document.getElementById?("event-history").object
    private lazy var empty = document.getElementById?("event-empty").object
    private lazy var latest = document.getElementById?("event-latest").object
    private lazy var status = document.getElementById?("event-status").object
    private var pendingResultCard: JSObject?
    private var handlers: [JSClosure] = []
    private var currentCard: JSObject?
    private var timer: Double?
    private var following = true
    private var suspended = false
    private var poppedSnores = 0
    private var announcedSpecials: Set<GameEvent.Art> = []
    private var matchedSnacks: Set<StandardTileKind> = []
    private var announcedRunEvents: Set<GameEvent.Art> = []

    private lazy var advance = JSClosure { [weak self] _ -> JSValue in
        guard let self else { return .undefined }
        self.timer = nil
        self.showNext()
        return .undefined
    }

    func wireEvents() {
        let inspect = JSClosure { [weak self] _ -> JSValue in
            self?.pauseFollowing()
            return .undefined
        }
        let keys = JSClosure { [weak self] args -> JSValue in
            if let key = args.first?.object?.key.string, ["ArrowLeft", "ArrowRight", "Home", "End"].contains(key) {
                self?.pauseFollowing()
            }
            return .undefined
        }
        let follow = JSClosure { [weak self] _ -> JSValue in
            self?.resumeFollowing()
            return .undefined
        }
        handlers = [inspect, keys, follow]
        _ = viewport?.addEventListener?("pointerdown", inspect)
        _ = viewport?.addEventListener?("wheel", inspect)
        _ = viewport?.addEventListener?("keydown", keys)
        _ = latest?.addEventListener?("click", follow)
    }

    func reset() {
        clearTimer()
        currentCard = nil
        pendingResultCard = nil
        following = true
        suspended = false
        poppedSnores = 0
        announcedSpecials.removeAll()
        matchedSnacks.removeAll()
        announcedRunEvents.removeAll()
        history?.textContent = .string("")
        status?.textContent = .string("")
        viewport?.scrollLeft = .number(0)
        empty?.hidden = .boolean(false)
        latest?.hidden = .boolean(true)
    }

    func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value
        clearTimer()
        if !value && following {
            if let card = pendingResultCard {
                pendingResultCard = nil
                show(card)
            } else if currentCard == nil {
                showNext()
            } else {
                startDwell()
            }
        }
    }

    func record(_ step: BoardStep) {
        switch step {
        case .snorePopped:
            poppedSnores += 1
        case .matchCleared(_, _, _, let kinds):
            matchedSnacks.formUnion(kinds)
        case .avatarReaction(.teidoComboWakeUp(let depth)):
            appendOncePerRun(.couchCombo(depth: depth))
        case .snackRunCompleted, .snackRunExpired:
            if let event = GameEvent.from(step) { append(event, prioritize: true) }
        default:
            guard let event = GameEvent.from(step) else { return }
            if case .specialCreated = step, !announcedSpecials.insert(event.art).inserted { return }
            append(event)
        }
    }

    func finishTurn(tier: Int, tierProgressFraction: Double) {
        if tier > 1 || tierProgressFraction >= 0.60 { appendOncePerRun(.schedule) }
        if matchedSnacks.contains(.cupcake) && matchedSnacks.contains(.bigMac) { appendOncePerRun(.gemini) }
        matchedSnacks.removeAll()
        announcedSpecials.removeAll()
        guard poppedSnores > 0 else { return }
        let title = poppedSnores == 1 ? "Snore bubble popped" : "\(poppedSnores) snore bubbles popped"
        poppedSnores = 0
        append(GameEvent(title: title, detail: "The locked snacks are free.", art: .cleared))
    }

    private func appendOncePerRun(_ event: GameEvent) {
        if announcedRunEvents.insert(event.art).inserted { append(event) }
    }

    private func append(_ event: GameEvent, prioritize: Bool = false) {
        guard let history else { return }
        let card = element("li", className: "event-card")
        card.dataset.art = .string(event.art.rawValue)
        card.dataset.announcement = .string("\(event.title). \(event.detail)")
        let copy = element("div", className: "event-copy")
        _ = copy.appendChild?(element("strong", className: "event-title", text: event.title))
        _ = copy.appendChild?(element("span", className: "event-detail", text: event.detail))

        let art = element("span", className: "event-art")
        _ = art.setAttribute?("aria-hidden", "true")
        let travel = element("span", className: "event-travel")
        _ = travel.appendChild?(element("span", className: "event-sprite"))
        _ = art.appendChild?(travel)
        _ = card.appendChild?(copy)
        _ = card.appendChild?(art)
        _ = history.appendChild?(card)
        empty?.hidden = .boolean(true)

        if (history.childElementCount.number ?? 0) > 32, let first = history.firstElementChild.object {
            let offset = (viewport?.scrollLeft.number ?? 0) - (first.offsetWidth.number ?? 0)
            if first.classList.contains("is-current").boolean == true {
                currentCard = nil
                clearTimer()
            }
            _ = first.remove?()
            viewport?.scrollLeft = .number(max(0, offset))
        }
        if prioritize && following {
            if suspended { pendingResultCard = card }
            else { show(card) }
        } else if timer == nil {
            showNext()
        }
        updateLatestButton()
    }

    private func element(_ tag: String, className: String, text: String? = nil) -> JSObject {
        let node = document.createElement!(tag).object!
        node.className = .string(className)
        if let text { node.textContent = .string(text) }
        return node
    }

    private func showNext() {
        guard following, !suspended else { return }
        let next = currentCard == nil ? history?.firstElementChild.object : currentCard?.nextElementSibling.object
        if let next { show(next) }
    }

    private func show(_ card: JSObject) {
        _ = currentCard?.classList.remove("is-current")
        currentCard = card
        _ = card.classList.add("is-current")
        status?.textContent = card.dataset.announcement

        let offset = card.offsetLeft.number ?? 0
        let reduceMotion = JSObject.global.matchMedia?("(prefers-reduced-motion: reduce)").matches.boolean == true
        if reduceMotion || offset == 0 {
            viewport?.scrollLeft = .number(offset)
        } else if let options = JSObject.global.Object.function?.new() {
            options.left = .number(offset)
            options.behavior = .string("smooth")
            _ = viewport?.scrollTo?(options)
        }
        startDwell()
        updateLatestButton()
    }

    private func pauseFollowing() {
        guard history?.firstElementChild.object != nil, following else { return }
        following = false
        clearTimer()
        updateLatestButton()
    }

    private func resumeFollowing() {
        guard let card = history?.lastElementChild.object else { return }
        following = true
        _ = viewport?.focus?()
        show(card)
    }

    private func updateLatestButton() {
        let hasQueuedCards = currentCard?.nextElementSibling.object != nil
        latest?.hidden = .boolean(following && !hasQueuedCards)
    }

    private func startDwell() {
        clearTimer()
        timer = JSObject.global.setTimeout?(advance, 3_000).number
    }

    private func clearTimer() {
        if let timer { _ = JSObject.global.clearTimeout?(timer) }
        timer = nil
    }
}
