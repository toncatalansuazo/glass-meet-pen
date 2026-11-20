import AppKit
import BrushKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel.shared
    private let settings = AppSettings.shared
    private let capture = CaptureService()
    private(set) var server: RemoteServer?
    private var overlay: OverlayController?
    private var toolbar: ToolbarController?
    private var pairing: PairingWindowController?
    private var approval: ApprovalWindowController?
    private var cancellables: Set<AnyCancellable> = []
    private var lastPermission = ScreenPermission.isGranted

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyDockPolicy(settings.showInDock)

        let server = RemoteServer(model: model, capture: capture)
        self.server = server
        overlay = OverlayController(model: model)
        let toolbar = ToolbarController(model: model, server: server)
        self.toolbar = toolbar
        wirePairingWindows(server)
        wireModelCallbacks(toolbar)
        wireSettings()
        watchScreens()
        watchScreenPermission()
        server.start()
    }

    private func wirePairingWindows(_ server: RemoteServer) {
        let pairing = PairingWindowController(server: server)
        self.pairing = pairing
        server.onShowPairing = { [weak pairing] in pairing?.show() }
        let approval = ApprovalWindowController()
        self.approval = approval
        server.onApprovalRequest = { [weak approval] request, done in
            guard let approval else { done(false); return }
            approval.ask(request, completion: done)
        }
        server.onApprovalCancelled = { [weak approval] in approval?.cancel(id: $0) }
    }

    private func wireModelCallbacks(_ toolbar: ToolbarController) {
        model.onDrawModeChanged = { [weak self] on in
            self?.overlay?.setDrawMode(on)
            self?.server?.drawModeChanged(on)
        }
        model.onToolChanged = { [weak self] source, state in self?.server?.toolChanged(source: source, state: state) }
        model.onDisplayChanged = { [weak self] screen, info in
            self?.overlay?.move(to: screen)
            self?.toolbar?.place(on: screen)
            self?.server?.displayChanged(info)
        }
        model.$toolbarVisible.sink { [weak toolbar] in toolbar?.setVisible($0) }.store(in: &cancellables)
    }

    private func wireSettings() {
        settings.onShowInDockChanged = { [weak self] in self?.applyDockPolicy($0) }
        settings.onHotKeysChanged = { [weak self] in self?.registerHotKeys() }
        registerHotKeys()
    }

    private func watchScreens() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.screensChanged() }
        }
    }

    /// Tells the phone when Screen Recording permission changes.
    private func watchScreenPermission() {
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ScreenPermission.isGranted
                guard now != self.lastPermission else { return }
                self.lastPermission = now
                self.server?.screenPermissionChanged(now)
            }
        }
    }

    private func registerHotKeys() {
        let hk = HotKeyCenter.shared
        hk.unregisterAll()
        hk.register(settings.drawHotKey) { [weak self] in self?.model.toggleDrawMode() }
        hk.register(settings.clearHotKey) { [weak self] in self?.model.clear() }
    }

    private func applyDockPolicy(_ showInDock: Bool) {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    // MARK: Dock

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.toolbarVisible = true
        toolbar?.setVisible(true)
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(model.drawMode ? "Stop Drawing" : "Start Drawing") { [weak self] in self?.model.toggleDrawMode() })
        menu.addItem(ClosureMenuItem("Show Toolbar") { [weak self] in self?.model.toolbarVisible = true })
        menu.addItem(ClosureMenuItem("Clear All") { [weak self] in self?.model.clear() })
        menu.addItem(ClosureMenuItem("Connect iPhone/iPad…") { [weak self] in self?.server?.showPairing() })
        if let coffee = AppSettings.buyMeACoffeeURL {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("☕ Buy Me a Coffee…") { NSWorkspace.shared.open(coffee) })
        }
        return menu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let server else { return .terminateNow }
        server.shutdown {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}
