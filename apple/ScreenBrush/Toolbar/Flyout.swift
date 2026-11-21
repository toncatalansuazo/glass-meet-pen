import AppKit
import BrushKit
import Combine
import SwiftUI

/// The pickers that unfold from a toolbar button.
enum Flyout: Hashable {
    case tools, colors, widths
}

/// Which flyout is open and where its button is. Opens while the pointer is over
/// the button (or on click) and closes shortly after the pointer leaves both.
@MainActor
final class FlyoutState: ObservableObject {
    @Published private(set) var open: Flyout?
    /// Button frames in the toolbar's content coordinates (top-left origin).
    private(set) var anchors: [Flyout: CGRect] = [:]
    private var hoveredButton: Flyout?
    private var hoveringFlyout = false
    private var closeWork: DispatchWorkItem?

    func setAnchor(_ rect: CGRect, for flyout: Flyout) { anchors[flyout] = rect }

    func toggle(_ flyout: Flyout) {
        closeWork?.cancel()
        open = open == flyout ? nil : flyout
    }

    func close() {
        closeWork?.cancel()
        open = nil
    }

    func buttonHover(_ flyout: Flyout, _ inside: Bool) {
        if inside {
            hoveredButton = flyout
            closeWork?.cancel()
            open = flyout
        } else {
            if hoveredButton == flyout { hoveredButton = nil }
            scheduleClose()
        }
    }

    func flyoutHover(_ inside: Bool) {
        hoveringFlyout = inside
        if inside { closeWork?.cancel() } else { scheduleClose() }
    }

    private func scheduleClose() {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hoveredButton == nil, !self.hoveringFlyout else { return }
            self.open = nil
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}

final class FlyoutPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
    }
    override var canBecomeKey: Bool { true }
}

/// Shows the open flyout next to its button, on the side away from the screen edge.
@MainActor
final class FlyoutController {
    private let panel = FlyoutPanel()
    private let view: NSView
    private let state: FlyoutState
    private let model: AppModel
    private weak var toolbar: NSPanel?
    private var subscriptions: Set<AnyCancellable> = []

    init(model: AppModel, state: FlyoutState, toolbar: NSPanel) {
        self.model = model
        self.state = state
        self.toolbar = toolbar
        view = FirstMouseHostingView(rootView: FlyoutView(model: model, state: state))
        panel.contentView = view
        model.$toolbarOpacity
            .sink { [weak self] opacity in
                self?.panel.hasShadow = opacity > 0.5
                self?.panel.invalidateShadow()
            }
            .store(in: &subscriptions)

        state.$open.removeDuplicates()
            .sink { [weak self] open in DispatchQueue.main.async { self?.show(open) } }
            .store(in: &subscriptions)
        model.$toolbarVisible.combineLatest(model.$toolbarPosition)
            .sink { [weak state] _, _ in state?.close() }
            .store(in: &subscriptions)
    }

    private func show(_ flyout: Flyout?) {
        guard let flyout, let toolbar, toolbar.isVisible, let anchor = state.anchors[flyout] else {
            toolbar?.removeChildWindow(panel)
            panel.orderOut(nil)
            return
        }
        let size = view.fittingSize
        let bar = toolbar.frame
        // Button rect in screen coordinates (bottom-left origin).
        let button = NSRect(x: bar.minX + anchor.minX, y: bar.maxY - anchor.maxY, width: anchor.width, height: anchor.height)
        let gap: CGFloat = 4
        var origin: NSPoint
        switch model.toolbarPosition {
        case .bottom: origin = NSPoint(x: button.midX - size.width / 2, y: bar.maxY + gap)
        case .left: origin = NSPoint(x: bar.maxX + gap, y: button.midY - size.height / 2)
        case .right: origin = NSPoint(x: bar.minX - size.width - gap, y: button.midY - size.height / 2)
        }
        if let screen = toolbar.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
            origin.y = min(max(origin.y, screen.minY + 4), screen.maxY - size.height - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent == nil { toolbar.addChildWindow(panel, ordered: .above) }
        panel.orderFrontRegardless()
    }
}

struct FlyoutView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: FlyoutState

    var body: some View {
        content
            .buttonStyle(.plain)
            .modifier(SeeThroughHalo(backgroundOpacity: model.toolbarOpacity))
            .padding(10)
            .background(.regularMaterial.opacity(model.toolbarOpacity), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1 * model.toolbarOpacity)))
            .padding(4)
            .fixedSize()
            .onHover { state.flyoutHover($0) }
    }

    @ViewBuilder private var content: some View {
        switch state.open {
        case .tools: tools
        case .colors: colors
        case .widths: widths
        case nil: EmptyView()
        }
    }

    private var tools: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 4), count: 3), spacing: 4) {
            ForEach(Tool.allCases, id: \.self) { tool in
                Button { model.selectTool(tool); state.close() } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tool.symbolName).font(.title3).frame(height: 22)
                        Text(tool.displayName).font(.caption2).lineLimit(1)
                    }
                    .frame(width: 64, height: 46)
                    .background(model.mouseTool.tool == tool ? Color.primary.opacity(0.15) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .hoverTip(tool.shortcutHelp)
            }
        }
        .fixedSize()
    }

    private var colors: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 4), spacing: 6) {
                ForEach(Array(RGBAColor.palette.enumerated()), id: \.offset) { index, color in
                    Button { model.selectColor(color); state.close() } label: {
                        Circle()
                            .fill(color.swiftUI)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1))
                            .frame(width: 24, height: 24)
                            .padding(3)
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: model.mouseTool.color == color ? 2 : 0))
                    }
                    .hoverTip("Color \(index + 1)")
                }
            }
            .fixedSize()
            HStack(spacing: 6) {
                Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary)
                Slider(value: $model.inkOpacity, in: 0.1...1).controlSize(.small).frame(width: 90)
                Text("\(Int(model.inkOpacity * 100))%").font(.caption).monospacedDigit().frame(width: 34, alignment: .trailing)
            }
            .hoverTip("Ink opacity")
        }
    }

    private var widths: some View {
        HStack(spacing: 4) {
            ForEach(WidthPreset.allCases, id: \.self) { w in
                Button { model.selectWidth(w); state.close() } label: {
                    VStack(spacing: 3) {
                        Circle().fill(Color.primary)
                            .frame(width: CGFloat(w.points) + 2, height: CGFloat(w.points) + 2)
                            .frame(height: 22)
                        Text("\(Int(w.points)) pt").font(.caption2)
                    }
                    .frame(width: 44, height: 46)
                    .background(model.mouseTool.width == w ? Color.primary.opacity(0.15) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
            }
        }
    }
}
