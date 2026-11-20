import AppKit
import BrushKit
import Combine

/// Central state of the Mac app. Owns the drawing document and routes intents
/// from the mouse (overlay) and the phone (server) into it, then fans events out
/// to the overlay and the connected phone.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    // MARK: Published UI state

    @Published private(set) var drawMode = false
    @Published var mouseTool = ToolState() {
        didSet { if mouseTool != oldValue { onToolChanged?(.mouse, mouseTool) } }
    }
    @Published private(set) var phoneTool: ToolState?
    @Published private(set) var phoneName: String?
    /// Seconds before new strokes fade away; nil keeps them until cleared.
    @Published var fadeDelay: TimeInterval? = AppSettings.shared.fadeDelay > 0 ? AppSettings.shared.fadeDelay : nil {
        didSet { settings.fadeDelay = fadeDelay ?? 0 }
    }
    /// Opacity of the toolbar's background (its buttons stay solid).
    @Published var toolbarOpacity: Double = AppSettings.shared.toolbarOpacity {
        didSet { settings.toolbarOpacity = toolbarOpacity }
    }
    @Published var compactToolbar: Bool = AppSettings.shared.compactToolbar {
        didSet { settings.compactToolbar = compactToolbar }
    }
    @Published var toolbarPosition: ToolbarPosition = AppSettings.shared.toolbarPosition {
        didSet { settings.toolbarPosition = toolbarPosition }
    }
    /// Opacity of new mouse strokes (0.1...1), stored as the stroke color's alpha.
    @Published var inkOpacity: Double = AppSettings.shared.inkOpacity {
        didSet { settings.inkOpacity = inkOpacity }
    }
    /// Whiteboard behind the strokes, hiding the apps under the overlay.
    @Published var boardEnabled = false
    @Published var boardOpacity: Double = AppSettings.shared.boardOpacity {
        didSet { settings.boardOpacity = boardOpacity }
    }
    @Published var toolbarVisible = true
    @Published private(set) var display: DisplayInfo
    @Published private(set) var screens: [NSScreen] = NSScreen.screens
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    let settings = AppSettings.shared

    // MARK: Document

    private(set) var document = Document()

    /// Listeners for document changes (overlay, server). `origin` is the source whose intent caused them.
    private var documentListeners: [(DocumentEvent) -> Void] = []
    var onDrawModeChanged: ((Bool) -> Void)?
    var onToolChanged: ((SourceID, ToolState) -> Void)?
    var onDisplayChanged: ((NSScreen, DisplayInfo) -> Void)?
    /// Asks the overlay to animate fading strokes before they're removed.
    var onFadeStrokes: (([UUID], TimeInterval) -> Void)?

    private init() {
        let screen = Self.screen(for: AppSettings.shared.defaultDisplayID) ?? NSScreen.main ?? NSScreen.screens[0]
        display = Self.info(for: screen)
        selectedScreen = screen
    }

    // MARK: Display

    private(set) var selectedScreen: NSScreen

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static func screen(for id: CGDirectDisplayID?) -> NSScreen? {
        guard let id else { return nil }
        return NSScreen.screens.first { displayID(of: $0) == id }
    }

    static func info(for screen: NSScreen) -> DisplayInfo {
        DisplayInfo(id: displayID(of: screen), name: screen.localizedName,
                    width: Float(screen.frame.width), height: Float(screen.frame.height))
    }

    func selectDisplay(_ screen: NSScreen) {
        selectedScreen = screen
        display = Self.info(for: screen)
        onDisplayChanged?(screen, display)
    }

    /// Called when displays are added/removed/resized.
    func screensChanged() {
        screens = NSScreen.screens
        let current = Self.screen(for: display.id) ?? NSScreen.main ?? NSScreen.screens[0]
        selectDisplay(current)
    }

    // MARK: Modes

    func setDrawMode(_ on: Bool) {
        guard on != drawMode else { return }
        if !on { _ = apply(document.cancel(source: .mouse)) }
        drawMode = on
        onDrawModeChanged?(on)
    }

    func toggleDrawMode() { setDrawMode(!drawMode) }

    // MARK: Listeners

    func addDocumentListener(_ listener: @escaping (DocumentEvent) -> Void) {
        documentListeners.append(listener)
    }

    @discardableResult
    private func apply(_ events: [DocumentEvent]) -> [DocumentEvent] {
        for event in events {
            for listener in documentListeners { listener(event) }
            if case .committedChanged(let added, _) = event, let fadeDelay, !added.isEmpty {
                scheduleFade(added.map(\.id), after: fadeDelay)
            }
        }
        refreshUndoState()
        return events
    }

    private func refreshUndoState() {
        canUndo = document.canUndo(.mouse)
        canRedo = document.canRedo(.mouse)
    }

    // MARK: Intents (any source)

    func begin(_ stroke: Stroke) { apply(document.begin(stroke)) }
    func append(source: SourceID, id: UUID, points: [StrokePoint]) { apply(document.append(source: source, id: id, points: points)) }
    func end(source: SourceID, id: UUID) { apply(document.end(source: source, id: id)) }
    func cancel(source: SourceID, id: UUID? = nil) { apply(document.cancel(source: source, id: id)) }
    func erase(source: SourceID, points: [StrokePoint], radius: Float) {
        apply(document.erase(source: source, at: points, radius: radius, aspect: display.aspect))
    }
    func undo(source: SourceID = .mouse) { apply(document.undo(source: source)) }
    func redo(source: SourceID = .mouse) { apply(document.redo(source: source)) }
    func clear(source: SourceID = .mouse) { apply(document.clear(source: source)) }

    /// Normalized eraser radius for a given width preset.
    func eraserRadius(_ width: WidthPreset) -> Float {
        (width.points * 2 + 6) / max(display.width, 1)
    }

    // MARK: Fading ink

    private static let fadeAnimation: TimeInterval = 0.6

    static let fadeChoices: [TimeInterval] = [1, 3, 5]

    private func scheduleFade(_ ids: [UUID], after fadeDelay: TimeInterval) {
        let delay = max(fadeDelay - Self.fadeAnimation, 0.1)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let alive = ids.filter { self.document.committed[$0] != nil }
            guard !alive.isEmpty else { return }
            self.onFadeStrokes?(alive, Self.fadeAnimation)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeAnimation) { [weak self] in
                guard let self else { return }
                self.apply(self.document.expire(alive))
            }
        }
    }

    // MARK: Phone state

    func phoneConnected(name: String?) {
        phoneName = name
        if name == nil { phoneTool = nil }
    }

    func setPhoneTool(_ state: ToolState, source: SourceID) {
        phoneTool = state
        onToolChanged?(source, state)
    }

    // MARK: Tools (mouse)

    func selectTool(_ tool: Tool) { mouseTool.tool = tool }
    func selectColor(_ color: RGBAColor) { mouseTool.color = color }
    func selectWidth(_ width: WidthPreset) { mouseTool.width = width }
}
