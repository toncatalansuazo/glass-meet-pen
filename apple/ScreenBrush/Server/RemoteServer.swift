import AppKit
import BrushKit
import Network

/// Bonjour-advertised listener for the Glasspen Remote app. One phone at a
/// time; each phone opens a control channel and a video channel.
@MainActor
final class RemoteServer: ObservableObject {
    @Published private(set) var secret = PairingSecret.generate()
    @Published private(set) var port: UInt16 = 0
    @Published private(set) var listenerError: String?
    @Published private(set) var connectedName: String?
    @Published private(set) var connectedIsPad = false
    @Published private(set) var lanAddress: String?

    let serviceName: String = Host.current().localizedName ?? "Mac"

    private let model: AppModel
    private let capture: CaptureService
    private var listener: NWListener?
    private let limiter = LimiterBox()

    /// At most this many connections may be mid-handshake at once; extra ones are dropped.
    private static let maxPending = 16

    private struct Session {
        var control: SecureChannel
        var video: SecureChannel?
        var sourceID: SourceID
        var deviceName: String
        var isPad: Bool
        var toolState: ToolState
    }

    /// Connections still in the handshake; held strongly until hello or close.
    private var pending: [ObjectIdentifier: SecureChannel] = [:]
    private var session: Session?
    /// Live stroke IDs owned by the phone, so we don't echo its own live stroke back.
    private var phoneLiveIDs: Set<UUID> = []
    private var lastToolStates: [SourceID: ToolState] = [:]

    var onShowPairing: (() -> Void)?
    /// Shows the "Allow this device?" prompt; the completion gets the user's answer.
    var onApprovalRequest: ((ConfirmRequest, @escaping (Bool) -> Void) -> Void)?
    /// Closes the prompt for a request whose connection went away.
    var onApprovalCancelled: ((UUID) -> Void)?
    private var approvalOpen = false

    init(model: AppModel, capture: CaptureService) {
        self.model = model
        self.capture = capture
        lanAddress = Self.currentLANAddress()

        model.addDocumentListener { [weak self] event in self?.broadcast(event) }
        capture.onPermissionDenied = { [weak self] in
            self?.send(.screenPermission(granted: false))
            ScreenPermission.promptIfNeeded()
        }
    }

    // MARK: Listener

    func start() {
        startListener(port: ProtocolInfo.defaultPort)
    }

    private func startListener(port requested: UInt16?) {
        do {
            let nwPort = requested.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
            let listener = try NWListener(using: .lowLatencyTCP(), on: nwPort)
            listener.service = NWListener.Service(name: serviceName, type: ProtocolInfo.bonjourType)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.port = listener.port?.rawValue ?? 0
                        self.listenerError = nil
                        self.lanAddress = Self.currentLANAddress()
                    case .failed(let error):
                        listener.cancel()
                        if requested != nil {
                            self.startListener(port: nil) // default port busy: let the system pick one
                        } else {
                            self.listenerError = error.localizedDescription
                        }
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            if requested != nil { startListener(port: nil) } else { listenerError = error.localizedDescription }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard pending.count < Self.maxPending else { connection.cancel(); return }
        // The token is copied now; Reset pairing cancels pending handshakes anyway.
        let auth = ServerAuth(token: secret.token, approve: { [weak self] request, done in
            Task { @MainActor in
                guard let self else { done(false); return }
                self.requestApproval(request, done)
            }
        }, cancelApproval: { [weak self] id in
            Task { @MainActor in self?.onApprovalCancelled?(id) }
        }, limiter: limiter)
        let channel = SecureChannel(connection: connection, role: .server(auth))
        pending[ObjectIdentifier(channel)] = channel

        channel.onFrame = { [weak self, weak channel] kind, data in
            guard let self, let channel, kind == .message,
                  let message = try? MessageCodec.decode(ClientMessage.self, from: data) else { return }
            self.handle(message, from: channel)
        }
        channel.onClose = { [weak self, weak channel] _ in
            guard let self, let channel else { return }
            self.pending[ObjectIdentifier(channel)] = nil
            self.channelClosed(channel)
        }
        channel.start()
    }

    // MARK: Messages

    private func handle(_ message: ClientMessage, from channel: SecureChannel) {
        if case .hello(let version, let role, let name, let sourceID, let isPad) = message {
            guard version == ProtocolInfo.version else { channel.cancel(); return }
            let mode = channel.authMode
            pending[ObjectIdentifier(channel)] = nil
            switch role {
            case .control: attachControl(channel, name: name, sourceID: sourceID, isPad: isPad, mode: mode)
            case .video: attachVideo(channel, sourceID: sourceID)
            }
            return
        }
        guard let session, session.control === channel else { return }
        let src = session.sourceID

        switch message {
        case .hello: break
        case .strokeBegin(let stroke):
            guard stroke.sourceID == src else { return }
            phoneLiveIDs.insert(stroke.id)
            model.begin(stroke)
        case .strokeAppend(let id, let points):
            model.append(source: src, id: id, points: points)
        case .strokeEnd(let id):
            model.end(source: src, id: id)
            phoneLiveIDs.remove(id)
        case .strokeCancel(let id):
            model.cancel(source: src, id: id)
            phoneLiveIDs.remove(id)
        case .erase(let points, let radius):
            model.erase(source: src, points: points, radius: radius)
        case .undo: model.undo(source: src)
        case .redo: model.redo(source: src)
        case .clear: model.clear(source: src)
        case .setTool(let state):
            self.session?.toolState = state
            lastToolStates[src] = state
            model.setPhoneTool(state, source: src)
        case .setMacDrawMode(let on):
            model.setDrawMode(on)
        case .viewport(let rect, let w, let h):
            capture.setViewport(rect?.cgRect, pixels: CGSize(width: w, height: h))
        case .requestKeyframe:
            capture.requestKeyframe()
        case .ping(let t):
            send(.pong(sentAt: t))
        }
    }

    private func attachControl(_ channel: SecureChannel, name: String, sourceID: SourceID, isPad: Bool, mode: AuthMode?) {
        if let old = session {
            // Single active phone: the newly paired device takes over.
            old.control.send(ServerMessage.sessionEnded(reason: "Another device connected"))
            let oldControl = old.control, oldVideo = old.video
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { oldControl.cancel(); oldVideo?.cancel() }
            capture.stop()
            model.cancel(source: old.sourceID)
        }
        let tool = lastToolStates[sourceID] ?? ToolState(tool: .pen, color: RGBAColor.palette[4], width: .medium)
        session = Session(control: channel, video: nil, sourceID: sourceID, deviceName: name, isPad: isPad, toolState: tool)
        connectedName = name
        connectedIsPad = isPad
        model.phoneConnected(name: name)
        model.setPhoneTool(tool, source: sourceID)

        let welcome = Welcome(macName: serviceName, display: model.display, snapshot: model.document.orderedStrokes,
                              toolState: tool, macDrawMode: model.drawMode, screenPermission: CaptureService.hasPermission)
        channel.send(ServerMessage.welcome(welcome))
        if mode?.receivesPairingToken == true {
            channel.send(ServerMessage.pairingToken(secret.token))
        }
        if !CaptureService.hasPermission { ScreenPermission.promptIfNeeded() }
    }

    private func attachVideo(_ channel: SecureChannel, sourceID: SourceID) {
        guard var s = session, s.sourceID == sourceID else { channel.cancel(); return }
        s.video?.cancel()
        s.video = channel
        session = s
        capture.start(displayID: model.display.id, channel: channel)
    }

    private func channelClosed(_ channel: SecureChannel) {
        guard let s = session else { return }
        if s.control === channel {
            s.video?.cancel()
            capture.stop()
            model.cancel(source: s.sourceID)
            phoneLiveIDs.removeAll()
            session = nil
            connectedName = nil
            model.phoneConnected(name: nil)
        } else if s.video === channel {
            capture.stop()
            session?.video = nil
        }
    }

    // MARK: Outgoing

    private func send(_ message: ServerMessage) {
        session?.control.send(message)
    }

    private func broadcast(_ event: DocumentEvent) {
        guard session != nil else { return }
        switch event {
        case .liveBegan(let s) where phoneLiveIDs.contains(s.id): return
        case .liveUpdated(let id, _, _) where phoneLiveIDs.contains(id): return
        case .liveCancelled(let id) where phoneLiveIDs.contains(id):
            // The Mac may cancel a phone stroke (e.g. clear); tell the phone.
            phoneLiveIDs.remove(id)
        default: break
        }
        send(ServerMessage(event))
    }

    func toolChanged(source: SourceID, state: ToolState) {
        send(.toolChanged(source: source, state: state))
    }

    func drawModeChanged(_ on: Bool) { send(.drawModeChanged(on)) }

    func displayChanged(_ info: DisplayInfo) {
        send(.displayChanged(info))
        capture.switchDisplay(to: info.id)
    }

    func screenPermissionChanged(_ granted: Bool) { send(.screenPermission(granted: granted)) }

    // MARK: Pairing

    func showPairing() { onShowPairing?() }

    /// One prompt at a time: a second request while one is open is declined.
    private func requestApproval(_ request: ConfirmRequest, _ done: @escaping (Bool) -> Void) {
        guard !approvalOpen, let onApprovalRequest else { done(false); return }
        approvalOpen = true
        onApprovalRequest(request) { [weak self] allowed in
            self?.approvalOpen = false
            done(allowed)
        }
    }

    /// New token; drops the connected phone.
    func resetPairing() {
        secret = PairingSecret.generate()
        if let s = session {
            s.control.send(ServerMessage.sessionEnded(reason: "Pairing was reset on the Mac"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { s.control.cancel(); s.video?.cancel() }
        }
        for channel in pending.values { channel.cancel() }
    }

    /// Notifies the phone that the Mac app is quitting.
    func shutdown(completion: @escaping () -> Void) {
        guard let s = session else { listener?.cancel(); completion(); return }
        s.control.send(ServerMessage.sessionEnded(reason: "Glasspen Meet was closed on the Mac")) { _ in
            DispatchQueue.main.async { completion() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { completion() }
    }

    var pairingURL: URL {
        secret.pairingURL(serviceName: serviceName, host: lanAddress, port: port)
    }

    static func currentLANAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var candidates: [(String, String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            candidates.append((name, String(cString: host)))
        }
        // Prefer Wi‑Fi/Ethernet (en*) over VPN/bridge interfaces.
        return (candidates.first { $0.0.hasPrefix("en") } ?? candidates.first)?.1
    }
}
