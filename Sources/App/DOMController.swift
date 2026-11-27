import Engine
import JavaScriptKit

/// Swift-driven DOM controller managing the Home Screen, reactive Cupcake & Teido HUD,
/// native `<dialog>` modals (Settings, Scrapbook, Game Over), and theme classes.
final class DOMController {
    private static let pausingDialogs = ["dialog-settings", "dialog-run-journal"]
    private let document = JSObject.global.document.object!
    private var closures: [JSClosure] = []
    private var displayedSnackRun: SnackRunState = .idle

    var onPlayTapped: (() -> Void)?
    var onMissionsTapped: (() -> Void)?
    var onMissionSelected: ((MiniMission) -> Void)?
    var onMissionNextTapped: (() -> Void)?
    var onHomeTapped: (() -> Void)?
    var onRestartTapped: (() -> Void)?
    var onShuffleTapped: (() -> Void)?
    var onSnackRunSelected: ((SnackRunKind) -> Void)?
    var onSnackRunSkipped: (() -> Void)?
    var onSettingsChanged: ((Bool, Bool, Bool, Bool) -> Void)?
    var onThemeSelected: ((BackdropTheme) -> Void)?
    var onPauseChanged: ((Bool) -> Void)?

    func wireEvents() {
        bindClick("btn-play") { [weak self] in self?.onPlayTapped?() }
        bindClick("btn-missions") { [weak self] in self?.onMissionsTapped?() }
        bindClick("btn-run-journal") { [weak self] in self?.openDialog("dialog-run-journal") }
        bindClick("btn-scrapbook") { [weak self] in self?.openDialog("dialog-scrapbook") }
        bindClick("btn-home-settings") { [weak self] in self?.openDialog("dialog-settings") }
        bindClick("btn-pause") { [weak self] in self?.openDialog("dialog-settings") }
        bindClick("btn-shuffle") { [weak self] in self?.onShuffleTapped?() }
        bindClick("snack-run-dash") { [weak self] in self?.onSnackRunSelected?(.biltemaDash) }
        bindClick("snack-run-poke") { [weak self] in self?.onSnackRunSelected?(.pokeOrder) }
        bindClick("snack-run-skip") { [weak self] in self?.onSnackRunSkipped?() }
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
        wireMissions()

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

    private func wireMissions() {
        guard let list = byId("mission-list") else { return }
        for mission in MiniMission.allCases {
            let id = "mission-\(mission.rawValue)"
            let row = document.createElement!("li").object!
            let button = document.createElement!("button").object!
            button.id = .string(id)
            button.type = .string("button")
            button.className = .string("mission-choice")
            _ = button.setAttribute?("aria-labelledby", "\(id)-title")
            _ = button.setAttribute?("aria-describedby", "\(id)-status \(id)-detail")
            let title = document.createElement!("strong").object!
            title.id = .string("\(id)-title")
            title.textContent = .string(mission.title)
            let status = document.createElement!("span").object!
            status.id = .string("\(id)-status")
            status.className = .string("mission-choice-status")
            let detail = document.createElement!("span").object!
            detail.id = .string("\(id)-detail")
            detail.className = .string("mission-choice-detail")
            detail.textContent = .string(mission.instruction)
            _ = button.appendChild?(title)
            _ = button.appendChild?(status)
            _ = button.appendChild?(detail)
            _ = row.appendChild?(button)
            _ = list.appendChild?(row)
            bindClick(id) { [weak self] in
                self?.closeDialog("dialog-missions")
                self?.onMissionSelected?(mission)
            }
        }
        bindClick("btn-mission-next") { [weak self] in
            self?.closeDialog("dialog-mission-result")
            self?.onMissionNextTapped?()
        }
        bindClick("btn-mission-retry") { [weak self] in
            self?.closeDialog("dialog-mission-result")
            self?.onRestartTapped?()
        }
        bindClick("btn-mission-home") { [weak self] in
            self?.closeDialog("dialog-mission-result")
            self?.onHomeTapped?()
            self?.onMissionsTapped?()
        }
        let keepResultOpen = JSClosure { args in
            _ = args.first?.object?.preventDefault?()
            return .undefined
        }
        closures.append(keepResultOpen)
        _ = byId("dialog-mission-result")?.addEventListener?("cancel", keepResultOpen)
    }

    func showMissions(storage: StorageManager) {
        for mission in MiniMission.allCases {
            let id = "mission-\(mission.rawValue)"
            let unlocked = storage.isMissionUnlocked(mission)
            let cleared = storage.missionsCleared >= mission.rawValue
            byId(id)?.disabled = .boolean(!unlocked)
            setText("\(id)-status", cleared ? "Cleared" : (unlocked ? "\(mission.moveLimit) swaps" : "Locked"))
        }
        openDialog("dialog-missions")
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

    func updateSnackRun(_ state: SnackRunState) {
        setSnackRunControlsEnabled(true)
        guard state != displayedSnackRun else { return }
        displayedSnackRun = state
        let visible = state != .idle
        byId("snack-run-panel")?.hidden = .boolean(!visible)
        switch state {
        case .idle:
            break
        case .offered(let goals):
            byId("snack-run-choices")?.hidden = .boolean(false)
            byId("snack-run-progress")?.hidden = .boolean(true)
            byId("snack-run-dash")?.hidden = .boolean(!goals.contains { $0.kind == .biltemaDash })
            byId("snack-run-poke")?.hidden = .boolean(!goals.contains { $0.kind == .pokeOrder })
            for goal in goals {
                if case .pokeOrder(let ingredient) = goal {
                    setText("snack-run-poke-detail", "\(snackName(ingredient)) → Poke · Fiesta Bomb")
                }
            }
            setText("snack-run-skip", "Skip")
        case .active(let run):
            byId("snack-run-choices")?.hidden = .boolean(true)
            byId("snack-run-progress")?.hidden = .boolean(false)
            setText("snack-run-title", run.goal.kind.title)
            let remaining = run.movesRemaining
            setText("snack-run-moves", "\(remaining) \(remaining == 1 ? "swap" : "swaps") left")
            setText("snack-run-reward", "Earn a \(run.goal.kind.rewardName)")
            switch run.goal {
            case .biltemaDash:
                let count = run.remainingReceipts.count
                setText("snack-run-task", "Clear \(count) marked \(count == 1 ? "receipt" : "receipts")")
            case .pokeOrder(let ingredient):
                let first = snackName(ingredient)
                setText("snack-run-task", run.ingredientsMatched == 0 ? "Match \(first), then Poke" : "\(first) ✓ · Match Poke")
            }
            setText("snack-run-skip", "Leave")
        }
    }

    func updateMission(_ attempt: MissionAttempt?, showStory: Bool) {
        byId("screen-game")?.dataset.mode = .string(attempt == nil ? "endless" : "mission")
        byId("run-focus")?.hidden = .boolean(!showStory)
        byId("mission-panel")?.hidden = .boolean(attempt == nil)
        guard let attempt else { return }
        let remaining = attempt.movesRemaining
        setText("mission-title", attempt.definition.title)
        setText("mission-moves", "\(remaining) \(remaining == 1 ? "swap" : "swaps") left")
        if attempt.definition == .puppyPickup, attempt.puppiesHome > 0 {
            setText("mission-task", "\(attempt.puppiesHome)/2 puppies home")
        } else {
            setText("mission-task", attempt.definition.instruction)
        }
    }

    func setSnackRunControlsEnabled(_ enabled: Bool) {
        for id in ["snack-run-dash", "snack-run-poke", "snack-run-skip"] {
            byId(id)?.disabled = .boolean(!enabled)
        }
    }

    private func snackName(_ kind: StandardTileKind) -> String {
        switch kind {
        case .hermanosTaco: "Taco"
        case .biltemaCombo: "Biltema"
        default: kind.displayName
        }
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
        if let attempt = resolver.mission {
            setText("hud-tier", "MISSION \(attempt.definition.rawValue)")
        } else {
            setText("hud-tier", "TIER \(resolver.stats.tier)")
        }

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

    func showMissionResult(_ attempt: MissionAttempt, result: MissionResult) {
        let won = result == .cleared
        let next = won && attempt.definition.next != nil
        switch result {
        case .cleared:
            setText("mission-result-title", next ? "Mission cleared!" : "All missions cleared!")
            let used = attempt.definition.moveLimit - attempt.movesRemaining
            setText("mission-result-detail", "\(attempt.definition.title) in \(used) \(used == 1 ? "swap" : "swaps").")
        case .outOfSwaps, .noValidMoves:
            setText("mission-result-title", result == .outOfSwaps ? "Out of swaps" : "Out of valid moves")
            setText("mission-result-detail", attempt.definition.instruction)
        }
        byId("btn-mission-next")?.hidden = .boolean(!next)
        setText("btn-mission-retry", won ? "Replay mission" : "Retry mission")
        openDialog("dialog-mission-result")
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
