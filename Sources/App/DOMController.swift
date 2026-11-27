import Engine
import JavaScriptKit

/// Swift-driven DOM controller managing the Home Screen, reactive Cupcake & Teido HUD,
/// native `<dialog>` modals (Settings, Scrapbook, Game Over), and theme classes.
final class DOMController {
    private static let pausingDialogs = ["dialog-settings", "dialog-run-journal"]
    private let document = JSObject.global.document.object!
    private var closures: [JSClosure] = []

    var onPlayTapped: (() -> Void)?
    var onNextStageTapped: (() -> Void)?
    var onHomeTapped: (() -> Void)?
    var onRestartTapped: (() -> Void)?
    var onShuffleTapped: (() -> Void)?
    var onSettingsChanged: ((Bool, Bool, Bool, Bool) -> Void)?
    var onThemeSelected: ((BackdropTheme) -> Void)?
    var onPauseChanged: ((Bool) -> Void)?

    func wireEvents() {
        bindClick("btn-play") { [weak self] in self?.onPlayTapped?() }
        bindClick("btn-run-journal") { [weak self] in self?.openDialog("dialog-run-journal") }
        bindClick("btn-scrapbook") { [weak self] in self?.openDialog("dialog-scrapbook") }
        bindClick("btn-home-settings") { [weak self] in self?.openDialog("dialog-settings") }
        bindClick("btn-pause") { [weak self] in self?.openDialog("dialog-settings") }
        bindClick("btn-shuffle") { [weak self] in self?.onShuffleTapped?() }
        bindClick("btn-settings-restart") { [weak self] in
            self?.closeDialog("dialog-settings")
            self?.onRestartTapped?()
        }
        bindClick("btn-settings-home") { [weak self] in
            self?.closeDialog("dialog-settings")
            self?.onHomeTapped?()
        }
        bindClick("btn-stage-retry") { [weak self] in
            self?.closeDialog("dialog-stage-result")
            self?.onRestartTapped?()
        }
        bindClick("btn-stage-next") { [weak self] in
            self?.closeDialog("dialog-stage-result")
            self?.onNextStageTapped?()
        }
        bindClick("btn-stage-home") { [weak self] in
            self?.closeDialog("dialog-stage-result")
            self?.onHomeTapped?()
        }
        let keepResultOpen = JSClosure { args in
            _ = args.first?.object?.preventDefault?()
            return .undefined
        }
        closures.append(keepResultOpen)
        _ = byId("dialog-stage-result")?.addEventListener?("cancel", keepResultOpen)

        for id in ["toggle-sfx", "toggle-music", "toggle-snore", "toggle-shake"] {
            if let el = byId(id) {
                let c = JSClosure { [weak self] _ -> JSValue in
                    self?.emitSettingsChange()
                    return .undefined
                }
                closures.append(c)
                _ = el.addEventListener?("change", c)
            }
        }
        for id in Self.pausingDialogs {
            guard let dialog = byId(id) else { continue }
            let onClose = JSClosure { [weak self] _ -> JSValue in
                self?.notifyPauseState()
                return .undefined
            }
            closures.append(onClose)
            _ = dialog.addEventListener?("close", onClose)
        }
    }

    func showScreen(_ screen: String) {
        if let home = byId("screen-home"), let game = byId("screen-game") {
            let isGame = (screen == "game")
            home.hidden = .boolean(isGame)
            game.hidden = .boolean(!isGame)
            if let inGameControls = byId("settings-ingame-actions") {
                inGameControls.hidden = .boolean(!isGame)
            }
            byId("settings-updates")?.hidden = .boolean(isGame)
        }
    }

    func applyBackdrop(_ theme: BackdropTheme) {
        if let body = document.body.object {
            body.dataset.theme = .string(theme.rawValue)
        }
    }

    func syncSettingsUI(from data: PersistedProgress) {
        if let el = byId("toggle-sfx") { el.checked = .boolean(data.soundEffectsEnabled) }
        if let el = byId("toggle-music") { el.checked = .boolean(data.musicEnabled) }
        if let el = byId("toggle-snore") { el.checked = .boolean(data.goofySnoreSoundsEnabled) }
        if let el = byId("toggle-shake") { el.checked = .boolean(data.screenShakeEnabled) }
    }

    func updateHomeStats(storage: StorageManager) {
        setText("home-highscore", "\(storage.data.highScore)")
        setText("home-puppies", "\(storage.data.totalPuppiesRescued)")
        setText("home-craving", "Craving \(storage.data.nextCraving)")
        let tiersEarned = storage.tiersEarned
        setText("home-scrapbook-count", "\(tiersEarned) \(tiersEarned == 1 ? "tier" : "tiers")")
    }

    func updateStage(_ attempt: CravingAttempt) {
        let stage = attempt.definition
        setText("hud-tier", "CRAVING \(stage.number)")
        let chapterName = stage.chapterTheme + (stage.isFinale ? " Finale" : "")
        let chapter = stage.encore > 0 ? "\(chapterName) · Encore \(stage.encore)" : chapterName
        setText("chapter-theme", chapter)
        _ = byId("chapter-theme")?.setAttribute?("title", chapter)
        setText("chapter-step", "\(stage.stageInChapter) / \(CravingStage.stagesPerChapter)")
        for index in 0..<CravingStage.stagesPerChapter {
            let slot = index + 1
            var state = slot < stage.stageInChapter ? "cleared" : "ahead"
            if slot == stage.stageInChapter { state = stage.isFinale ? "finale" : "current" }
            byId("chapter-pips")?.children.item(index).object?.dataset.state = .string(state)
        }

        updateStageBudget(attempt.movesRemaining)
        for index in 0..<2 {
            let id = "goal-\(index)"
            let row = byId(id)
            row?.hidden = .boolean(index >= attempt.objectives.count)
            guard index < attempt.objectives.count else { continue }
            let objective = attempt.objectives[index]
            let copy = goalCopy(objective.goal)
            setText("\(id)-title", copy.title)
            setText("\(id)-count", "\(objective.progress) / \(objective.goal.target)")
            if let art = byId("\(id)-art") {
                art.textContent = .string(copy.symbol)
                art.style.backgroundImage = .string(copy.icon.map { "url('./assets/\($0).svg')" } ?? "none")
            }
            _ = row?.toggleAttribute?("data-complete", objective.remaining == 0)
        }

        let tip: String?
        switch stage.spotlight {
        case .cupcake: tip = "Cupcake Spotlight · 2× favorites"
        case .teido: tip = "Teido Spotlight · 3× earns a rocket"
        case .none:
            tip = switch stage.goals.count == 1 ? stage.goals.first : nil {
            case .puppies: "Match below the puppy to guide it home"
            case .snores: "Match beside a bubble to pop it"
            default: nil
            }
        }
        byId("stage-tip")?.hidden = .boolean(tip == nil)
        if let tip { setText("stage-tip", tip) }
    }

    func updateStageBudget(_ remaining: Int) {
        setText("stage-swaps", "\(remaining) \(remaining == 1 ? "swap" : "swaps") left")
    }

    func showFinaleBonus(_ count: Int) {
        setText("stage-swaps", "Bonus ×\(count)")
    }

    private func goalCopy(_ goal: CravingGoal) -> (title: String, icon: String?, symbol: String) {
        switch goal {
        case .snacks(let kind, _):
            let title: String
            switch kind {
            case .cupcake: title = "Cupcakes"
            case .teido: title = "Teido tiles"
            case .hermanosTaco: title = "Hermanos Tacos"
            case .partillePoke: title = "Poke Bowls"
            case .biltemaCombo: title = "Biltema Combos"
            case .bigMac: title = "Big Macs"
            }
            return (title, "tile-\(kind.rawValue)", "")
        case .favorites: return ("Cupcakes + Big Macs", "tile-bigMac", "")
        case .puppies: return ("Puppies home", "tile-puppy", "")
        case .snores: return ("Snores popped", nil, "Zzz")
        case .specials(.rockets, _): return ("Rockets fired", "event-rocket", "")
        case .specials(.bombs, _): return ("Fiesta Bombs fired", nil, "✦")
        case .specials(.combinations, _): return ("Specials combined", nil, "↔✦")
        }
    }

    func updateHUD(
        resolver: CascadeResolver,
        highScore: Int,
        activeCombo: Int,
        cupcakeState: String,
        teidoState: String,
        lifetimePuppies: UInt64,
        hasSleepingPuppy: Bool
    ) {
        setText("hud-score", "\(resolver.stats.score)")
        setText("hud-best", "BEST \(max(resolver.stats.score, highScore))")
        let surge = resolver.currentConfig.surge

        let snoreCount = resolver.board.activeSnoreCount
        setText("hud-snore-count", "😴 Snore \(snoreCount)/\(DifficultyConfig.snoreLoseThreshold)")
        let snorePct = Int((resolver.snoreMeterProgress * 100.0).rounded())
        if let sbar = byId("hud-snore-bar") {
            sbar.style.width = .string("\(snorePct)%")
            sbar.dataset.danger = .string(snoreCount >= 8 ? "true" : "false")
        }

        setText("hud-combo", "\(activeCombo)x")
        setText("hud-puppies", "\(lifetimePuppies)")
        setText("hud-shuffles", "\(resolver.stats.availableShuffles)/\(DifficultyConfig.maxEmergencyShuffles)")

        if let shuffleBtn = byId("btn-shuffle") {
            shuffleBtn.disabled = .boolean(resolver.stats.availableShuffles == 0)
        }

        if let cup = byId("avatar-cupcake") {
            cup.dataset.state = .string(cupcakeState)
        }
        if let teido = byId("avatar-teido") {
            teido.dataset.state = .string(teidoState)
            teido.dataset.surge = .string(surge == .teido ? "active" : "")
        }
        if let puppyBadge = byId("cupcake-sleeping-puppy") {
            puppyBadge.hidden = .boolean(!hasSleepingPuppy)
        }
    }

    func renderScrapbook(storage: StorageManager) {
        setText("scrapbook-unlocked-count", "\(storage.tiersEarned)")
        setText("scrapbook-total-puppies", "\(storage.data.totalPuppiesRescued) 🐾")
        setText("scrapbook-trail-stars", "\(storage.data.cravingStars ?? 0)")

        if let themeRow = byId("scrapbook-themes") {
            themeRow.innerHTML = .string("")
            for theme in BackdropTheme.allCases {
                let unlocked = storage.isThemeUnlocked(theme)
                let selected = storage.data.selectedBackdrop == theme
                guard let btn = document.createElement?("button").object else { continue }
                btn.type = .string("button")
                btn.className = .string("theme-pill" + (selected ? " is-selected" : "") + (unlocked ? "" : " is-locked"))
                btn.disabled = .boolean(!unlocked)
                btn.textContent = .string((unlocked ? (selected ? "✓ " : "✨ ") : "🔒 ") + theme.displayName)
                if unlocked {
                    let c = JSClosure { [weak self] _ -> JSValue in
                        self?.onThemeSelected?(theme)
                        return .undefined
                    }
                    closures.append(c)
                    _ = btn.addEventListener?("click", c)
                }
                _ = themeRow.appendChild?(btn)
            }
        }

        if let grid = byId("scrapbook-grid") {
            grid.innerHTML = .string("")
            for m in ScrapbookMilestone.allCases {
                let progress = storage.progress(for: m)
                let unlocked = progress.tiersEarned > 0
                let tierLabel = "Tier \(progress.nextTier)"
                let amount = "\(progress.progress) / \(progress.goal) \(m.progressUnit)"
                guard let card = document.createElement?("article").object else { continue }
                card.className = .string("polaroid-card" + (unlocked ? " is-unlocked" : ""))
                if unlocked { card.dataset.tierAccent = .string(String((progress.tiersEarned - 1) % 3)) }

                if let photo = document.createElement?("div").object {
                    photo.className = .string("polaroid-photo")
                    if let icon = document.createElement?("span").object {
                        icon.textContent = .string(unlocked ? m.emoji : "🔒")
                        _ = icon.setAttribute?("aria-hidden", "true")
                        _ = photo.appendChild?(icon)
                    }
                    if unlocked, let tier = document.createElement?("span").object {
                        tier.className = .string("polaroid-tier")
                        tier.textContent = .string("Tier \(progress.tiersEarned)")
                        _ = photo.appendChild?(tier)
                    }
                    _ = card.appendChild?(photo)
                }

                if let title = document.createElement?("h2").object {
                    title.className = .string("polaroid-title")
                    title.textContent = .string(m.title)
                    _ = card.appendChild?(title)
                }

                if unlocked, let desc = document.createElement?("p").object {
                    desc.className = .string("polaroid-desc")
                    desc.textContent = .string("✨ \(m.rewardText)")
                    _ = card.appendChild?(desc)
                }

                if let next = document.createElement?("p").object {
                    next.className = .string("polaroid-next")
                    next.textContent = .string("\(tierLabel) · \(unlocked ? amount : m.requirementText)")
                    _ = card.appendChild?(next)
                }

                if let bar = document.createElement?("div").object,
                   let fill = document.createElement?("div").object {
                    bar.className = .string("polaroid-progress")
                    _ = bar.setAttribute?("role", "progressbar")
                    _ = bar.setAttribute?("aria-label", tierLabel)
                    _ = bar.setAttribute?("aria-valuenow", "\(progress.percent)")
                    _ = bar.setAttribute?("aria-valuetext", amount)
                    fill.className = .string("polaroid-progress-fill")
                    fill.style.width = .string("\(progress.percent)%")
                    _ = bar.appendChild?(fill)
                    _ = card.appendChild?(bar)
                }

                _ = grid.appendChild?(card)
            }
        }
    }

    func showStageResult(_ attempt: CravingAttempt, result: CravingStageResult) {
        let number = attempt.definition.number
        let won: Bool
        switch result {
        case .cleared(let stars, let bonus):
            won = true
            setText("stage-result-title", "Craving \(number) cleared!")
            setText("stage-result-stars", String(repeating: "★", count: stars) + String(repeating: "☆", count: 3 - stars))
            _ = byId("stage-result-stars")?.setAttribute?("aria-label", "\(stars) of 3 stars")
            setText("stage-result-detail", bonus > 0 ? "\(bonus) bonus \(bonus == 1 ? "power-up" : "power-ups")" : "Cleared on the final swap")
        case .outOfSwaps:
            won = false
            setText("stage-result-title", "Out of swaps")
            setText("stage-result-detail", "Craving \(number)")
        case .blocked(let reason):
            won = false
            setText("stage-result-title", reason == .snoreOverload ? "Light Sleeper Alert" : "Out of valid moves")
            setText("stage-result-detail", "Craving \(number)")
        }
        let summary = attempt.objectives.map {
            "\(goalCopy($0.goal).title) \($0.progress)/\($0.goal.target)"
        }.joined(separator: " · ")
        setText("stage-result-objectives", summary)
        byId("stage-result-stars")?.hidden = .boolean(!won)
        byId("btn-stage-next")?.hidden = .boolean(!won)
        byId("btn-stage-retry")?.hidden = .boolean(won)
        openDialog("dialog-stage-result")
    }

    func openDialog(_ id: String) {
        if let dlg = byId(id) {
            _ = dlg.showModal?()
            if Self.pausingDialogs.contains(id) { notifyPauseState() }
        }
    }

    func closeDialog(_ id: String) {
        if let dlg = byId(id) {
            _ = dlg.close?()
        }
    }

    private func notifyPauseState() {
        onPauseChanged?(Self.pausingDialogs.contains { byId($0)?.open.boolean == true })
    }

    private func emitSettingsChange() {
        let sfx = byId("toggle-sfx")?.checked.boolean ?? true
        let music = byId("toggle-music")?.checked.boolean ?? true
        let snore = byId("toggle-snore")?.checked.boolean ?? true
        let shake = byId("toggle-shake")?.checked.boolean ?? true
        onSettingsChanged?(sfx, music, snore, shake)
    }

    private func bindClick(_ id: String, handler: @escaping () -> Void) {
        guard let el = byId(id) else { return }
        let closure = JSClosure { _ -> JSValue in
            handler()
            return .undefined
        }
        closures.append(closure)
        _ = el.addEventListener?("click", closure)
    }

    private func byId(_ id: String) -> JSObject? {
        document.getElementById?(id).object
    }

    private func setText(_ id: String, _ text: String) {
        byId(id)?.textContent = .string(text)
    }
}
