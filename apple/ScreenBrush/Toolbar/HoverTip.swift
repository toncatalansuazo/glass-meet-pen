import AppKit
import SwiftUI

extension View {
    /// A tooltip that also shows while another app is active. The toolbar is a
    /// non-activating panel, and AppKit's own tooltips (`.help`) only appear when
    /// this app is frontmost, which it rarely is.
    func hoverTip(_ text: String) -> some View {
        overlay(HoverTipArea(text: text))
            .accessibilityLabel(text)
    }
}

/// Tracks the pointer over its frame without taking clicks, and asks the shared
/// tip window to show `text` next to it.
private struct HoverTipArea: NSViewRepresentable {
    let text: String

    final class TrackingView: NSView {
        var text = ""

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) {
            guard let window else { return }
            HoverTipWindow.shared.schedule(text, for: window.convertToScreen(convert(bounds, to: nil)), owner: self)
        }

        override func mouseExited(with event: NSEvent) { HoverTipWindow.shared.hide(owner: self) }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { HoverTipWindow.shared.hide(owner: self) }
        }
    }

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.text = text
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.text = text
        HoverTipWindow.shared.update(text, owner: view)
    }
}

/// One small floating label shared by every hover tip, placed on the side of the
/// control that faces the middle of the screen.
@MainActor
final class HoverTipWindow {
    static let shared = HoverTipWindow()

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private weak var owner: NSView?
    private var pending: DispatchWorkItem?

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -4),
        ])
        panel.contentView = background
    }

    func schedule(_ text: String, for rect: NSRect, owner: NSView) {
        pending?.cancel()
        self.owner = owner
        let work = DispatchWorkItem { [weak self] in self?.show(text, for: rect) }
        pending = work
        // Quick once a tip is already up, so moving along the toolbar feels live.
        DispatchQueue.main.asyncAfter(deadline: .now() + (panel.isVisible ? 0.05 : 0.5), execute: work)
    }

    func update(_ text: String, owner: NSView) {
        guard self.owner === owner, panel.isVisible else { return }
        label.stringValue = text
        resize(keepingCenterOf: panel.frame)
    }

    func hide(owner: NSView) {
        guard self.owner === owner else { return }
        pending?.cancel()
        self.owner = nil
        // Leave a moment for the pointer to reach the next button before hiding.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.owner == nil else { return }
            self.panel.orderOut(nil)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func show(_ text: String, for rect: NSRect) {
        label.stringValue = text
        let size = panel.contentView?.fittingSize ?? .zero
        let gap: CGFloat = 8
        var origin: NSPoint
        switch AppModel.shared.toolbarPosition {
        case .bottom: origin = NSPoint(x: rect.midX - size.width / 2, y: rect.maxY + gap)
        case .left: origin = NSPoint(x: rect.maxX + gap, y: rect.midY - size.height / 2)
        case .right: origin = NSPoint(x: rect.minX - size.width - gap, y: rect.midY - size.height / 2)
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) })?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
            origin.y = min(max(origin.y, screen.minY + 4), screen.maxY - size.height - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    private func resize(keepingCenterOf frame: NSRect) {
        let size = panel.contentView?.fittingSize ?? frame.size
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
    }
}
