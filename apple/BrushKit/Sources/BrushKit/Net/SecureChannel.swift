import CryptoKit
import Foundation
import Network

public enum ChannelError: Error, Equatable, CustomStringConvertible {
    case authFailed
    case denied
    case locked
    case protocolError(String)
    case closed

    public var description: String {
        switch self {
        case .authFailed: return "This pairing has expired. Pair again from your computer."
        case .denied: return "The pairing was declined on the computer."
        case .locked: return "Too many attempts. Try again in 30 seconds"
        case .protocolError(let s): return "Protocol error: \(s)"
        case .closed: return "Connection closed"
        }
    }
}

/// What a client uses to authenticate.
public enum ClientAuth: Sendable {
    case token(String)
    case confirm(deviceName: String)

    public var mode: AuthMode {
        if case .token = self { return .token }
        return .confirm
    }
}

/// A pairing the user has to allow on the computer.
public struct ConfirmRequest: Sendable {
    public let id: UUID
    /// Already cleaned with `ConfirmRequest.displayName(_:)`.
    public let deviceName: String
    public let code: String
    public let host: String

    public static let maxNameLength = 40

    /// The name a phone sends is untrusted: keep one line of printable text, at most 40 characters.
    public static func displayName(_ raw: String?) -> String {
        let printable = (raw ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }
        let name = String(String.UnicodeScalarView(printable)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Unknown device" : String(name.prefix(maxNameLength))
    }
}

/// How the server checks clients.
public struct ServerAuth: @unchecked Sendable {
    /// The pairing token, as it was when the connection arrived.
    public var token: String
    /// Asks the user to allow a confirm-mode pairing; call the completion with the answer.
    public var approve: (ConfirmRequest, @escaping (Bool) -> Void) -> Void
    /// The connection behind a request closed before the user answered: close the prompt.
    public var cancelApproval: (UUID) -> Void
    public var limiter: LimiterBox

    public init(token: String, approve: @escaping (ConfirmRequest, @escaping (Bool) -> Void) -> Void,
                cancelApproval: @escaping (UUID) -> Void = { _ in }, limiter: LimiterBox) {
        self.token = token; self.approve = approve; self.cancelApproval = cancelApproval; self.limiter = limiter
    }
}

/// A length-prefixed, authenticated, encrypted channel over a TCP `NWConnection`.
/// Wire format: `[UInt32 length][payload]`. During the handshake, payloads are
/// JSON; afterwards each payload is `ChaChaPoly([kind:UInt8][body])`.
/// The handshake is described in docs/protocol.md.
public final class SecureChannel: @unchecked Sendable {
    public enum Role { case client(ClientAuth), server(ServerAuth) }

    public let connection: NWConnection
    private let role: Role
    private let queue: DispatchQueue
    private let callbackQueue: DispatchQueue

    private var sendCipher: FrameCipher?
    private var receiveCipher: FrameCipher?
    private var closed = false
    /// Host whose limiter attempt this connection holds, until the handshake ends.
    private var reservedHost: String?

    /// Client, confirm mode: keys waiting for the user to say the codes match.
    private var keysAwaitingMatch: HandshakeKeys?
    /// Server, confirm mode: the open prompt, the user's answer, and whether the proof checked out.
    private var approvalID: UUID?
    private var approvalAnswer: Bool?
    private var proofVerified = false

    /// How the peer authenticated; set before `onReady`.
    public private(set) var authMode: AuthMode?
    private let lock = NSLock()
    private var _pendingSends = 0

    public var onReady: (() -> Void)?
    /// Client, confirm mode: the 6-digit code to show. Answer with `confirmCode(matches:)`.
    public var onConfirmCode: ((String) -> Void)?
    public var onFrame: ((FrameKind, Data) -> Void)?
    public var onClose: ((ChannelError?) -> Void)?

    public static let maxFrameSize = 16 * 1024 * 1024
    /// Handshake messages are small JSON; anything bigger closes the connection.
    public static let maxHandshakeFrameSize = 4 * 1024
    /// Time allowed for the whole handshake, including the user clicking Allow.
    public static let handshakeTimeout: TimeInterval = 90

    public init(connection: NWConnection, role: Role, callbackQueue: DispatchQueue = .main) {
        self.connection = connection
        self.role = role
        self.queue = DispatchQueue(label: "SecureChannel")
        self.callbackQueue = callbackQueue
    }

    /// Number of frames handed to the network that haven't been fully processed yet.
    public var pendingSends: Int {
        lock.lock(); defer { lock.unlock() }
        return _pendingSends
    }

    public var remoteHost: String {
        if case .hostPort(let host, _) = connection.endpoint { return "\(host)" }
        if case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint { return "\(host)" }
        return "\(connection.endpoint)"
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.beginHandshake()
            case .failed: self.close(.closed)
            case .waiting: self.close(.closed)
            case .cancelled: self.close(nil)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ kind: FrameKind, _ body: Data, completion: ((Bool) -> Void)? = nil) {
        queue.async { [self] in
            guard !closed, sendCipher != nil else { completion?(false); return }
            do {
                let sealed = try sendCipher!.seal(Data([kind.rawValue]) + body)
                lock.lock(); _pendingSends += 1; lock.unlock()
                writeRaw(sealed) { [weak self] ok in
                    guard let self else { return }
                    self.lock.lock(); self._pendingSends -= 1; self.lock.unlock()
                    completion?(ok)
                }
            } catch {
                completion?(false)
            }
        }
    }

    public func send(_ message: some Encodable, completion: ((Bool) -> Void)? = nil) {
        guard let data = try? MessageCodec.encode(message) else { completion?(false); return }
        send(.message, data, completion: completion)
    }

    public func cancel() {
        queue.async { [self] in close(nil) }
    }

    /// Client, confirm mode: the user compared the codes on both screens.
    /// `true` continues the pairing; `false` cancels it.
    public func confirmCode(matches: Bool) {
        queue.async { [self] in
            guard let keys = keysAwaitingMatch else { return }
            keysAwaitingMatch = nil
            if matches { sendClientProof(keys, mode: .confirm) } else { close(nil) }
        }
    }

    // MARK: Handshake

    private func beginHandshake() {
        queue.asyncAfter(deadline: .now() + Self.handshakeTimeout) { [weak self] in
            guard let self, self.receiveCipher == nil else { return }
            self.close(.protocolError("timeout"))
        }
        switch role {
        case .client(let auth): runClient(auth)
        case .server(let auth): runServer(auth)
        }
    }

    // MARK: Client: hello → challenge → (reveal, user says codes match) → proof → result

    private struct ClientHandshake {
        let auth: ClientAuth
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let nonce = Handshake.randomNonce()
        var pub: Data { priv.publicKey.rawRepresentation }
        var mode: AuthMode { auth.mode }
    }

    private func runClient(_ auth: ClientAuth) {
        let hs = ClientHandshake(auth: auth)
        switch auth {
        case .token:
            writeJSON(ClientHello(v: ProtocolInfo.version, mode: .token, nonce: hs.nonce, pub: hs.pub))
        case .confirm(let name):
            writeJSON(ClientHello(v: ProtocolInfo.version, mode: .confirm, nonce: hs.nonce,
                                  commit: Handshake.commitment(to: hs.pub), deviceName: name))
        }
        readJSON(ServerChallenge.self) { [self] in clientHandleChallenge($0, hs) }
    }

    private func clientHandleChallenge(_ challenge: ServerChallenge, _ hs: ClientHandshake) {
        guard !challenge.locked else { close(.locked); return }
        guard let keys = clientKeys(hs, challenge) else { close(.protocolError("key")); return }
        guard hs.mode == .confirm else { sendClientProof(keys, mode: .token); return }
        writeJSON(ClientReveal(pub: hs.pub))
        keysAwaitingMatch = keys
        let code = keys.confirmCode
        callbackQueue.async { [weak self] in self?.onConfirmCode?(code) }
    }

    private func clientKeys(_ hs: ClientHandshake, _ challenge: ServerChallenge) -> HandshakeKeys? {
        guard let serverPub = challenge.pub,
              let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverPub),
              let shared = try? hs.priv.sharedSecretFromKeyAgreement(with: peer) else { return nil }
        var token: String?
        if case .token(let t) = hs.auth { token = t }
        return HandshakeKeys(shared: shared, token: token, mode: hs.mode, clientNonce: hs.nonce,
                             serverNonce: challenge.nonce, clientPub: hs.pub, serverPub: serverPub)
    }

    private func sendClientProof(_ keys: HandshakeKeys, mode: AuthMode) {
        writeJSON(ClientProof(mac: keys.clientProof))
        readJSON(ServerResult.self) { [self] result in
            guard result.ok, let mac = result.mac, keys.isValidServerProof(mac) else {
                close(Self.error(forReason: result.reason)); return
            }
            authMode = mode
            established(send: keys.clientToServer, receive: keys.serverToClient)
        }
    }

    private static func error(forReason reason: String?) -> ChannelError {
        switch reason {
        case "locked": return .locked
        case "denied": return .denied
        default: return .authFailed
        }
    }

    // MARK: Server: hello → challenge → (reveal, prompt) → proof → (Allow) → result

    private struct ServerHandshake {
        let hello: ClientHello
        let auth: ServerAuth
        let host: String
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let nonce = Handshake.randomNonce()
        var pub: Data { priv.publicKey.rawRepresentation }
    }

    private func runServer(_ auth: ServerAuth) {
        let host = remoteHost
        readJSON(ClientHello.self) { [self] in serverHandleHello(ServerHandshake(hello: $0, auth: auth, host: host)) }
    }

    private func serverHandleHello(_ hs: ServerHandshake) {
        guard hs.auth.limiter.begin(hs.host) else {
            writeJSON(ServerChallenge(nonce: hs.nonce, pub: nil, locked: true)) { [self] in close(.locked) }
            return
        }
        reservedHost = hs.host
        guard hs.hello.v == ProtocolInfo.version else { close(.protocolError("version")); return }
        writeJSON(ServerChallenge(nonce: hs.nonce, pub: hs.pub, locked: false))
        switch hs.hello.mode {
        case .token:
            guard let pub = hs.hello.pub, let keys = serverKeys(hs, clientPub: pub) else { rejectClient("auth", hs); return }
            serverReadProof(keys, hs)
        case .confirm:
            readJSON(ClientReveal.self) { [self] in serverHandleReveal($0, hs) }
        }
    }

    private func serverHandleReveal(_ reveal: ClientReveal, _ hs: ServerHandshake) {
        guard let commit = hs.hello.commit, Handshake.verify(Handshake.commitment(to: reveal.pub), expected: commit),
              let keys = serverKeys(hs, clientPub: reveal.pub) else { rejectClient("auth", hs); return }
        // Both screens show the code now; the proof arrives once the user confirms on the phone.
        askUser(keys, hs)
        serverReadProof(keys, hs)
    }

    private func serverKeys(_ hs: ServerHandshake, clientPub: Data) -> HandshakeKeys? {
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientPub),
              let shared = try? hs.priv.sharedSecretFromKeyAgreement(with: peer) else { return nil }
        return HandshakeKeys(shared: shared, token: hs.hello.mode == .token ? hs.auth.token : nil, mode: hs.hello.mode,
                             clientNonce: hs.hello.nonce, serverNonce: hs.nonce, clientPub: clientPub, serverPub: hs.pub)
    }

    private func serverReadProof(_ keys: HandshakeKeys, _ hs: ServerHandshake) {
        readJSON(ClientProof.self) { [self] proof in
            guard keys.isValidClientProof(proof.mac) else { rejectClient("auth", hs); return }
            guard hs.hello.mode == .confirm else { acceptClient(keys, mode: .token); return }
            proofVerified = true
            finishConfirmIfAnswered(keys, hs)
        }
    }

    private func askUser(_ keys: HandshakeKeys, _ hs: ServerHandshake) {
        let request = ConfirmRequest(id: UUID(), deviceName: ConfirmRequest.displayName(hs.hello.deviceName),
                                     code: keys.confirmCode, host: hs.host)
        approvalID = request.id
        callbackQueue.async {
            hs.auth.approve(request) { [weak self] allowed in
                self?.queue.async { [weak self] in self?.userAnswered(allowed, keys, hs) }
            }
        }
    }

    private func userAnswered(_ allowed: Bool, _ keys: HandshakeKeys, _ hs: ServerHandshake) {
        guard !closed, approvalID != nil else { return }
        approvalID = nil
        approvalAnswer = allowed
        finishConfirmIfAnswered(keys, hs)
    }

    /// Confirm mode needs both the user's Allow and a valid proof from the phone.
    private func finishConfirmIfAnswered(_ keys: HandshakeKeys, _ hs: ServerHandshake) {
        guard let answer = approvalAnswer else { return }
        guard answer else { rejectClient("denied", hs); return }
        guard proofVerified else { return }
        acceptClient(keys, mode: .confirm)
    }

    private func acceptClient(_ keys: HandshakeKeys, mode: AuthMode) {
        releaseAttempt(success: true)
        authMode = mode
        writeJSON(ServerResult(ok: true, mac: keys.serverProof, reason: nil))
        established(send: keys.serverToClient, receive: keys.clientToServer)
    }

    private func rejectClient(_ reason: String, _ hs: ServerHandshake) {
        releaseAttempt(success: false)
        let reply = hs.auth.limiter.isLocked(hs.host) ? "locked" : reason
        writeJSON(ServerResult(ok: false, mac: nil, reason: reply)) { [self] in
            close(reason == "denied" ? .denied : .authFailed)
        }
    }

    private func releaseAttempt(success: Bool) {
        guard let host = reservedHost, case .server(let auth) = role else { return }
        reservedHost = nil
        auth.limiter.finish(host, success: success)
    }

    /// Closes the prompt if the connection ends before the user answered.
    private func cancelOpenApproval() {
        guard let id = approvalID, case .server(let auth) = role else { return }
        approvalID = nil
        callbackQueue.async { auth.cancelApproval(id) }
    }

    private func established(send: SymmetricKey, receive: SymmetricKey) {
        sendCipher = FrameCipher(key: send)
        receiveCipher = FrameCipher(key: receive)
        callbackQueue.async { [weak self] in self?.onReady?() }
        receiveLoop()
    }

    private func receiveLoop() {
        readRaw { [weak self] data in
            guard let self, var cipher = self.receiveCipher else { return }
            do {
                let plain = try cipher.open(data)
                self.receiveCipher = cipher
                guard let kindByte = plain.first, let kind = FrameKind(rawValue: kindByte) else {
                    self.close(.protocolError("frame kind")); return
                }
                let body = plain.dropFirst()
                self.callbackQueue.async { [weak self] in self?.onFrame?(kind, Data(body)) }
                self.receiveLoop()
            } catch {
                self.close(.protocolError("decrypt"))
            }
        }
    }

    // MARK: Raw framing

    private func writeJSON<T: Encodable>(_ value: T, then: (() -> Void)? = nil) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        writeRaw(data) { _ in self.queue.async { then?() } }
    }

    private func readJSON<T: Decodable>(_ type: T.Type, handler: @escaping (T) -> Void) {
        readRaw(maxLength: Self.maxHandshakeFrameSize) { [weak self] data in
            guard let self else { return }
            guard let value = try? JSONDecoder().decode(T.self, from: data) else {
                self.close(.protocolError("handshake")); return
            }
            handler(value)
        }
    }

    private func writeRaw(_ payload: Data, completion: @escaping (Bool) -> Void) {
        var header = ByteWriter()
        header.u32(UInt32(payload.count))
        connection.send(content: header.data + payload, completion: .contentProcessed { error in
            completion(error == nil)
        })
    }

    private func readRaw(maxLength: Int = SecureChannel.maxFrameSize, _ handler: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard error == nil, let data, data.count == 4 else { self.close(isComplete ? nil : .closed); return }
            var r = ByteReader(data)
            let length = Int(r.u32() ?? 0)
            guard length > 0, length <= maxLength else { self.close(.protocolError("length")); return }
            self.connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] body, _, _, error in
                guard let self else { return }
                guard error == nil, let body, body.count == length else { self.close(.closed); return }
                handler(body)
            }
        }
    }

    private func close(_ error: ChannelError?) {
        guard !closed else { return }
        closed = true
        releaseAttempt(success: false) // a handshake abandoned halfway counts as a failed attempt
        cancelOpenApproval()
        connection.cancel()
        callbackQueue.async { [weak self] in self?.onClose?(error) }
    }
}

/// Thread-safe wrapper so the listener and its connections can share one limiter.
public final class LimiterBox: @unchecked Sendable {
    private var limiter: FailureLimiter
    private let lock = NSLock()
    public init(_ limiter: FailureLimiter = FailureLimiter()) { self.limiter = limiter }
    public func isLocked(_ host: String) -> Bool { lock.lock(); defer { lock.unlock() }; return limiter.isLocked(host) }
    public func begin(_ host: String) -> Bool { lock.lock(); defer { lock.unlock() }; return limiter.begin(host) }
    public func finish(_ host: String, success: Bool) { lock.lock(); limiter.finish(host, success: success); lock.unlock() }
}

extension NWParameters {
    /// TCP with Nagle disabled, for low-latency stroke streaming, over infrastructure or peer-to-peer Wi‑Fi.
    public static func lowLatencyTCP() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.connectionTimeout = 6
        let params = NWParameters(tls: nil, tcp: tcp)
        // Peer-to-peer Wi‑Fi (AWDL, as AirDrop uses): works across different networks,
        // on networks with client isolation, or with no Wi‑Fi network at all.
        params.includePeerToPeer = true
        params.serviceClass = .responsiveData
        return params
    }
}
