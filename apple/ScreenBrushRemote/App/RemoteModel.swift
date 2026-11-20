import BrushKit
import Combine
import Network
import UIKit

enum CanvasMode: String { case navigate, paint }

/// App state for Glasspen Remote: pairing, connection, and the mirrored drawing.
@MainActor
final class RemoteModel: ObservableObject {
    enum Phase: Equatable {
        case pairing                 // choose a Mac or scan the QR code
        case connecting(String)      // Mac name
        case connected
        case reconnecting(String)
    }

    @Published private(set) var phase: Phase = .pairing
    @Published var message: String?
    @Published private(set) var macName = ""
    @Published private(set) var display = DisplayInfo(id: 0, name: "", width: 16, height: 10)
    @Published private(set) var macDrawMode = false
    @Published private(set) var screenPermission = true
    @Published var toolState = ToolState(tool: .pen, color: RGBAColor.palette[4], width: .medium) {
        didSet { if toolState != oldValue { client?.send(.setTool(toolState)) } }
    }
    @Published var mode: CanvasMode = .navigate
    @Published private(set) var hasVideo = false
    /// During a new pairing: the code both screens show, and whether the user said it matches.
    @Published private(set) var confirmCode: String?
    @Published private(set) var codeConfirmed = false
    /// A pairing link opened from outside the app (Camera, Safari, …), waiting for the user's OK.
    @Published var pendingLink: PairingLink?

    let isPad = UIDevice.current.userInterfaceIdiom == .pad
    let sourceID: SourceID
    private(set) var mirror = DocumentMirror()

    // Canvas hooks (UIKit side)
    var onDocumentChanged: (() -> Void)?
    var onVideo: ((VideoPacket) -> Void)?
    var onDetail: ((DetailPacket?) -> Void)?
    var onFitRequested: (() -> Void)?
    var onDisplayChanged: (() -> Void)?
    var onVideoReset: (() -> Void)?

    private var client: RemoteClient?
    private var retryAttempt = 0
    private var retryWork: DispatchWorkItem?
    private var pathMonitor: NWPathMonitor?
    private var lastPathStatus: NWPath.Status?

    init() {
        let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        sourceID = SourceID("device:\(id)")
        // Pencil-first on iPad: paint mode by default.
        if isPad { mode = .paint }
        startPathMonitor()
    }

    var deviceName: String { UIDevice.current.name }

    // MARK: Pairing entry points

    /// Reconnect to the last Mac if we have a remembered token.
    func resumeIfPossible() {
        guard client == nil, case .pairing = phase, let saved = Keychain.load() else { return }
        connect(target: saved.target, auth: .token(saved.token), name: saved.macName)
    }

    func pair(with link: PairingLink) {
        // Prefer Bonjour; fall back to the address in the QR if the service isn't resolvable.
        let target: MacTarget = .service(name: link.serviceName)
        Keychain.save(SavedPairing(target: target, token: link.token, macName: link.serviceName))
        fallbackHost = link.host.flatMap { h in link.port.map { MacTarget.hostPort(host: h, port: $0) } }
        connect(target: target, auth: .token(link.token), name: link.serviceName)
    }

    /// New pairing without the QR code: the user confirms a code on the Mac.
    func pair(target: MacTarget) {
        fallbackHost = nil
        connect(target: target, auth: .confirm(deviceName: deviceName), name: target.displayName)
    }

    /// The user checked that the phone and the Mac show the same code.
    func codesMatch() {
        codeConfirmed = true
        client?.confirmCode(matches: true)
    }

    /// Stops a pairing that is waiting for the user or for Allow on the Mac.
    func cancelPairing() {
        disconnect()
        phase = .pairing
    }

    /// Links from other apps could replace the saved Mac, so the user confirms them first.
    func handle(url: URL) {
        pendingLink = PairingLink(url: url)
    }

    func acceptPendingLink() {
        guard let link = pendingLink else { return }
        pendingLink = nil
        pair(with: link)
    }

    private var fallbackHost: MacTarget?

    func forgetMac() {
        disconnect()
        Keychain.delete()
        phase = .pairing
    }

    func disconnect() {
        retryWork?.cancel()
        client?.stop()
        resetConnectionState()
    }

    // MARK: Connection

    private var lastAttempt: (target: MacTarget, auth: ClientAuth, name: String)?

    private func connect(target: MacTarget, auth: ClientAuth, name: String) {
        lastAttempt = (target, auth, name)
        retryWork?.cancel()
        client?.stop()
        message = nil
        if case .reconnecting = phase {} else { phase = .connecting(name) }

        let c = RemoteClient(target: target, auth: auth, sourceID: sourceID,
                             deviceName: deviceName, isPad: isPad)
        client = c
        c.onConfirmCode = { [weak self] in self?.confirmCode = $0 }
        c.onReady = { [weak self] in
            self?.retryAttempt = 0
            self?.client?.send(.setTool(self?.toolState ?? ToolState()))
        }
        c.onMessage = { [weak self] in self?.handle($0, target: target) }
        c.onVideo = { [weak self] packet in
            if self?.hasVideo == false { self?.hasVideo = true }
            self?.onVideo?(packet)
        }
        c.onDetail = { [weak self] in self?.onDetail?($0) }
        c.onClose = { [weak self] error in
            self?.connectionClosed(error)
        }
        c.start()
    }

    private func connectionClosed(_ error: ChannelError?) {
        resetConnectionState()
        guard let last = lastAttempt else { phase = .pairing; return }
        if case .authFailed? = error, case .token = last.auth { Keychain.delete() }
        if let text = Self.failureMessage(error, auth: last.auth) {
            message = text
            phase = .pairing
            return
        }
        if case .pairing = phase { return } // the user cancelled
        if case .confirm = last.auth {
            // Never retry a pairing that needs Allow: the Mac would ask again by itself.
            message = "The connection was lost before the pairing finished. Try again."
            phase = .pairing
            return
        }
        retry(last)
    }

    private func resetConnectionState() {
        client = nil
        hasVideo = false
        confirmCode = nil
        codeConfirmed = false
        updateIdleTimer()
    }

    /// The message for errors that end the attempt; `nil` when a retry may help.
    private static func failureMessage(_ error: ChannelError?, auth: ClientAuth) -> String? {
        switch error {
        case .authFailed?:
            return auth.mode == .token ? ChannelError.authFailed.description : "Pairing failed. Try again."
        case .denied?, .locked?: return error?.description
        default: return nil
        }
    }

    /// Network blip or Mac unreachable: retry with backoff.
    private func retry(_ last: (target: MacTarget, auth: ClientAuth, name: String)) {
        var retryTarget = last.target
        if let fallback = fallbackHost, case .service = last.target, retryAttempt >= 2, retryAttempt % 2 == 0 {
            retryTarget = fallback // Bonjour not resolving: try the address from the QR code
        }
        scheduleRetry { [weak self] in self?.connect(target: retryTarget, auth: last.auth, name: last.name) }
        phase = .reconnecting(last.name)
    }

    private func scheduleRetry(_ action: @escaping () -> Void) {
        let delays: [Double] = [0.5, 1, 2, 4, 5]
        let delay = delays[min(retryAttempt, delays.count - 1)]
        retryAttempt += 1
        let work = DispatchWorkItem(block: action)
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Called when the app returns to the foreground or the network changes.
    func reconnectNow() {
        switch phase {
        case .reconnecting:
            guard let last = lastAttempt else { return }
            retryWork?.cancel()
            retryAttempt = 0
            connect(target: last.target, auth: last.auth, name: last.name)
        case .pairing:
            resumeIfPossible()
        default:
            break
        }
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                defer { self.lastPathStatus = path.status }
                if path.status == .satisfied, self.lastPathStatus != nil, self.lastPathStatus != .satisfied {
                    self.reconnectNow()
                }
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    // MARK: Messages from the Mac

    private func handle(_ message: ServerMessage, target: MacTarget) {
        if let event = message.documentEvent { applyDocumentEvent(event); return }
        switch message {
        case .welcome(let w): applyWelcome(w, target: target)
        case .pairingToken(let token): storePairingToken(token, target: target)
        case .drawModeChanged(let on):
            macDrawMode = on
        case .displayChanged(let info): applyDisplayChange(info)
        case .screenPermission(let granted):
            screenPermission = granted
        case .sessionEnded(let reason):
            disconnect()
            self.message = reason
            phase = .pairing
        default:
            break
        }
    }

    private func applyDocumentEvent(_ event: DocumentEvent) {
        mirror.apply(event)
        if case .committedChanged(let added, _) = event, let local = localStroke, added.contains(where: { $0.id == local.id }) {
            localStroke = nil
        }
        onDocumentChanged?()
    }

    private func applyWelcome(_ w: Welcome, target: MacTarget) {
        macName = w.macName
        let displayChanged = w.display != display
        display = w.display
        mirror.reset(snapshot: w.snapshot)
        macDrawMode = w.macDrawMode
        screenPermission = w.screenPermission
        phase = .connected
        message = nil
        confirmCode = nil
        codeConfirmed = false
        if displayChanged { onDisplayChanged?() }
        onDocumentChanged?()
        updateIdleTimer()
        // Remember the Mac for silent reconnects (token mode keeps the existing token).
        if let saved = Keychain.load(), saved.target == target || saved.macName == w.macName {
            Keychain.save(SavedPairing(target: target, token: saved.token, macName: w.macName))
        }
    }

    /// Only a pairing the user just confirmed may replace the saved token.
    private func storePairingToken(_ token: String, target: MacTarget) {
        guard let last = lastAttempt, last.auth.mode.receivesPairingToken else { return }
        let name = macName.isEmpty ? target.displayName : macName
        Keychain.save(SavedPairing(target: target, token: token, macName: name))
        lastAttempt = (target, .token(token), name)
    }

    private func applyDisplayChange(_ info: DisplayInfo) {
        display = info
        onDetail?(nil)
        onVideoReset?()
        onDisplayChanged?()
        onDocumentChanged?()
    }

    // MARK: Intents to the Mac

    /// The stroke this device is drawing right now (rendered locally for zero latency).
    private(set) var localStroke: Stroke?

    func beginLocalStroke(_ stroke: Stroke) {
        localStroke = stroke
        client?.send(.strokeBegin(stroke))
        onDocumentChanged?()
    }

    func appendLocal(points: [StrokePoint], send: Bool) {
        guard var s = localStroke, !points.isEmpty else { return }
        if s.tool.isShape {
            s.points = [s.points[0], points[points.count - 1]]
        } else {
            s.points.append(contentsOf: points)
        }
        localStroke = s
        if send { client?.send(.strokeAppend(id: s.id, points: points)) }
    }

    func sendAppend(id: UUID, points: [StrokePoint]) {
        client?.send(.strokeAppend(id: id, points: points))
    }

    func endLocalStroke() {
        guard let s = localStroke else { return }
        client?.send(.strokeEnd(id: s.id))
        // Keep drawing it locally until the Mac's commit arrives; drop it if that never happens.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.localStroke?.id == s.id { self?.localStroke = nil; self?.onDocumentChanged?() }
        }
    }

    func cancelLocalStroke() {
        guard let s = localStroke else { return }
        localStroke = nil
        client?.send(.strokeCancel(id: s.id))
        onDocumentChanged?()
    }

    func erase(points: [StrokePoint]) {
        let radius = (toolState.width.points * 2 + 6) / max(display.width, 1)
        client?.send(.erase(points: points, radius: radius))
    }

    func undo() { client?.send(.undo) }
    func redo() { client?.send(.redo) }
    func clear() { client?.send(.clear) }
    func requestFit() { onFitRequested?() }
    func requestKeyframe() { client?.send(.requestKeyframe) }

    func setMacDrawMode(_ on: Bool) {
        macDrawMode = on // optimistic; corrected by drawModeChanged
        client?.send(.setMacDrawMode(on))
    }

    func sendViewport(_ rect: CGRect?, pixels: CGSize) {
        client?.send(.viewport(rect: rect.map(NormRect.init), pixelWidth: Int(pixels.width), pixelHeight: Int(pixels.height)))
    }

    // MARK: Lifecycle

    func scenePhaseChanged(active: Bool) {
        if active {
            reconnectNow()
            onVideoReset?()
            requestKeyframe()
        }
        updateIdleTimer(active: active)
    }

    private func updateIdleTimer(active: Bool? = nil) {
        let isActive = active ?? (UIApplication.shared.applicationState == .active)
        UIApplication.shared.isIdleTimerDisabled = isActive && phase == .connected
    }
}
