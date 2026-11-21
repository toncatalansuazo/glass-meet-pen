import AppKit
import BrushKit
import Combine

/// Transparent, click-through-capable panel covering one display, above everything.
final class OverlayPanel: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        // Keep sharingType at its default so screen-sharing apps capture the annotations.
    }

    override var canBecomeKey: Bool { !ignoresMouseEvents }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyDown?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class OverlayController {
    private let model: AppModel
    private(set) var panel: OverlayPanel
    private let canvas: OverlayView

    init(model: AppModel) {
        self.model = model
        panel = OverlayPanel(screen: model.selectedScreen)
        canvas = OverlayView(model: model)
        panel.contentView = canvas
        panel.onKeyDown = { [weak self] in self?.handleKey($0) ?? false }

        model.addDocumentListener { [weak self] event in self?.canvas.apply(event) }
        model.onFadeStrokes = { [weak self] ids, duration in self?.canvas.fade(ids, duration: duration) }
        panel.orderFrontRegardless()
    }

    func setDrawMode(_ on: Bool) {
        panel.ignoresMouseEvents = !on
        canvas.drawModeChanged(on)
        if on {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.resignKey()
            panel.orderFrontRegardless()
        }
    }

    func move(to screen: NSScreen) {
        panel.setFrame(screen.frame, display: true)
        canvas.relayout()
    }

    /// Shortcuts while drawing: ⌘Z/⇧⌘Z, tool letters, 1–8 colors, Esc leaves draw mode.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard !canvas.isEditingText else { return false } // keys belong to the text being typed
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags.contains(.command) {
            if chars == "z" {
                flags.contains(.shift) ? model.redo() : model.undo()
                return true
            }
            return false
        }
        if event.keyCode == 53 { // Esc
            model.setDrawMode(false)
            return true
        }
        guard flags.subtracting([.shift, .capsLock, .numericPad, .function]).isEmpty, let c = chars.first else { return false }
        if let tool = Tool.allCases.first(where: { $0.shortcutKey == c }) {
            model.selectTool(tool)
            return true
        }
        if let n = c.wholeNumberValue, (1...RGBAColor.palette.count).contains(n) {
            model.selectColor(RGBAColor.palette[n - 1])
            return true
        }
        if c == "[" || c == "]" {
            let all = WidthPreset.allCases
            let i = model.mouseTool.width.rawValue + (c == "]" ? 1 : -1)
            if all.indices.contains(i) { model.selectWidth(all[i]) }
            return true
        }
        return false
    }
}

/// Renders committed strokes as one `CAShapeLayer` each, plus live strokes, and
/// turns mouse input into document intents.
@MainActor
final class OverlayView: NSView, NSTextFieldDelegate {
    private let model: AppModel
    private let board = CALayer()
    private let container = CALayer()
    private var committedLayers: [UUID: CAShapeLayer] = [:]
    private var liveLayers: [UUID: CAShapeLayer] = [:]
    private var liveStrokes: [UUID: Stroke] = [:]
    private var activeStroke: Stroke?
    private var erasing = false
    private var tracking: NSTrackingArea?
    private var subscriptions: Set<AnyCancellable> = []
    /// The text being typed with the Text tool, before it becomes a stroke, and the
    /// style it was opened with (later toolbar changes don't alter it).
    private var textEditor: NSTextField?
    private var textStyle: (fontSize: CGFloat, color: RGBAColor, width: WidthPreset)?
    var isEditingText: Bool { textEditor != nil }

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = .clear
        board.backgroundColor = .white
        board.opacity = 0
        layer?.addSublayer(board)
        container.isGeometryFlipped = true // top-left origin, matching normalized coordinates
        layer?.addSublayer(container)

        model.$boardEnabled.combineLatest(model.$boardOpacity, model.$toolbarVisible)
            .sink { [weak self] enabled, opacity, toolbarVisible in
                self?.board.opacity = Whiteboard.visibleOpacity(enabled: enabled, opacity: opacity, toolbarVisible: toolbarVisible)
            }
            .store(in: &subscriptions)
        model.$mouseTool
            .sink { [weak self] state in
                DispatchQueue.main.async {
                    if state.tool != .text { self?.finishText() }
                    self?.updateCursor()
                }
            }
            .store(in: &subscriptions)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        relayout()
    }

    func relayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        board.frame = bounds
        container.frame = bounds
        for (id, l) in committedLayers { if let s = model.document.committed[id] { configure(l, with: s) } }
        for (id, l) in liveLayers { if let s = liveStrokes[id] { configure(l, with: s) } }
        CATransaction.commit()
    }

    // MARK: Rendering

    private func configure(_ layer: CAShapeLayer, with stroke: Stroke) {
        layer.frame = container.bounds
        guard let r = StrokeRenderer.render(stroke, size: container.bounds.size) else { layer.path = nil; return }
        layer.path = r.path
        layer.opacity = Float(r.alpha)
        switch r.mode {
        case .stroke(let width):
            layer.fillColor = nil
            layer.strokeColor = r.color
            layer.lineWidth = width
            layer.lineCap = .round
            layer.lineJoin = .round
        case .fill:
            layer.fillColor = r.color
            layer.strokeColor = nil
            layer.lineWidth = 0
        }
    }

    private func makeLayer(for stroke: Stroke) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.contentsScale = window?.backingScaleFactor ?? 2
        configure(l, with: stroke)
        return l
    }

    func apply(_ event: DocumentEvent) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        switch event {
        case .liveBegan(let s):
            liveStrokes[s.id] = s
            let l = makeLayer(for: s)
            liveLayers[s.id] = l
            container.addSublayer(l)
        case .liveUpdated(let id, let points, let replace):
            guard var s = liveStrokes[id], let l = liveLayers[id] else { return }
            if replace { s.points = points } else { s.points.append(contentsOf: points) }
            liveStrokes[id] = s
            configure(l, with: s)
        case .liveCancelled(let id):
            liveLayers.removeValue(forKey: id)?.removeFromSuperlayer()
            liveStrokes[id] = nil
        case .committedChanged(let added, let removed):
            for id in removed { committedLayers.removeValue(forKey: id)?.removeFromSuperlayer() }
            for s in added {
                liveLayers.removeValue(forKey: s.id)?.removeFromSuperlayer()
                liveStrokes[s.id] = nil
                committedLayers[s.id]?.removeFromSuperlayer()
                committedLayers[s.id] = makeLayer(for: s)
            }
            if !added.isEmpty { restack() }
        }
    }

    /// Keeps committed strokes in seq order, with live strokes above them.
    private func restack() {
        let ordered = committedLayers.compactMap { id, l in model.document.committed[id].map { ($0.seq, l) } }
            .sorted { $0.0 < $1.0 }.map(\.1)
        container.sublayers = ordered + Array(liveLayers.values)
    }

    func fade(_ ids: [UUID], duration: TimeInterval) {
        for id in ids {
            guard let l = committedLayers[id] else { continue }
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = l.opacity
            anim.toValue = 0
            anim.duration = duration
            anim.fillMode = .forwards
            anim.isRemovedOnCompletion = false
            l.add(anim, forKey: "fade")
        }
    }

    // MARK: Mode & cursor

    func drawModeChanged(_ on: Bool) {
        if on {
            window?.makeFirstResponder(self)
            updateCursor()
        } else {
            finishActiveStroke(cancel: true)
            finishText()
            NSCursor.arrow.set()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.activeAlways, .cursorUpdate, .mouseMoved, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func cursorUpdate(with event: NSEvent) {
        if model.drawMode { updateCursor() } else { super.cursorUpdate(with: event) }
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor()
    }

    private func updateCursor() {
        guard model.drawMode else { return }
        switch model.mouseTool.tool {
        case .eraser: Self.eraserCursor.set()
        case .text: NSCursor.iBeam.set()
        default: Self.pencilCursor.set()
        }
    }

    /// Pencil whose tip (bottom-left of the glyph) is the hot spot.
    private static let pencilCursor = symbolCursor("pencil", hotSpot: { size in NSPoint(x: 3, y: size.height - 3) })
    private static let eraserCursor = symbolCursor("eraser", hotSpot: { size in NSPoint(x: size.width / 2, y: size.height / 2) })

    /// A black SF Symbol with a white halo, so it stays visible on dark and light content.
    /// `hotSpot` is in the image's top-left-origin coordinates.
    private static func symbolCursor(_ name: String, hotSpot: (NSSize) -> NSPoint) -> NSCursor {
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
            return .crosshair
        }
        func tinted(_ color: NSColor) -> NSImage {
            symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color])) ?? symbol
        }
        let halo = tinted(.white), ink = tinted(.black)
        let pad: CGFloat = 2
        let size = NSSize(width: symbol.size.width + pad * 2, height: symbol.size.height + pad * 2)
        let image = NSImage(size: size, flipped: false) { _ in
            let origin = NSPoint(x: pad, y: pad)
            for dx in [-1.5, 0, 1.5] as [CGFloat] {
                for dy in [-1.5, 0, 1.5] as [CGFloat] where dx != 0 || dy != 0 {
                    halo.draw(at: NSPoint(x: origin.x + dx, y: origin.y + dy), from: .zero, operation: .sourceOver, fraction: 1)
                }
            }
            ink.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        return NSCursor(image: image, hotSpot: hotSpot(size))
    }

    // MARK: Mouse input

    private func normalized(_ event: NSEvent) -> StrokePoint {
        let p = convert(event.locationInWindow, from: nil)
        let topLeft = CGPoint(x: p.x, y: bounds.height - p.y)
        let pressure = event.subtype == .tabletPoint ? CGFloat(event.pressure) : 1
        return Geometry.normalize(topLeft, in: bounds.size, pressure: pressure)
    }

    override func mouseDown(with event: NSEvent) {
        guard model.drawMode else { return }
        let point = normalized(event)
        let state = model.mouseTool
        if state.tool == .text {
            // A click while typing places the text; the next click starts a new one.
            if isEditingText { finishText() } else { beginText(at: convert(event.locationInWindow, from: nil)) }
            return
        }
        if state.tool == .eraser {
            erasing = true
            model.erase(source: .mouse, points: [point], radius: model.eraserRadius(state.width))
            return
        }
        let stroke = Stroke(sourceID: .mouse, tool: state.tool, color: inkColor,
                            width: state.width.normalized(displayWidth: model.display.width), points: [point])
        activeStroke = stroke
        model.begin(stroke)
    }

    override func mouseDragged(with event: NSEvent) {
        guard model.drawMode else { return }
        var point = normalized(event)
        if erasing {
            model.erase(source: .mouse, points: [point], radius: model.eraserRadius(model.mouseTool.width))
            return
        }
        guard let stroke = activeStroke else { return }
        if stroke.tool.isShape, event.modifierFlags.contains(.shift), let start = stroke.points.first {
            point = Geometry.constrain(tool: stroke.tool, start: start, end: point, aspect: model.display.aspect)
        }
        model.append(source: .mouse, id: stroke.id, points: [point])
    }

    override func mouseUp(with event: NSEvent) {
        if erasing { erasing = false; return }
        if let stroke = activeStroke, stroke.tool.isFigure, isClick(stroke) {
            placeDefaultFigure(replacing: stroke)
            return
        }
        finishActiveStroke(cancel: false)
    }

    /// A shape whose two points are a few desktop points apart was clicked, not dragged.
    private func isClick(_ stroke: Stroke) -> Bool {
        guard let a = stroke.points.first, let b = model.document.live[.mouse]?.points.last ?? stroke.points.last else { return true }
        let dx = CGFloat(b.x - a.x) * CGFloat(model.display.width), dy = CGFloat(b.y - a.y) * CGFloat(model.display.height)
        return hypot(dx, dy) < 6
    }

    /// Replaces a clicked figure with one of default size centered on the click.
    private func placeDefaultFigure(replacing stroke: Stroke) {
        activeStroke = nil
        model.cancel(source: .mouse, id: stroke.id)
        guard let center = stroke.points.first, let figureAspect = stroke.tool.figureAspect else { return }
        let height: Float = 120
        let w = height * figureAspect / max(model.display.width, 1) / 2
        let h = height / max(model.display.height, 1) / 2
        let placed = Stroke(sourceID: .mouse, tool: stroke.tool, color: stroke.color, width: stroke.width,
                            points: [StrokePoint(x: center.x - w, y: center.y - h), StrokePoint(x: center.x + w, y: center.y + h)])
        model.begin(placed)
        model.end(source: .mouse, id: placed.id)
    }

    private func finishActiveStroke(cancel: Bool) {
        erasing = false
        guard let stroke = activeStroke else { return }
        activeStroke = nil
        cancel ? model.cancel(source: .mouse, id: stroke.id) : model.end(source: .mouse, id: stroke.id)
    }

    // MARK: Text

    /// The selected color with the ink opacity as its alpha.
    private var inkColor: RGBAColor {
        var color = model.mouseTool.color
        color.a = Float(model.inkOpacity)
        return color
    }

    /// Opens a borderless field at `point` (view coordinates) to type into.
    private func beginText(at point: NSPoint) {
        let style = (fontSize: TextLayout.fontSize(for: model.mouseTool.width), color: inkColor, width: model.mouseTool.width)
        let field = NSTextField(string: "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: style.fontSize)
        field.textColor = style.color.nsColor
        field.placeholderString = "Type, then press Return"
        field.delegate = self
        let height = TextLayout.lineHeight(forFontSize: style.fontSize) + 4
        field.frame = NSRect(x: point.x, y: point.y - height / 2, width: max(bounds.maxX - point.x - 8, 120), height: height)
        addSubview(field)
        textEditor = field
        textStyle = style
        window?.makeFirstResponder(field)
    }

    /// Turns the typed text into a stroke and closes the field. Nothing is placed when
    /// the text is empty or has nothing drawable (only emoji, for example).
    private func finishText(cancel: Bool = false) {
        guard let field = textEditor, let style = textStyle else { return }
        textEditor = nil
        textStyle = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let frame = field.frame
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        guard !cancel, TextLayout.isDrawable(text) else { return }
        // AppKit frames grow upwards; the box is top-left-origin like the strokes.
        let fieldFrame = CGRect(x: frame.minX, y: bounds.height - frame.maxY, width: frame.width, height: frame.height)
        let corners = TextLayout.corners(textSize: TextLayout.size(of: text, fontSize: style.fontSize),
                                         fieldFrame: fieldFrame, in: bounds.size)
        let stroke = Stroke(sourceID: .mouse, tool: .text, color: style.color,
                            width: style.width.normalized(displayWidth: model.display.width), points: corners, text: text)
        model.begin(stroke)
        model.end(source: .mouse, id: stroke.id)
    }

    /// Return places the text; Esc throws it away.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): finishText(); return true
        case #selector(NSResponder.cancelOperation(_:)): finishText(cancel: true); return true
        default: return false
        }
    }
}
