import Engine
import JavaScriptKit

/// SwiftWasm entry point: wires Engine, HiDPI CanvasRenderer, InputHandler,
/// WebAudioManager, StorageManager, DOMController, and the 120Hz requestAnimationFrame loop.
@main
struct MunchiesWebMain {
    nonisolated(unsafe) static var controller: MunchiesAppController?

    static func main() {
        let app = MunchiesAppController()
        controller = app
        app.start()
    }
}

final class MunchiesAppController {
    private let storage = StorageManager()
    private let audio = WebAudioManager()
    private let dom = DOMController()
    private let eventStrip = GameEventStrip()
    private var resolver: CascadeResolver
    private var renderer: CanvasRenderer!
    private var input: InputHandler!

    private var activeCombo: Int = 1
    private var cupcakeState: String = "idle"
    private var teidoState: String = "gaming"
    private var cupcakeCheerTime: Double = 0
    private var teidoCheerTime: Double = 0
    private var isPlaying = false
    private var isSettingsOpen = false
    private var isSnackRunVisible = false

    private var isPausedForVisibility: Bool = false
    private var lastFrameMs: Double = 0
    private var idleSeconds: Double = 0
    private var rafClosure: JSClosure?
    private var resizeClosure: JSClosure?
    private var resizeObserver: JSObject?
    private var visibilityClosure: JSClosure?
    private var audioUnlockClosure: JSClosure?

    init() {
        let seed = UInt64.random(in: 1...UInt64.max)
        self.resolver = CascadeResolver(seed: seed)
    }

    func start() {
        let document = JSObject.global.document.object!
        guard let canvas = document.getElementById?("board-canvas").object else { return }

        audio.soundEffectsEnabled = storage.data.soundEffectsEnabled
        audio.goofySnoreSoundsEnabled = storage.data.goofySnoreSoundsEnabled

        renderer = CanvasRenderer(canvas: canvas)
        renderer.cosmetics = storage.cosmetics
        renderer.screenShakeEnabled = storage.data.screenShakeEnabled
        renderer.syncFullBoard(resolver.board)

        input = InputHandler(
            canvas: canvas,
            renderer: renderer,
            onFirstGesture: { [weak self] in
                self?.idleSeconds = 0
            },
            onSwapRequested: { [weak self] from, to in
                self?.handleSwap(from: from, to: to)
            }
        )

        dom.wireEvents()
        eventStrip.wireEvents()
        dom.applyBackdrop(storage.data.selectedBackdrop)
        dom.syncSettingsUI(from: storage.data)
        dom.updateHomeStats(storage: storage)
        dom.renderScrapbook(storage: storage)
        dom.showScreen("home")

        dom.onPlayTapped = { [weak self] in
            self?.startNewRun()
        }
        dom.onHomeTapped = { [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.syncMusicPlayback()
            self.renderer.cancelPlayback()
            self.input.reset()
            self.eventStrip.reset()
            self.syncSnackRun()
            self.dom.updateHomeStats(storage: self.storage)
            self.dom.renderScrapbook(storage: self.storage)
            self.dom.showScreen("home")
        }
        dom.onRestartTapped = { [weak self] in
            self?.startNewRun()
        }
        dom.onShuffleTapped = { [weak self] in
            self?.handleManualShuffle()
        }
        dom.onSnackRunSelected = { [weak self] kind in
            guard let self, self.canPlayTurn, self.resolver.acceptSnackRun(kind) else { return }
            self.input.reset()
            self.idleSeconds = 0
            self.syncSnackRun()
            self.renderer.render()
        }
        dom.onSnackRunSkipped = { [weak self] in
            guard let self, self.canPlayTurn else { return }
            self.resolver.skipSnackRun()
            self.syncSnackRun()
            self.renderer.render()
        }
        dom.onPauseChanged = { [weak self] paused in
            guard let self else { return }
            self.isSettingsOpen = paused
            self.lastFrameMs = 0
            self.input.reset()
            self.syncEventStripSuspension()
            self.syncMusicPlayback()
        }
        dom.onSettingsChanged = { [weak self] sfx, music, snore, shake in
            guard let self else { return }
            self.storage.data.soundEffectsEnabled = sfx
            self.storage.data.backgroundMusicEnabled = music
            self.storage.data.goofySnoreSoundsEnabled = snore
            self.storage.data.screenShakeEnabled = shake
            self.storage.save()
            self.audio.soundEffectsEnabled = sfx
            self.audio.goofySnoreSoundsEnabled = snore
            self.renderer.screenShakeEnabled = shake
            self.syncMusicPlayback()
        }
        dom.onThemeSelected = { [weak self] theme in
            guard let self else { return }
            self.storage.data.selectedBackdrop = theme
            self.storage.save()
            self.dom.applyBackdrop(theme)
            self.dom.renderScrapbook(storage: self.storage)
        }

        attachWindowLifecycle()
        startAnimationLoop()
    }

    private func startNewRun() {
        isPlaying = true
        isSettingsOpen = false
        lastFrameMs = 0
        activeCombo = 1
        cupcakeState = "idle"
        teidoState = "gaming"
        cupcakeCheerTime = 0
        teidoCheerTime = 0
        idleSeconds = 0
        eventStrip.reset()
        dom.showScreen("game")
        input.reset()
        renderer.cancelPlayback()
        renderer.resize()
        resolver = CascadeResolver(seed: UInt64.random(in: 1...UInt64.max))
        renderer.cosmetics = storage.cosmetics
        renderer.syncFullBoard(resolver.board)
        syncSnackRun()
        renderer.render()
        refreshHUD()
        audio.unlockIfNeeded()
        syncMusicPlayback()
    }

    private var canPlayTurn: Bool {
        isPlaying && !isSettingsOpen && !isPausedForVisibility && !resolver.isGameOver && !renderer.isAnimating
    }

    private func handleSwap(from: GridPos, to: GridPos) {
        guard canPlayTurn else { return }
        idleSeconds = 0
        activeCombo = 1
        let previous = resolver.stats
        let steps = resolver.performSwap(from: from, to: to)
        storage.recordProgress(from: previous, to: resolver.stats, steps: steps)
        play(steps)
    }

    private func handleManualShuffle() {
        guard canPlayTurn else { return }
        input.reset()
        play(resolver.triggerEmergencyShuffle())
    }

    private func play(_ steps: [BoardStep]) {
        guard !steps.isEmpty else { return }
        if isSnackRunVisible { dom.setSnackRunControlsEnabled(false) }
        renderer.playSteps(
            steps,
            finalBoard: resolver.board,
            onStep: { [weak self] step in self?.handleStepCue(step) },
            onComplete: { [weak self] in self?.finishPlayback() }
        )
    }

    private func finishPlayback() {
        eventStrip.finishTurn(tier: resolver.stats.tier, tierProgressFraction: resolver.tierProgressFraction)
        renderer.cosmetics = storage.cosmetics
        refreshIdleAvatars()
        refreshHUD()
        syncSnackRun()
        if let reason = resolver.gameOverReason {
            syncMusicPlayback()
            dom.showGameOver(reason: reason, stats: resolver.stats, highScore: storage.data.highScore)
        }
    }

    private func syncSnackRun() {
        let state = isPlaying ? resolver.snackRun : .idle
        dom.updateSnackRun(state)
        if case .active(let run) = state {
            renderer.setSnackRunReceipts(run.remainingReceipts)
        } else {
            renderer.setSnackRunReceipts([])
        }
        isSnackRunVisible = state != .idle
        syncEventStripSuspension()
    }

    private func syncEventStripSuspension() {
        eventStrip.setSuspended(isSettingsOpen || isPausedForVisibility || isSnackRunVisible)
    }

    private func syncMusicPlayback() {
        audio.setMusicPlaying(storage.data.musicEnabled && isPlaying && !isSettingsOpen
            && !isPausedForVisibility && !resolver.isGameOver)
    }

    private func handleStepCue(_ step: BoardStep) {
        eventStrip.record(step)
        switch step {
        case .swap(_, _, let reverted):
            reverted ? audio.playInvalidSwap() : audio.playSwap()

        case .matchCleared(_, let cascadeDepth, _, _):
            activeCombo = max(activeCombo, cascadeDepth)
            audio.playMatchPop(cascadeDepth: cascadeDepth)

        case .specialTriggered:
            audio.playSpecialBlast()

        case .snoreSpawned:
            audio.playSnoreSpawn()

        case .snorePopped:
            audio.playSnorePop()

        case .puppySpawned:
            audio.playPuppyYip()

        case .puppyRescued:
            audio.playPuppyRescue()
            cupcakeState = "cheerPuppy"
            cupcakeCheerTime = 0.9

        case .teidoComboAchievement:
            audio.playTeidoAchievement()
            teidoState = "levelClear"
            teidoCheerTime = 0.9

        case .tierUp(_, let surge, _, _, _, _):
            surge == .teido ? audio.playTeidoAchievement() : audio.playTierUp()

        case .snackRunCompleted:
            audio.playTierUp()

        case .boardShuffled:
            audio.playSwap()

        case .avatarReaction(let reaction):
            switch reaction {
            case .cupcakeCheerBigMac, .cupcakeCheerPuppy:
                cupcakeState = reaction == .cupcakeCheerBigMac ? "cheerBigMac" : "cheerPuppy"
                cupcakeCheerTime = 0.9
            case .cupcakeSnoreAlert:
                if cupcakeCheerTime == 0 { cupcakeState = "snoreAlert" }
            case .teidoNoddingOff:
                if teidoCheerTime == 0 { teidoState = "noddingOff" }
            case .teidoComboWakeUp, .teidoAchievementUnlocked:
                teidoState = "levelClear"
                teidoCheerTime = 0.9
            case .calm: refreshIdleAvatars()
            }

        default:
            break
        }
        refreshHUD()
    }

    private func refreshIdleAvatars() {
        if cupcakeCheerTime == 0 {
            cupcakeState = resolver.board.activeSnoreCount >= 5 ? "snoreAlert" : "idle"
        }
        if teidoCheerTime == 0 {
            teidoState = resolver.movesSinceLastSnore >= resolver.currentConfig.snoreSpawnCadence - 1 ? "noddingOff" : "gaming"
        }
    }

    private func tickAvatars(_ dt: Double) {
        let cupcakeExpired = cupcakeCheerTime > 0 && cupcakeCheerTime <= dt
        let teidoExpired = teidoCheerTime > 0 && teidoCheerTime <= dt
        cupcakeCheerTime = max(0, cupcakeCheerTime - dt)
        teidoCheerTime = max(0, teidoCheerTime - dt)
        if cupcakeExpired || teidoExpired {
            refreshIdleAvatars()
            refreshHUD()
        }
    }

    private func refreshHUD() {
        dom.updateHUD(
            resolver: resolver,
            highScore: storage.data.highScore,
            activeCombo: activeCombo,
            cupcakeState: cupcakeState,
            teidoState: teidoState,
            hasSleepingPuppy: storage.isUnlocked(.firstPuppyAdopted)
        )
    }

    private func attachWindowLifecycle() {
        let onResize = JSClosure { [weak self] _ -> JSValue in
            self?.renderer.resize()
            return .undefined
        }
        resizeClosure = onResize
        _ = JSObject.global.window.addEventListener("resize", onResize)
        if let parent = renderer.canvas.parentElement.object, let observer = JSObject.global.ResizeObserver.function?.new(onResize) {
            _ = observer.observe?(parent)
            resizeObserver = observer
        }

        let unlockAudio = JSClosure { [weak self] _ -> JSValue in
            self?.audio.unlockIfNeeded()
            return .undefined
        }
        audioUnlockClosure = unlockAudio
        _ = JSObject.global.window.addEventListener("pointerdown", unlockAudio, true)

        let onVis = JSClosure { [weak self] _ -> JSValue in
            guard let self else { return .undefined }
            let hidden = JSObject.global.document.hidden.boolean ?? false
            self.isPausedForVisibility = hidden
            self.syncEventStripSuspension()
            self.syncMusicPlayback()
            if !hidden {
                self.lastFrameMs = 0
            }
            return .undefined
        }
        visibilityClosure = onVis
        _ = JSObject.global.document.addEventListener("visibilitychange", onVis)
    }

    private func startAnimationLoop() {
        let frame = JSClosure { [weak self] args -> JSValue in
            guard let self else { return .undefined }
            let nowMs = args.first?.number ?? 0
            let stageSkipped = JSObject.global.window.__munchiesStageSkipped.boolean ?? false
            if self.isPlaying && !self.isSettingsOpen && !self.isPausedForVisibility && !stageSkipped {
                let dt = self.lastFrameMs == 0 ? 0.016 : (nowMs - self.lastFrameMs) / 1000.0
                self.lastFrameMs = nowMs
                self.renderer.tick(dt: dt)
                self.tickAvatars(min(0.05, max(0, dt)))

                if !self.renderer.isAnimating && !self.resolver.isGameOver {
                    self.idleSeconds += min(0.05, max(0, dt))
                    if self.idleSeconds >= 5.0 {
                        self.idleSeconds = 0
                        if let hint = MoveValidator.findBestHint(in: self.resolver.board) {
                            self.renderer.pulseHint(hint)
                        }
                    }
                }
            }
            if let raf = self.rafClosure {
                _ = JSObject.global.requestAnimationFrame?(raf)
            }
            return .undefined
        }
        rafClosure = frame
        _ = JSObject.global.requestAnimationFrame?(frame)
    }
}
