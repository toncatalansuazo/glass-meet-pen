import AppKit
import BrushKit
import Combine
import SwiftUI

/// Hosting view that accepts the first click even when the app isn't active,
/// so toolbar buttons work while another app has focus.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class ToolbarPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 760, height: 56),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
    }
    override var canBecomeKey: Bool { true }
}

@MainActor
final class ToolbarController {
    let panel = ToolbarPanel()
    private let model: AppModel
    private let view: NSView
    private let flyouts = FlyoutState()
    private var flyoutController: FlyoutController?
    private var subscriptions: Set<AnyCancellable> = []

    init(model: AppModel, server: RemoteServer) {
        self.model = model
        view = FirstMouseHostingView(rootView: ToolbarView(model: model, server: server, flyouts: flyouts))
        panel.contentView = view
        panel.setContentSize(view.fittingSize)
        place(on: model.selectedScreen)
        flyoutController = FlyoutController(model: model, state: flyouts, toolbar: panel)

        // A window shadow around a see-through toolbar draws a ghost outline.
        model.$toolbarOpacity
            .sink { [weak self] opacity in
                self?.panel.hasShadow = opacity > 0.5
                self?.panel.invalidateShadow()
            }
            .store(in: &subscriptions)

        // Switching between bar and sidebar moves the toolbar to that edge.
        model.$toolbarPosition.dropFirst().removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.place(on: self.panel.screen ?? self.model.selectedScreen)
                }
            }
            .store(in: &subscriptions)
        // The opacity slider appears with the board; resize keeping the toolbar's edge.
        model.$boardEnabled.dropFirst().removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.resizeInPlace() } }
            .store(in: &subscriptions)
        model.$compactToolbar.dropFirst().removeDuplicates()
            .sink { [weak self] _ in
                self?.flyouts.close()
                DispatchQueue.main.async { self?.resizeInPlace() }
            }
            .store(in: &subscriptions)
    }

    func place(on screen: NSScreen) {
        let f = screen.visibleFrame
        let size = view.fittingSize
        let origin: NSPoint
        switch model.toolbarPosition {
        case .bottom: origin = NSPoint(x: f.midX - size.width / 2, y: f.minY + 24)
        case .left: origin = NSPoint(x: f.minX + 12, y: f.midY - size.height / 2)
        case .right: origin = NSPoint(x: f.maxX - size.width - 12, y: f.midY - size.height / 2)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func resizeInPlace() {
        let old = panel.frame, size = view.fittingSize
        var frame = NSRect(origin: .zero, size: size)
        switch model.toolbarPosition {
        case .bottom: frame.origin = NSPoint(x: old.midX - size.width / 2, y: old.minY)
        case .left: frame.origin = NSPoint(x: old.minX, y: old.midY - size.height / 2)
        case .right: frame.origin = NSPoint(x: old.maxX - size.width, y: old.midY - size.height / 2)
        }
        panel.setFrame(frame, display: true)
    }

    func setVisible(_ visible: Bool) {
        if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }
}

struct ToolbarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var server: RemoteServer
    @ObservedObject var flyouts: FlyoutState

    private var vertical: Bool { model.toolbarPosition.isVertical }

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        let shape = RoundedRectangle(cornerRadius: vertical ? 18 : 28, style: .continuous)
        layout {
            dragHandle

            Button { model.toggleDrawMode() } label: {
                Image(systemName: model.drawMode ? "paintbrush.pointed.fill" : "cursorarrow")
                    .frame(width: 26, height: 26)
                    .foregroundStyle(model.drawMode ? Color.white : Color.primary)
                    .background(model.drawMode ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            }
            .hoverTip(model.drawMode
                      ? "Stop drawing: \(model.settings.drawHotKey.displayString) or Esc"
                      : "Start drawing: \(model.settings.drawHotKey.displayString)")

            divider

            if model.compactToolbar {
                cluster {
                    flyoutButton(.tools, help: "Tool: \(model.mouseTool.tool.displayName)") {
                        Image(systemName: model.mouseTool.tool.symbolName)
                    }
                    flyoutButton(.colors, help: "Color and opacity") {
                        Circle()
                            .fill(model.mouseTool.color.swiftUI.opacity(model.inkOpacity))
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1))
                            .frame(width: 18, height: 18)
                    }
                    flyoutButton(.widths, help: "Width \(Int(model.mouseTool.width.points)) pt") {
                        Circle().fill(Color.primary)
                            .frame(width: CGFloat(model.mouseTool.width.points) * 0.8 + 3,
                                   height: CGFloat(model.mouseTool.width.points) * 0.8 + 3)
                    }
                }
            } else {
                allOptions
            }

            divider

            cluster {
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 22, height: 26) }
                    .disabled(!model.canUndo).hoverTip("Undo (⌘Z)")
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 22, height: 26) }
                    .disabled(!model.canRedo).hoverTip("Redo (⇧⌘Z)")
                Button { model.clear() } label: { Image(systemName: "trash").frame(width: 22, height: 26) }
                    .hoverTip("Clear all (\(model.settings.clearHotKey.displayString))")
                fadeMenu
            }

            divider

            boardControls

            divider

            cluster {
                phoneIndicator
                positionMenu
            }

            Button { model.toolbarVisible = false } label: {
                Image(systemName: "xmark").font(.caption).frame(width: 18, height: 26)
            }
            .hoverTip("Hide toolbar (show it again from the menu bar)")
        }
        .buttonStyle(.plain)
        .modifier(SeeThroughHalo(backgroundOpacity: model.toolbarOpacity))
        .padding(.horizontal, vertical ? 8 : 12)
        .padding(.vertical, vertical ? 12 : 8)
        .background(WindowDragArea())
        .background(.regularMaterial.opacity(model.toolbarOpacity), in: shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1 * model.toolbarOpacity)))
        .padding(4)
        .fixedSize()
        .onPreferenceChange(FlyoutAnchorKey.self) { anchors in
            for (flyout, rect) in anchors { flyouts.setAnchor(rect, for: flyout) }
        }
    }

    /// The full tool, color and width rows of the classic (non-compact) toolbar.
    @ViewBuilder private var allOptions: some View {
        cluster {
            ForEach(Tool.allCases, id: \.self) { tool in
                Button { model.selectTool(tool) } label: {
                    Image(systemName: tool.symbolName)
                        .frame(width: 26, height: 26)
                        .background(model.mouseTool.tool == tool ? Color.primary.opacity(0.15) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                }
                .hoverTip("\(tool.displayName) (\(String(tool.shortcutKey).uppercased()))")
            }
        }

        divider

        cluster {
            ForEach(Array(RGBAColor.palette.enumerated()), id: \.offset) { index, color in
                Button { model.selectColor(color) } label: {
                    Circle()
                        .fill(color.swiftUI)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1))
                        .frame(width: 18, height: 18)
                        .padding(3)
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: model.mouseTool.color == color ? 2 : 0))
                }
                .hoverTip("Color \(index + 1)")
            }
        }

        divider

        cluster {
            ForEach(WidthPreset.allCases, id: \.self) { w in
                Button { model.selectWidth(w) } label: {
                    Circle().fill(Color.primary)
                        .frame(width: CGFloat(w.points) * 0.8 + 3, height: CGFloat(w.points) * 0.8 + 3)
                        .frame(width: 22, height: 26)
                        .background(model.mouseTool.width == w ? Color.primary.opacity(0.15) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                }
                .hoverTip("Width \(Int(w.points)) pt")
            }
        }

        let layout = vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        layout {
            Circle()
                .fill(model.mouseTool.color.swiftUI.opacity(model.inkOpacity))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1))
                .frame(width: 14, height: 14)
            Slider(value: $model.inkOpacity, in: 0.1...1)
                .controlSize(.small)
                .frame(width: vertical ? Self.columnWidth : 70)
        }
        .frame(minHeight: 26)
        .hoverTip("Ink opacity \(Int(model.inkOpacity * 100))%")
    }

    /// Grip to move the toolbar.
    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .rotationEffect(vertical ? .zero : .degrees(90))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: vertical ? Self.columnWidth : 14, height: vertical ? 14 : 26)
            .overlay(WindowDragArea())
            .hoverTip("Drag to move the toolbar")
    }

    /// Shows the current choice; hovering or clicking unfolds every option.
    private func flyoutButton<Label: View>(_ flyout: Flyout, help: String, @ViewBuilder label: () -> Label) -> some View {
        Button { flyouts.toggle(flyout) } label: {
            label()
                .frame(width: 26, height: 26)
                .background(flyouts.open == flyout ? Color.primary.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .onHover { flyouts.buttonHover(flyout, $0) }
        .background(GeometryReader { g in
            Color.clear.preference(key: FlyoutAnchorKey.self, value: [flyout: g.frame(in: .global)])
        })
        .accessibilityLabel(help)
    }

    /// Width of the sidebar's single column.
    private static let columnWidth: CGFloat = 40

    /// A run of buttons: in a row on the bottom bar, in a column in a sidebar.
    @ViewBuilder private func cluster<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if vertical {
            VStack(spacing: 4) { content() }
        } else {
            HStack(spacing: 10) { content() }
        }
    }

    private var positionMenu: some View {
        Menu {
            ForEach(ToolbarPosition.allCases, id: \.self) { position in
                Button { model.toolbarPosition = position } label: {
                    checkmarked(position.title, model.toolbarPosition == position)
                }
            }
        } label: {
            Image(systemName: model.toolbarPosition.symbolName).frame(width: 22, height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverTip("Toolbar position")
    }

    /// Opens upward from the bottom bar (wherever it fits in a sidebar): how long new strokes stay before fading.
    private var fadeMenu: some View {
        Menu {
            Button { model.fadeDelay = nil } label: { checkmarked("Permanent", model.fadeDelay == nil) }
            Divider()
            ForEach(AppModel.fadeChoices, id: \.self) { seconds in
                Button { model.fadeDelay = seconds } label: { checkmarked("\(Int(seconds)) s", model.fadeDelay == seconds) }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: model.fadeDelay == nil ? "timer" : "timer.circle.fill")
                Text(model.fadeDelay.map { "\(Int($0))s" } ?? "∞").monospacedDigit()
            }
            .foregroundStyle(model.fadeDelay == nil ? Color.primary : Color.accentColor)
            .frame(height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverTip("Fading ink: how long new strokes stay")
    }

    @ViewBuilder private func checkmarked(_ title: String, _ selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    /// Whiteboard behind the strokes, with its opacity slider while it is on.
    @ViewBuilder private var boardControls: some View {
        Button { model.boardEnabled.toggle() } label: {
            Image(systemName: model.boardEnabled ? "rectangle.inset.filled" : "rectangle.dashed")
                .frame(width: 22, height: 26)
                .foregroundStyle(model.boardEnabled ? Color.accentColor : Color.primary)
        }
        .hoverTip(model.boardEnabled ? "Hide whiteboard" : "Show whiteboard")
        if model.boardEnabled {
            Slider(value: $model.boardOpacity, in: 0.1...1)
                .controlSize(.small)
                .frame(width: vertical ? Self.columnWidth : 76)
                .hoverTip("Whiteboard opacity \(Int(model.boardOpacity * 100))%")
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.15 * max(model.toolbarOpacity, 0.4))).frame(width: vertical ? Self.columnWidth : 1, height: vertical ? 1 : 22)
    }

    @ViewBuilder private var phoneIndicator: some View {
        if let name = model.phoneName {
            HStack(spacing: 4) {
                Image(systemName: server.connectedIsPad ? "ipad" : "iphone")
                Circle().fill((model.phoneTool?.color ?? RGBAColor.palette[0]).swiftUI).frame(width: 8, height: 8)
            }
            .frame(height: 26)
            .hoverTip("\(name) connected")
        } else {
            Button { server.showPairing() } label: {
                Image(systemName: "iphone.slash").foregroundStyle(.secondary).frame(width: 22, height: 26)
            }
            .hoverTip("Connect iPhone/iPad")
        }
    }
}

extension RGBAColor {
    var swiftUI: Color { Color(.sRGB, red: Double(r), green: Double(g), blue: Double(b), opacity: Double(a)) }
}

private struct FlyoutAnchorKey: PreferenceKey {
    static var defaultValue: [Flyout: CGRect] = [:]
    static func reduce(value: inout [Flyout: CGRect], nextValue: () -> [Flyout: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Moves its window when dragged. SwiftUI content in a non-activating panel
/// doesn't move the window by its background on its own.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// As the toolbar background fades out, outlines the icons in the window
/// background color so they stay readable over any screen content.
struct SeeThroughHalo: ViewModifier {
    let backgroundOpacity: Double

    func body(content: Content) -> some View {
        let strength = 1 - backgroundOpacity
        content
            .shadow(color: Color(nsColor: .windowBackgroundColor).opacity(strength), radius: 0.8)
            .shadow(color: Color(nsColor: .windowBackgroundColor).opacity(strength * 0.8), radius: 2)
    }
}
