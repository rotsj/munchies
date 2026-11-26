import Engine
import JavaScriptKit

/// Swift-driven DOM controller managing the Home Screen, reactive Cupcake & Teido HUD,
/// native `<dialog>` modals (Settings, Scrapbook, Game Over), and theme classes.
final class DOMController {
    private let document = JSObject.global.document.object!
    private var closures: [JSClosure] = []

    var onPlayTapped: (() -> Void)?
    var onHomeTapped: (() -> Void)?
    var onRestartTapped: (() -> Void)?
    var onShuffleTapped: (() -> Void)?
    var onSettingsChanged: ((Bool, Bool, Bool, Bool) -> Void)?
    var onThemeSelected: ((BackdropTheme) -> Void)?
    var onPauseChanged: ((Bool) -> Void)?

    func wireEvents() {
        bindClick("btn-play") { [weak self] in self?.onPlayTapped?() }
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
        bindClick("btn-gameover-replay") { [weak self] in
            self?.closeDialog("dialog-gameover")
            self?.onRestartTapped?()
        }
        bindClick("btn-gameover-home") { [weak self] in
            self?.closeDialog("dialog-gameover")
            self?.onHomeTapped?()
        }

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
        if let dialog = byId("dialog-settings") {
            let onClose = JSClosure { [weak self] _ -> JSValue in
                self?.onPauseChanged?(false)
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
        let tiersEarned = storage.tiersEarned
        setText("home-scrapbook-count", "\(tiersEarned) \(tiersEarned == 1 ? "tier" : "tiers")")
    }

    func updateHUD(
        resolver: CascadeResolver,
        highScore: Int,
        activeCombo: Int,
        cupcakeState: String,
        teidoState: String,
        hasSleepingPuppy: Bool
    ) {
        setText("hud-score", "\(resolver.stats.score)")
        setText("hud-best", "BEST \(max(resolver.stats.score, highScore))")
        setText("hud-tier", "TIER \(resolver.stats.tier)")

        let surge = resolver.currentConfig.surge
        let tierLabel: String
        switch surge {
        case .none: tierLabel = "🌙 Night Owl Tier"
        case .cupcake: tierLabel = "🧁 Cupcake Surge!"
        case .teido: tierLabel = "🎮 Teido Surge!"
        }
        setText("hud-tier-label", tierLabel)

        let tierPct = Int((resolver.tierProgressFraction * 100.0).rounded())
        setText("hud-tier-pct", "\(tierPct)%")
        if let bar = byId("hud-tier-bar") {
            bar.style.width = .string("\(tierPct)%")
        }

        let snoreCount = resolver.board.activeSnoreCount
        setText("hud-snore-count", "😴 Snore \(snoreCount)/\(DifficultyConfig.snoreLoseThreshold)")
        let snorePct = Int((resolver.snoreMeterProgress * 100.0).rounded())
        if let sbar = byId("hud-snore-bar") {
            sbar.style.width = .string("\(snorePct)%")
            sbar.dataset.danger = .string(snoreCount >= 8 ? "true" : "false")
        }

        setText("hud-combo", "\(activeCombo)x")
        setText("hud-puppies", "\(resolver.stats.puppiesRescued)")
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
        setText("scrapbook-best-tier", "T\(storage.data.highestTierReached)")

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

    func showGameOver(reason: GameOverReason, stats: RunStats, highScore: Int) {
        setText("gameover-icon", reason == .snoreOverload ? "😴💤" : "🌭🔄")
        setText("gameover-title", reason.headline)
        setText("gameover-score", "\(stats.score)")
        setText("gameover-tier", "Tier \(stats.tier)")
        setText("gameover-puppies", "\(stats.puppiesRescued) 🐾")
        setText("gameover-snores", "\(stats.snoreBubblesPopped)")
        setText("gameover-cascade", "\(stats.maxCascadeReached)x")
        if let badge = byId("gameover-record-badge") {
            badge.hidden = .boolean(!(stats.score > 0 && stats.score >= highScore))
        }
        openDialog("dialog-gameover")
    }

    func openDialog(_ id: String) {
        if let dlg = byId(id) {
            _ = dlg.showModal?()
            if id == "dialog-settings" { onPauseChanged?(true) }
        }
    }

    func closeDialog(_ id: String) {
        if let dlg = byId(id) {
            _ = dlg.close?()
        }
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
