import Engine
import JavaScriptKit
import WASILibc

/// Cosmetics unlocked via the Couple's Milestone Scrapbook.
public struct BoardCosmetics: Equatable {
    public var biltemaTrimUnlocked: Bool = false
    public var goldenSesameBorderUnlocked: Bool = false
    public var puppyPawTrailUnlocked: Bool = false
}

struct VisualTile {
    var tile: Tile
    var pos: GridPos
    var x: Double
    var y: Double
    var targetX: Double
    var targetY: Double
    var scaleX: Double = 1.0
    var scaleY: Double = 1.0
    var scaleVelocityX: Double = 0
    var scaleVelocityY: Double = 0
    var alpha: Double = 1.0
    var selected: Bool = false
    var hintPulse: Double = 0.0
}

struct Particle {
    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
    var life: Double
    var maxLife: Double
    var size: Double
    var color: String
    var emoji: String?
}

struct BeamEffect {
    var x1: Double
    var y1: Double
    var x2: Double
    var y2: Double
    var color: String
    var life: Double
    var maxLife: Double
}

struct FloatingCallout {
    var text: String
    var x: Double
    var y: Double
    var color: String
    var fontSize: Double
    var life: Double
    var maxLife: Double
}

/// HiDPI 2D Canvas renderer for the 8x9 Munchies board running at 120Hz via requestAnimationFrame.
final class CanvasRenderer {
    let canvas: JSObject
    let ctx: JSObject

    var logicalWidth: Double = 360
    var logicalHeight: Double = 420
    var cellSize: Double = 42
    var boardOriginX: Double = 12
    var boardOriginY: Double = 12

    var cosmetics = BoardCosmetics()
    var screenShakeEnabled: Bool = true
    var isAnimating: Bool = false

    private var tiles: [Int: VisualTile] = [:]
    private var posToId: [GridPos: Int] = [:]
    private var particles: [Particle] = []
    private var beams: [BeamEffect] = []
    private var callouts: [FloatingCallout] = []
    private var spriteCache: [String: JSObject] = [:]
    private var spriteLoaders: [JSClosure] = []

    // Active step playback state
    private var stepQueue: [BoardStep] = []
    private var finalBoardSnapshot: BoardState?
    private var stepTimer: Double = 0
    private var stepDuration: Double = 0
    private var onStepEvent: ((BoardStep) -> Void)?
    private var onPlaybackComplete: (() -> Void)?

    // Screen shake & idle time
    private var shakeTimer: Double = 0
    private var shakeIntensity: Double = 0
    private var elapsedTime: Double = 0

    init(canvas: JSObject) {
        self.canvas = canvas
        self.ctx = canvas.getContext!("2d").object!
        preloadSVGSprites()
        resize()
    }

    private func preloadSVGSprites() {
        let names = [
            "cupcake", "teido", "hermanosTaco", "partillePoke",
            "biltemaCombo", "bigMac", "puppy", "padThai"
        ]
        let imageCtor = JSObject.global.Image.function!
        for name in names {
            let img = imageCtor.new()
            let loaded = JSClosure { [weak self] args -> JSValue in
                guard let source = args.first?.object?.target.object,
                      let bitmap = JSObject.global.document.createElement("canvas").object else { return .undefined }
                bitmap.width = 192
                bitmap.height = 192
                _ = bitmap.getContext?("2d").object?.drawImage?(source, 0, 0, 192, 192)
                self?.spriteCache[name] = bitmap
                return .undefined
            }
            spriteLoaders.append(loaded)
            img.onload = loaded.jsValue
            img.src = .string("./assets/tile-\(name).svg")
        }
    }

    func resize() {
        guard let parent = canvas.parentElement.object else { return }
        let rect = parent.getBoundingClientRect!()
        let width = rect.width.number ?? 0
        let height = rect.height.number ?? 0
        let dpr = JSObject.global.window.devicePixelRatio.number ?? 1
        guard width >= 28, height >= 29 else { return }
        guard width != logicalWidth || height != logicalHeight
                || canvas.width.number != floor(width * dpr) || canvas.height.number != floor(height * dpr) else { return }

        logicalWidth = width
        logicalHeight = height
        canvas.width = .number(floor(width * dpr))
        canvas.height = .number(floor(height * dpr))
        canvas.style.width = .string("\(width)px")
        canvas.style.height = .string("\(height)px")
        _ = ctx.setTransform?(dpr, 0, 0, dpr, 0, 0)

        let pad: Double = 10.0
        let maxW = (width - pad * 2) / Double(BoardState.cols)
        let maxH = (height - pad * 2) / Double(BoardState.rows)
        cellSize = floor(min(maxW, maxH))

        let totalW = cellSize * Double(BoardState.cols)
        let totalH = cellSize * Double(BoardState.rows)
        boardOriginX = floor((width - totalW) / 2.0)
        boardOriginY = floor((height - totalH) / 2.0)

        for (id, var vt) in tiles {
            let pt = centerPoint(for: vt.pos)
            vt.x = pt.0
            vt.y = pt.1
            vt.targetX = pt.0
            vt.targetY = pt.1
            tiles[id] = vt
        }
    }

    func syncFullBoard(_ board: BoardState) {
        tiles.removeAll()
        posToId.removeAll()
        for r in 0..<BoardState.rows {
            for c in 0..<BoardState.cols {
                let pos = GridPos(row: r, col: c)
                guard let tile = board[pos] else { continue }
                let pt = centerPoint(for: pos)
                tiles[tile.id] = VisualTile(tile: tile, pos: pos, x: pt.0, y: pt.1, targetX: pt.0, targetY: pt.1)
                posToId[pos] = tile.id
            }
        }
    }

    func cancelPlayback() {
        stepQueue.removeAll()
        finalBoardSnapshot = nil
        onStepEvent = nil
        onPlaybackComplete = nil
        isAnimating = false
        _ = canvas.setAttribute?("aria-busy", "false")
        particles.removeAll()
        beams.removeAll()
        callouts.removeAll()
        shakeTimer = 0
        setSelected(nil)
    }

    func setSelected(_ pos: GridPos?) {
        for (id, var vt) in tiles {
            vt.selected = (vt.pos == pos)
            tiles[id] = vt
        }
    }

    func pulseHint(_ move: ValidMove) {
        for p in [move.from, move.to] {
            if let id = posToId[p], var vt = tiles[id] {
                vt.hintPulse = 1.0
                tiles[id] = vt
            }
        }
    }

    func gridPos(atLocalX x: Double, y: Double) -> GridPos? {
        let col = Int(floor((x - boardOriginX) / cellSize))
        let row = Int(floor((y - boardOriginY) / cellSize))
        guard row >= 0, row < BoardState.rows, col >= 0, col < BoardState.cols else { return nil }
        return GridPos(row: row, col: col)
    }

    // MARK: - Step Playback

    func playSteps(
        _ steps: [BoardStep],
        finalBoard: BoardState,
        onStep: @escaping (BoardStep) -> Void,
        onComplete: @escaping () -> Void
    ) {
        guard !steps.isEmpty else {
            onComplete()
            return
        }
        setSelected(nil)
        stepQueue = steps
        finalBoardSnapshot = finalBoard
        onStepEvent = onStep
        onPlaybackComplete = onComplete
        isAnimating = true
        _ = canvas.setAttribute?("aria-busy", "true")
        advanceNextStep()
    }

    private func advanceNextStep() {
        guard !stepQueue.isEmpty else {
            if let snapshot = finalBoardSnapshot {
                syncFullBoard(snapshot)
            }
            finalBoardSnapshot = nil
            isAnimating = false
            _ = canvas.setAttribute?("aria-busy", "false")
            let done = onPlaybackComplete
            onPlaybackComplete = nil
            onStepEvent = nil
            done?()
            return
        }

        let step = stepQueue.removeFirst()
        onStepEvent?(step)
        stepTimer = 0
        stepDuration = applyStep(step)
        if stepDuration <= 0.001 {
            advanceNextStep()
        }
    }

    private func applyStep(_ step: BoardStep) -> Double {
        switch step {
        case .swap(let from, let to, let reverted):
            let idA = posToId[from]
            let idB = posToId[to]
            let ptA = centerPoint(for: from)
            let ptB = centerPoint(for: to)
            if reverted {
                if let idA, var tile = tiles[idA] {
                    tile.x += (ptB.0 - ptA.0) * 0.23
                    tile.y += (ptB.1 - ptA.1) * 0.23
                    tiles[idA] = tile
                }
                triggerShake(intensity: 3.0, duration: 0.14)
                return 0.16
            } else {
                posToId[from] = idB
                posToId[to] = idA
                if let idA, var vtA = tiles[idA] {
                    vtA.pos = to
                    vtA.targetX = ptB.0
                    vtA.targetY = ptB.1
                    tiles[idA] = vtA
                }
                if let idB, var vtB = tiles[idB] {
                    vtB.pos = from
                    vtB.targetX = ptA.0
                    vtB.targetY = ptA.1
                    tiles[idB] = vtB
                }
                if cosmetics.puppyPawTrailUnlocked {
                    spawnParticles(at: ptA.0, y: ptA.1, color: "#ffe8a3", count: 4, emoji: "🐾")
                }
                return 0.13
            }

        case .matchCleared(let positions, let cascadeDepth, let points, _):
            var sumX = 0.0
            var sumY = 0.0
            for pos in positions {
                let pt = centerPoint(for: pos)
                sumX += pt.0
                sumY += pt.1
                if let id = posToId.removeValue(forKey: pos), let vt = tiles.removeValue(forKey: id) {
                    spawnParticles(at: pt.0, y: pt.1, color: Self.tileColor(for: vt.tile.kind), count: 8)
                }
            }
            if !positions.isEmpty {
                let avgX = sumX / Double(positions.count)
                let avgY = sumY / Double(positions.count)
                let label = cascadeDepth >= 2 ? "\(cascadeDepth)x! +\(points)" : "+\(points)"
                let color = cascadeDepth >= 3 ? "#ffe066" : "#ffffff"
                callouts.append(FloatingCallout(text: label, x: avgX, y: avgY, color: color, fontSize: cascadeDepth >= 2 ? 20 : 15, life: 0.65, maxLife: 0.65))
            }
            if cascadeDepth >= 3 {
                triggerShake(intensity: 5.5, duration: 0.18)
            }
            return 0.15

        case .specialCreated(let at, let tile):
            let pt = centerPoint(for: at)
            if let old = posToId[at] { tiles.removeValue(forKey: old) }
            tiles[tile.id] = VisualTile(tile: tile, pos: at, x: pt.0, y: pt.1, targetX: pt.0, targetY: pt.1, scaleX: 1.25, scaleY: 1.25)
            posToId[at] = tile.id
            spawnParticles(at: pt.0, y: pt.1, color: "#ffd866", count: 12)
            return 0.09

        case .specialTriggered(let kind, let origin, let affected, let points):
            let origPt = centerPoint(for: origin)
            switch kind {
            case .korvRocketHorizontal, .rocketPlusRocket, .rocketPlusBomb:
                let range = kind == .rocketPlusBomb ? -1...1 : 0...0
                for row in range.map({ origin.row + $0 }) where (0..<BoardState.rows).contains(row) {
                    addRocketBeam(axis: .horizontal, lane: row)
                }
                if kind != .korvRocketHorizontal {
                    for col in range.map({ origin.col + $0 }) where (0..<BoardState.cols).contains(col) {
                        addRocketBeam(axis: .vertical, lane: col)
                    }
                }
            case .korvRocketVertical:
                addRocketBeam(axis: .vertical, lane: origin.col)
            case .goldenSwirl, .swirlPlusRocket, .swirlPlusBomb, .swirlPlusSwirl:
                for p in affected.prefix(16) {
                    let dst = centerPoint(for: p)
                    beams.append(BeamEffect(x1: origPt.0, y1: origPt.1, x2: dst.0, y2: dst.1, color: "#ffe066", life: 0.26, maxLife: 0.26))
                }
            case .fiestaBomb, .bombPlusBomb, .padThaiCross:
                spawnParticles(at: origPt.0, y: origPt.1, color: "#ff8c42", count: 22)
            }

            for pos in affected {
                if let id = posToId.removeValue(forKey: pos) {
                    tiles.removeValue(forKey: id)
                }
                let pt = centerPoint(for: pos)
                spawnParticles(at: pt.0, y: pt.1, color: "#ffd166", count: 5)
            }
            triggerShake(intensity: 7.0, duration: 0.22)
            callouts.append(FloatingCallout(text: "+\(points)", x: origPt.0, y: origPt.1, color: "#ffe066", fontSize: 22, life: 0.72, maxLife: 0.72))
            return 0.24

        case .cupcakePacifierWave(let from, let poppedSnoreAt):
            let s = centerPoint(for: from)
            let d = centerPoint(for: poppedSnoreAt)
            beams.append(BeamEffect(x1: s.0, y1: s.1, x2: d.0, y2: d.1, color: "#ff85c0", life: 0.30, maxLife: 0.30))
            spawnParticles(at: d.0, y: d.1, color: "#ff99cc", count: 16, emoji: "✨")
            return 0.28

        case .snoreDamaged(let at, let remaining):
            if let id = posToId[at], var vt = tiles[id] {
                vt.tile.snore?.hitsRemaining = remaining
                tiles[id] = vt
            }
            return 0.04

        case .snorePopped(let at, let points):
            if let id = posToId[at], var vt = tiles[id] {
                vt.tile.snore = nil
                tiles[id] = vt
            }
            let pt = centerPoint(for: at)
            spawnParticles(at: pt.0, y: pt.1, color: "#b8d0ff", count: 12)
            callouts.append(FloatingCallout(text: "Shhh! +\(points)", x: pt.0, y: pt.1, color: "#c8dcff", fontSize: 15, life: 0.6, maxLife: 0.6))
            return 0.10

        case .snoreSpawned(let at, let bubble):
            if let id = posToId[at], var vt = tiles[id] {
                vt.tile.snore = bubble
                tiles[id] = vt
            }
            let pt = centerPoint(for: at)
            callouts.append(FloatingCallout(text: "Zzz...", x: pt.0, y: pt.1, color: "#b0beff", fontSize: 16, life: 0.65, maxLife: 0.65))
            return 0.16

        case .snoreDrifted(let from, let to):
            if let fromId = posToId[from], var fromVt = tiles[fromId],
               let toId = posToId[to], var toVt = tiles[toId] {
                toVt.tile.snore = fromVt.tile.snore
                fromVt.tile.snore = nil
                tiles[fromId] = fromVt
                tiles[toId] = toVt
            }
            return 0.06

        case .gravityApplied(let moves):
            for move in moves {
                posToId.removeValue(forKey: move.from)
            }
            for move in moves {
                posToId[move.to] = move.tileId
                if var vt = tiles[move.tileId] {
                    let pt = centerPoint(for: move.to)
                    vt.pos = move.to
                    vt.targetX = pt.0
                    vt.targetY = pt.1
                    vt.scaleX = 0.94
                    vt.scaleY = 1.07
                    tiles[move.tileId] = vt
                }
            }
            return 0.18

        case .tilesSpawned(let spawns):
            for spawn in spawns {
                if let old = posToId[spawn.at] { tiles.removeValue(forKey: old) }
                let dst = centerPoint(for: spawn.at)
                let startY = spawn.spawnRowOffset > 0 ? boardOriginY - Double(spawn.spawnRowOffset) * cellSize : dst.1
                tiles[spawn.tile.id] = VisualTile(
                    tile: spawn.tile,
                    pos: spawn.at,
                    x: dst.0,
                    y: startY,
                    targetX: dst.0,
                    targetY: dst.1,
                    scaleX: 0.95,
                    scaleY: 1.06
                )
                posToId[spawn.at] = spawn.tile.id
            }
            return 0.20

        case .puppySpawned(let at, let tile):
            let pt = centerPoint(for: at)
            if let old = posToId[at] { tiles.removeValue(forKey: old) }
            tiles[tile.id] = VisualTile(tile: tile, pos: at, x: pt.0, y: pt.1 - cellSize, targetX: pt.0, targetY: pt.1)
            posToId[at] = tile.id
            spawnParticles(at: pt.0, y: pt.1, color: "#ffe066", count: 10, emoji: "🐾")
            callouts.append(FloatingCallout(text: "Stray Puppy! 🐾", x: pt.0, y: pt.1, color: "#ffe066", fontSize: 17, life: 0.85, maxLife: 0.85))
            return 0.22

        case .puppyRescued(let at, let blastPositions, let points):
            let pt = centerPoint(for: at)
            for p in blastPositions {
                if let id = posToId.removeValue(forKey: p) { tiles.removeValue(forKey: id) }
            }
            spawnParticles(at: pt.0, y: pt.1, color: "#ff7ab6", count: 18, emoji: "💖")
            triggerShake(intensity: 6.5, duration: 0.22)
            callouts.append(FloatingCallout(text: "PUPPY RESCUED! +\(points)", x: logicalWidth / 2.0, y: pt.1 - 12, color: "#ff99cc", fontSize: 19, life: 0.95, maxLife: 0.95))
            return 0.30

        case .teidoComboAchievement(let at, let tile):
            let pt = centerPoint(for: at)
            if let old = posToId[at] { tiles.removeValue(forKey: old) }
            tiles[tile.id] = VisualTile(tile: tile, pos: at, x: pt.0, y: pt.1, targetX: pt.0, targetY: pt.1, scaleX: 1.25, scaleY: 1.25)
            posToId[at] = tile.id
            callouts.append(FloatingCallout(text: "🏆 Combo Rocket!", x: pt.0, y: pt.1, color: "#66d9ff", fontSize: 18, life: 0.85, maxLife: 0.85))
            return 0.22

        case .tierUp(_, _, let banner, let poppedSnores, _, _):
            for p in poppedSnores {
                if let id = posToId[p], var vt = tiles[id] {
                    vt.tile.snore = nil
                    tiles[id] = vt
                }
                let pt = centerPoint(for: p)
                spawnParticles(at: pt.0, y: pt.1, color: "#ffffff", count: 10)
            }
            callouts.append(FloatingCallout(text: banner, x: logicalWidth / 2.0, y: logicalHeight / 2.0, color: "#ffe866", fontSize: 22, life: 1.1, maxLife: 1.1))
            return 0.30

        case .boardShuffled(let moves, _):
            for move in moves {
                posToId[move.to] = move.tileId
                if var vt = tiles[move.tileId] {
                    let pt = centerPoint(for: move.to)
                    vt.pos = move.to
                    vt.targetX = pt.0
                    vt.targetY = pt.1
                    tiles[move.tileId] = vt
                }
            }
            callouts.append(FloatingCallout(text: "🌭 Korv Shuffle!", x: logicalWidth / 2.0, y: logicalHeight / 2.0, color: "#80d4ff", fontSize: 21, life: 0.85, maxLife: 0.85))
            return 0.28

        case .avatarReaction, .gameOver:
            return 0.0
        }
    }

    // MARK: - 120Hz Frame Tick & Rendering

    func tick(dt: Double) {
        let clampedDt = min(0.05, max(0.001, dt))
        elapsedTime += clampedDt

        if isAnimating {
            stepTimer += clampedDt
            if stepTimer >= stepDuration {
                advanceNextStep()
            }
        }

        let lerpFactor = min(1.0, clampedDt * 22.0)
        let springDecay = exp(-22.0 * clampedDt)
        for (id, var vt) in tiles {
            vt.x += (vt.targetX - vt.x) * lerpFactor
            vt.y += (vt.targetY - vt.y) * lerpFactor

            let targetScale = vt.selected ? 1.12 : 1.0
            advanceScale(&vt.scaleX, velocity: &vt.scaleVelocityX, target: targetScale, dt: clampedDt, decay: springDecay)
            advanceScale(&vt.scaleY, velocity: &vt.scaleVelocityY, target: targetScale, dt: clampedDt, decay: springDecay)

            if vt.hintPulse > 0 {
                vt.hintPulse = max(0, vt.hintPulse - clampedDt * 1.4)
            }
            tiles[id] = vt
        }

        particles = particles.compactMap { p in
            var next = p
            next.life -= clampedDt
            guard next.life > 0 else { return nil }
            next.x += next.vx * clampedDt
            next.y += next.vy * clampedDt
            next.vy += 120.0 * clampedDt
            return next
        }

        beams = beams.compactMap { b in
            var next = b
            next.life -= clampedDt
            return next.life > 0 ? next : nil
        }

        callouts = callouts.compactMap { c in
            var next = c
            next.life -= clampedDt
            next.y -= 44.0 * clampedDt
            return next.life > 0 ? next : nil
        }

        if shakeTimer > 0 {
            shakeTimer = max(0, shakeTimer - clampedDt)
        }

        render()
    }

    private func render() {
        _ = ctx.clearRect?(0, 0, logicalWidth, logicalHeight)
        _ = ctx.save?()

        if screenShakeEnabled && shakeTimer > 0 {
            let decay = shakeTimer * 4.5
            let dx = sin(elapsedTime * 85.0) * shakeIntensity * min(1.0, decay)
            let dy = cos(elapsedTime * 72.0) * shakeIntensity * 0.5 * min(1.0, decay)
            _ = ctx.translate?(dx, dy)
        }

        drawBoardContainer()
        drawTiles()
        drawBeams()
        drawParticles()
        drawCallouts()

        _ = ctx.restore?()
    }

    private func advanceScale(_ scale: inout Double, velocity: inout Double, target: Double, dt: Double, decay: Double) {
        let displacement = scale - target
        let impulse = (velocity + 22.0 * displacement) * dt
        scale = target + (displacement + impulse) * decay
        velocity = (velocity - 22.0 * impulse) * decay
    }

    private func addRocketBeam(axis: RocketOrientation, lane: Int) {
        let first = axis == .horizontal ? GridPos(row: lane, col: 0) : GridPos(row: 0, col: lane)
        let last = axis == .horizontal
            ? GridPos(row: lane, col: BoardState.cols - 1) : GridPos(row: BoardState.rows - 1, col: lane)
        let start = centerPoint(for: first)
        let end = centerPoint(for: last)
        beams.append(BeamEffect(x1: start.0, y1: start.1, x2: end.0, y2: end.1, color: "#2ea8ff", life: 0.25, maxLife: 0.25))
    }

    private func drawBoardContainer() {
        let totalW = cellSize * Double(BoardState.cols)
        let totalH = cellSize * Double(BoardState.rows)

        drawRoundedRect(x: boardOriginX - 7, y: boardOriginY - 7, w: totalW + 14, h: totalH + 14, r: 20)
        ctx.fillStyle = .string("rgba(16, 20, 40, 0.62)")
        _ = ctx.fill?()
        ctx.lineWidth = .number(cosmetics.biltemaTrimUnlocked ? 3.5 : 1.5)
        ctx.strokeStyle = .string(cosmetics.biltemaTrimUnlocked ? "rgba(38, 148, 255, 0.92)" : "rgba(255, 255, 255, 0.22)")
        _ = ctx.stroke?()

        for r in 0..<BoardState.rows {
            for c in 0..<BoardState.cols {
                let x = boardOriginX + Double(c) * cellSize + 1.5
                let y = boardOriginY + Double(r) * cellSize + 1.5
                drawRoundedRect(x: x, y: y, w: cellSize - 3, h: cellSize - 3, r: 8)
                ctx.fillStyle = .string((r + c) % 2 == 0 ? "rgba(255,255,255,0.08)" : "rgba(255,255,255,0.03)")
                _ = ctx.fill?()
            }
        }
    }

    private func drawTiles() {
        let badge = cellSize * 0.86
        let half = badge / 2.0

        for vt in tiles.values {
            _ = ctx.save?()
            _ = ctx.translate?(vt.x, vt.y)

            let pulseBoost = vt.hintPulse > 0 ? (1.0 + sin(vt.hintPulse * .pi * 4.0) * 0.08) : 1.0
            let idleTilt = vt.tile.kind.isPuppy ? sin(elapsedTime * 5.0) * 0.07 : 0.0
            _ = ctx.rotate?(idleTilt)
            _ = ctx.scale?(vt.scaleX * pulseBoost, vt.scaleY * pulseBoost)

            drawRoundedRect(x: -half, y: -half + 2.5, w: badge, h: badge, r: cellSize * 0.22)
            ctx.fillStyle = .string("rgba(0, 0, 0, 0.24)")
            _ = ctx.fill?()

            drawRoundedRect(x: -half, y: -half, w: badge, h: badge, r: cellSize * 0.22)
            ctx.fillStyle = .string(Self.tileColor(for: vt.tile.kind))
            _ = ctx.fill?()

            if vt.selected {
                ctx.lineWidth = .number(3.0)
                ctx.strokeStyle = .string("#ffdf5c")
                _ = ctx.stroke?()
            } else if cosmetics.goldenSesameBorderUnlocked {
                ctx.lineWidth = .number(2.2)
                ctx.strokeStyle = .string("#f5c242")
                _ = ctx.stroke?()
            } else {
                ctx.lineWidth = .number(1.2)
                ctx.strokeStyle = .string("rgba(255,255,255,0.45)")
                _ = ctx.stroke?()
            }

            let key = Self.spriteKey(for: vt.tile.kind)
            if vt.tile.kind.isPuppy {
                let tailX = badge * (0.37 + sin(elapsedTime * 12) * 0.04)
                _ = ctx.beginPath?()
                _ = ctx.moveTo?(badge * 0.17, badge * 0.22)
                _ = ctx.quadraticCurveTo?(tailX, badge * 0.31, tailX, badge * 0.13)
                ctx.strokeStyle = .string("#a87547")
                ctx.lineWidth = .number(badge * 0.06)
                ctx.lineCap = .string("round")
                _ = ctx.stroke?()
            }
            if let img = spriteCache[key] {
                let iconSize = badge * 0.80
                _ = ctx.drawImage?(img, -iconSize / 2.0, -iconSize / 2.0, iconSize, iconSize)
            } else {
                ctx.font = .string("\(Int(cellSize * 0.52))px system-ui, sans-serif")
                ctx.textAlign = .string("center")
                ctx.textBaseline = .string("middle")
                _ = ctx.fillText?(Self.fallbackEmoji(for: vt.tile.kind), 0, 1)
            }

            drawSpecialOverlay(vt.tile.special, size: badge)

            if let snore = vt.tile.snore {
                drawSnoreOverlay(snore, size: badge)
            }

            _ = ctx.restore?()
        }
    }

    private func drawSpecialOverlay(_ special: SpecialModifier, size s: Double) {
        switch special {
        case .none:
            return
        case .korvRocket(let orientation):
            ctx.fillStyle = .string("rgba(26, 138, 255, 0.85)")
            ctx.strokeStyle = .string("#ffffff")
            ctx.lineWidth = .number(1.8)
            if orientation == .horizontal {
                drawRoundedRect(x: -s * 0.46, y: -s * 0.13, w: s * 0.92, h: s * 0.26, r: 6)
            } else {
                drawRoundedRect(x: -s * 0.13, y: -s * 0.46, w: s * 0.26, h: s * 0.92, r: 6)
            }
            _ = ctx.fill?()
            _ = ctx.stroke?()
            ctx.fillStyle = .string("#ffffff")
            ctx.font = .string("800 \(Int(cellSize * 0.34))px system-ui, sans-serif")
            ctx.textAlign = .string("center")
            ctx.textBaseline = .string("middle")
            _ = ctx.fillText?(orientation == .horizontal ? "↔" : "↕", 0, 1)

        case .fiestaBomb:
            _ = ctx.beginPath?()
            _ = ctx.arc?(0, 0, s * 0.45, 0, Double.pi * 2.0)
            ctx.fillStyle = .string("rgba(255, 110, 40, 0.24)")
            _ = ctx.fill?()
            ctx.strokeStyle = .string("#ffd84d")
            ctx.lineWidth = .number(2.8)
            _ = ctx.stroke?()
            ctx.font = .string("\(Int(cellSize * 0.32))px system-ui, sans-serif")
            ctx.textAlign = .string("center")
            ctx.textBaseline = .string("middle")
            _ = ctx.fillText?("💥", s * 0.24, s * 0.24)

        case .goldenSwirl:
            _ = ctx.beginPath?()
            _ = ctx.arc?(0, 0, s * 0.44, 0, Double.pi * 2.0)
            ctx.fillStyle = .string("rgba(255, 224, 92, 0.92)")
            _ = ctx.fill?()
            ctx.strokeStyle = .string("#ffffff")
            ctx.lineWidth = .number(2.6)
            _ = ctx.stroke?()
            ctx.font = .string("\(Int(cellSize * 0.46))px system-ui, sans-serif")
            ctx.textAlign = .string("center")
            ctx.textBaseline = .string("middle")
            _ = ctx.fillText?("🍦", 0, 1)
        }
    }

    private func drawSnoreOverlay(_ snore: SnoreBubble, size s: Double) {
        let pulse = 1.0 + sin(elapsedTime * 3.2) * 0.04
        _ = ctx.beginPath?()
        _ = ctx.arc?(0, 0, s * 0.48 * pulse, 0, Double.pi * 2.0)
        ctx.fillStyle = .string(snore.isDoubleZzz ? "rgba(74, 82, 194, 0.64)" : "rgba(130, 152, 245, 0.50)")
        _ = ctx.fill?()
        ctx.strokeStyle = .string(snore.isDoubleZzz ? "rgba(225, 232, 255, 0.96)" : "rgba(255, 255, 255, 0.82)")
        ctx.lineWidth = .number(snore.isDoubleZzz ? 3.0 : 2.0)
        _ = ctx.stroke?()

        ctx.fillStyle = .string("#ffffff")
        ctx.font = .string("900 \(Int(cellSize * 0.27))px system-ui, sans-serif")
        ctx.textAlign = .string("center")
        ctx.textBaseline = .string("middle")
        _ = ctx.fillText?(snore.isDoubleZzz ? "ZZZ!" : "Zzz", 0, snore.isDrifting ? -3 : 0)

        if snore.isDrifting {
            ctx.fillStyle = .string("#c8f0ff")
            ctx.font = .string("800 \(Int(cellSize * 0.16))px system-ui, sans-serif")
            _ = ctx.fillText?("▲", 0, cellSize * 0.22)
        }
    }

    private func drawBeams() {
        for b in beams {
            let alpha = max(0, b.life / b.maxLife)
            _ = ctx.save?()
            ctx.globalAlpha = .number(alpha)
            ctx.strokeStyle = .string(b.color)
            ctx.lineWidth = .number(12.0 * alpha + 3.0)
            ctx.lineCap = .string("round")
            _ = ctx.beginPath?()
            _ = ctx.moveTo?(b.x1, b.y1)
            _ = ctx.lineTo?(b.x2, b.y2)
            _ = ctx.stroke?()
            _ = ctx.restore?()
        }
    }

    private func drawParticles() {
        for p in particles {
            let alpha = max(0, p.life / p.maxLife)
            _ = ctx.save?()
            ctx.globalAlpha = .number(alpha)
            if let emoji = p.emoji {
                ctx.font = .string("\(Int(p.size * 2.2))px system-ui, sans-serif")
                ctx.textAlign = .string("center")
                ctx.textBaseline = .string("middle")
                _ = ctx.fillText?(emoji, p.x, p.y)
            } else {
                _ = ctx.beginPath?()
                _ = ctx.arc?(p.x, p.y, p.size * alpha, 0, Double.pi * 2.0)
                ctx.fillStyle = .string(p.color)
                _ = ctx.fill?()
            }
            _ = ctx.restore?()
        }
    }

    private func drawCallouts() {
        for c in callouts {
            let alpha = max(0, min(1.0, (c.life / c.maxLife) * 1.4))
            _ = ctx.save?()
            ctx.globalAlpha = .number(alpha)
            ctx.font = .string("900 \(Int(c.fontSize))px system-ui, -apple-system, sans-serif")
            ctx.textAlign = .string("center")
            ctx.textBaseline = .string("middle")
            ctx.lineWidth = .number(3.5)
            ctx.strokeStyle = .string("rgba(12, 14, 28, 0.85)")
            _ = ctx.strokeText?(c.text, c.x, c.y)
            ctx.fillStyle = .string(c.color)
            _ = ctx.fillText?(c.text, c.x, c.y)
            _ = ctx.restore?()
        }
    }

    private func drawRoundedRect(x: Double, y: Double, w: Double, h: Double, r: Double) {
        let radius = min(r, w / 2.0, h / 2.0)
        _ = ctx.beginPath?()
        _ = ctx.moveTo?(x + radius, y)
        _ = ctx.arcTo?(x + w, y, x + w, y + h, radius)
        _ = ctx.arcTo?(x + w, y + h, x, y + h, radius)
        _ = ctx.arcTo?(x, y + h, x, y, radius)
        _ = ctx.arcTo?(x, y, x + w, y, radius)
        _ = ctx.closePath?()
    }

    private func centerPoint(for pos: GridPos) -> (Double, Double) {
        let x = boardOriginX + (Double(pos.col) + 0.5) * cellSize
        let y = boardOriginY + (Double(pos.row) + 0.5) * cellSize
        return (x, y)
    }

    private func triggerShake(intensity: Double, duration: Double) {
        guard screenShakeEnabled else { return }
        shakeIntensity = max(shakeIntensity, intensity)
        shakeTimer = max(shakeTimer, duration)
    }

    private func spawnParticles(at x: Double, y: Double, color: String, count: Int, emoji: String? = nil) {
        for i in 0..<count {
            let angle = (Double(i) / Double(max(1, count))) * Double.pi * 2.0 + Double.random(in: -0.3...0.3)
            let speed = Double.random(in: 55...165)
            particles.append(Particle(
                x: x,
                y: y,
                vx: cos(angle) * speed,
                vy: sin(angle) * speed - 40.0,
                life: 0.45,
                maxLife: 0.45,
                size: Double.random(in: 4.5...8.5),
                color: color,
                emoji: emoji
            ))
        }
    }

    static func spriteKey(for kind: TileKind) -> String {
        switch kind {
        case .standard(let std): return std.rawValue
        case .puppy: return "puppy"
        case .padThai: return "padThai"
        }
    }

    static func fallbackEmoji(for kind: TileKind) -> String {
        switch kind {
        case .standard(.cupcake): return "🧁"
        case .standard(.teido): return "🥔"
        case .standard(.hermanosTaco): return "🌮"
        case .standard(.partillePoke): return "🥗"
        case .standard(.biltemaCombo): return "🌭"
        case .standard(.bigMac): return "🍔"
        case .puppy: return "🐶"
        case .padThai: return "🍜"
        }
    }

    static func tileColor(for kind: TileKind) -> String {
        switch kind {
        case .standard(.cupcake): return "#ffd6eb"
        case .standard(.teido): return "#fae8c8"
        case .standard(.hermanosTaco): return "#ffebc2"
        case .standard(.partillePoke): return "#d1f5f0"
        case .standard(.biltemaCombo): return "#d1e8ff"
        case .standard(.bigMac): return "#ffdebd"
        case .puppy: return "#fff2d1"
        case .padThai: return "#ffdb9e"
        }
    }
}
