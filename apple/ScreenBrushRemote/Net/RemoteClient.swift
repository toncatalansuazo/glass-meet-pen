import BrushKit
import Foundation
import Network

/// Where to reach the Mac: a Bonjour service (preferred) or a manual host:port.
enum MacTarget: Codable, Hashable {
    case service(name: String)
    case hostPort(host: String, port: UInt16)

    var endpoint: NWEndpoint {
        switch self {
        case .service(let name):
            return .service(name: name, type: ProtocolInfo.bonjourType, domain: "local.", interface: nil)
        case .hostPort(let host, let port):
            return .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 7878)
        }
    }

    var displayName: String {
        switch self {
        case .service(let name): return name
        case .hostPort(let host, let port): return "\(host):\(port)"
        }
    }
}

/// Owns the control + video channels to one Mac.
@MainActor
final class RemoteClient {
    let target: MacTarget
    /// Starts as `.confirm` for a new pairing; switches to `.token` once the Mac sends one.
    private var auth: ClientAuth
    private let sourceID: SourceID
    private let deviceName: String
    private let isPad: Bool

    private var control: SecureChannel?
    private var video: SecureChannel?
    private var closed = false

    var onMessage: ((ServerMessage) -> Void)?
    var onVideo: ((VideoPacket) -> Void)?
    var onDetail: ((DetailPacket) -> Void)?
    var onReady: (() -> Void)?
    /// Confirm mode: the code to show. Answer with `confirmCode(matches:)`.
    var onConfirmCode: ((String) -> Void)?
    var onClose: ((ChannelError?) -> Void)?

    init(target: MacTarget, auth: ClientAuth, sourceID: SourceID, deviceName: String, isPad: Bool) {
        self.target = target; self.auth = auth
        self.sourceID = sourceID; self.deviceName = deviceName; self.isPad = isPad
    }

    func start() {
        let channel = makeChannel()
        control = channel
        channel.onReady = { [weak self] in self?.controlReady() }
        channel.onConfirmCode = { [weak self] in self?.onConfirmCode?($0) }
        channel.onFrame = { [weak self] kind, data in self?.handleControlFrame(kind, data) }
        channel.onClose = { [weak self] error in
            guard let self, !self.closed else { return }
            self.stop()
            self.onClose?(error)
        }
        channel.start()
    }

    /// The user compared the codes on the phone and the Mac.
    func confirmCode(matches: Bool) {
        control?.confirmCode(matches: matches)
    }

    private func controlReady() {
        control?.send(ClientMessage.hello(version: ProtocolInfo.version, role: .control, deviceName: deviceName,
                                          sourceID: sourceID, isPad: isPad))
        onReady?()
        // A new pairing gets the token on the control channel first; video then uses it,
        // so the Mac doesn't ask the user to allow a second connection.
        if case .token = auth { startVideo() }
    }

    private func handleControlFrame(_ kind: FrameKind, _ data: Data) {
        guard kind == .message, let message = try? MessageCodec.decode(ServerMessage.self, from: data) else { return }
        if case .pairingToken(let token) = message { adoptToken(token) }
        onMessage?(message)
    }

    private func adoptToken(_ token: String) {
        guard auth.mode.receivesPairingToken else { return }
        auth = .token(token)
        startVideo()
    }

    private func startVideo() {
        let channel = makeChannel()
        video = channel
        channel.onReady = { [weak self, weak channel] in
            guard let self, let channel else { return }
            channel.send(ClientMessage.hello(version: ProtocolInfo.version, role: .video, deviceName: self.deviceName,
                                             sourceID: self.sourceID, isPad: self.isPad))
            self.send(.requestKeyframe)
        }
        channel.onFrame = { [weak self] kind, data in
            switch kind {
            case .video: if let p = VideoPacket(decoding: data) { self?.onVideo?(p) }
            case .detail: if let p = DetailPacket(decoding: data) { self?.onDetail?(p) }
            case .message: break
            }
        }
        channel.onClose = { [weak self] _ in
            // Video loss alone: retry the video channel while control is alive.
            guard let self, !self.closed else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.closed else { return }
                self.startVideo()
            }
        }
        channel.start()
    }

    private func makeChannel() -> SecureChannel {
        let connection = NWConnection(to: target.endpoint, using: .lowLatencyTCP())
        return SecureChannel(connection: connection, role: .client(auth))
    }

    func send(_ message: ClientMessage) {
        control?.send(message)
    }

    func stop() {
        closed = true
        control?.cancel()
        video?.cancel()
        control = nil
        video = nil
    }
}

/// Browses the local network for Macs running Glasspen Meet.
@MainActor
final class MacBrowser: ObservableObject {
    @Published private(set) var macs: [String] = []
    @Published private(set) var permissionDenied = false
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true // also find Macs over peer-to-peer Wi‑Fi
        let browser = NWBrowser(for: .bonjour(type: ProtocolInfo.bonjourType, domain: "local."), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { result -> String? in
                if case .service(let name, _, _, _) = result.endpoint { return name }
                return nil
            }
            Task { @MainActor in self?.macs = Array(Set(names)).sorted() }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .waiting(let error), .failed(let error):
                    // The Local Network permission prompt was denied (DNS-SD policy error).
                    if case .dns(let code) = error, code == -65570 { self?.permissionDenied = true }
                case .ready:
                    self?.permissionDenied = false
                default: break
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
