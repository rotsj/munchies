import Engine
import JavaScriptKit
import WASILibc

/// Pointer Events recognizer supporting drag-to-swap (35% tile threshold without lifting)
/// and tap-to-select + tap-adjacent on Mobile Safari and desktop browsers.
final class InputHandler {
    private let canvas: JSObject
    private let renderer: CanvasRenderer
    private let onSwapRequested: (GridPos, GridPos) -> Void
    private let onFirstGesture: () -> Void

    private var selectedPos: GridPos?
    private var dragStartPos: GridPos?
    private var dragStartX: Double = 0
    private var dragStartY: Double = 0
    private var dragTriggered = false
    private var activePointerId: Int?

    private var downClosure: JSClosure?
    private var moveClosure: JSClosure?
    private var upClosure: JSClosure?
    private var cancelClosure: JSClosure?

    init(
        canvas: JSObject,
        renderer: CanvasRenderer,
        onFirstGesture: @escaping () -> Void,
        onSwapRequested: @escaping (GridPos, GridPos) -> Void
    ) {
        self.canvas = canvas
        self.renderer = renderer
        self.onFirstGesture = onFirstGesture
        self.onSwapRequested = onSwapRequested
        attachListeners()
    }

    private func attachListeners() {
        let onDown = JSClosure { [weak self] args -> JSValue in
            guard let self, let event = args.first?.object else { return .undefined }
            self.handlePointerDown(event)
            return .undefined
        }
        let onMove = JSClosure { [weak self] args -> JSValue in
            guard let self, let event = args.first?.object else { return .undefined }
            self.handlePointerMove(event)
            return .undefined
        }
        let onUp = JSClosure { [weak self] args -> JSValue in
            guard let self, let event = args.first?.object else { return .undefined }
            self.handlePointerUp(event)
            return .undefined
        }
        let onCancel = JSClosure { [weak self] args -> JSValue in
            guard let self, let id = args.first?.object?.pointerId.number,
                  self.activePointerId == Int(id) else { return .undefined }
            self.reset()
            return .undefined
        }

        self.downClosure = onDown
        self.moveClosure = onMove
        self.upClosure = onUp
        self.cancelClosure = onCancel

        _ = canvas.addEventListener?("pointerdown", onDown)
        _ = canvas.addEventListener?("pointermove", onMove)
        _ = canvas.addEventListener?("pointerup", onUp)
        _ = canvas.addEventListener?("pointercancel", onCancel)
        _ = canvas.addEventListener?("lostpointercapture", onCancel)
    }

    private func localCoords(from event: JSObject) -> (Double, Double) {
        let rect = canvas.getBoundingClientRect!()
        let x = (event.clientX.number ?? 0) - (rect.left.number ?? 0)
        let y = (event.clientY.number ?? 0) - (rect.top.number ?? 0)
        return (x, y)
    }

    private func handlePointerDown(_ event: JSObject) {
        onFirstGesture()
        guard !renderer.isAnimating, activePointerId == nil, event.button.number == 0 else { return }

        let pointerId = Int(event.pointerId.number ?? 0)
        activePointerId = pointerId
        _ = canvas.setPointerCapture?(pointerId)

        let (x, y) = localCoords(from: event)
        guard let pos = renderer.gridPos(atLocalX: x, y: y) else {
            clearSelection()
            return
        }

        dragStartPos = pos
        dragStartX = x
        dragStartY = y
        dragTriggered = false

        if let prev = selectedPos {
            if prev == pos {
                clearSelection()
            } else if prev.isAdjacent(to: pos) {
                clearSelection()
                dragTriggered = true
                onSwapRequested(prev, pos)
            } else {
                selectedPos = pos
                renderer.setSelected(pos)
            }
        } else {
            selectedPos = pos
            renderer.setSelected(pos)
        }
    }

    private func handlePointerMove(_ event: JSObject) {
        guard !renderer.isAnimating,
              !dragTriggered,
              let startPos = dragStartPos,
              activePointerId == Int(event.pointerId.number ?? -1) else { return }

        let (x, y) = localCoords(from: event)
        let dx = x - dragStartX
        let dy = y - dragStartY
        let threshold = renderer.cellSize * 0.35

        guard hypot(dx, dy) >= threshold else { return }

        let target: GridPos
        if abs(dx) > abs(dy) {
            target = GridPos(row: startPos.row, col: startPos.col + (dx > 0 ? 1 : -1))
        } else {
            target = GridPos(row: startPos.row + (dy > 0 ? 1 : -1), col: startPos.col)
        }

        if target.row >= 0 && target.row < BoardState.rows && target.col >= 0 && target.col < BoardState.cols {
            dragTriggered = true
            clearSelection()
            onSwapRequested(startPos, target)
        }
    }

    private func handlePointerUp(_ event: JSObject) {
        let pointerId = Int(event.pointerId.number ?? 0)
        if activePointerId == pointerId {
            activePointerId = nil
            dragStartPos = nil
        }
    }

    private func clearSelection() {
        selectedPos = nil
        renderer.setSelected(nil)
    }

    func reset() {
        activePointerId = nil
        dragStartPos = nil
        dragTriggered = false
        clearSelection()
    }
}
