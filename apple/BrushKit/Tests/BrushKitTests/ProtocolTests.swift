import CryptoKit
import Network
import XCTest
@testable import BrushKit

final class ProtocolTests: XCTestCase {
    func testClientMessagesRoundTrip() throws {
        let s = Stroke(sourceID: SourceID("phone:x"), tool: .arrow, color: RGBAColor.palette[4], width: 0.004,
                       points: [StrokePoint(x: 0.1, y: 0.2, p: 0.5)])
        let messages: [ClientMessage] = [
            .hello(version: 1, role: .control, deviceName: "iPhone", sourceID: s.sourceID, isPad: false),
            .strokeBegin(s), .strokeAppend(id: s.id, points: s.points), .strokeEnd(id: s.id),
            .strokeCancel(id: s.id), .erase(points: s.points, radius: 0.01), .undo, .redo, .clear,
            .setTool(ToolState(tool: .ellipse, color: RGBAColor.palette[3], width: .bold)),
            .setMacDrawMode(true), .viewport(rect: NormRect(x: 0.1, y: 0.1, w: 0.2, h: 0.2), pixelWidth: 1170, pixelHeight: 760),
            .viewport(rect: nil, pixelWidth: 0, pixelHeight: 0), .requestKeyframe, .ping(sentAt: 12.5),
        ]
        for m in messages {
            XCTAssertEqual(try MessageCodec.decode(ClientMessage.self, from: MessageCodec.encode(m)), m)
        }
    }

    func testServerMessagesRoundTrip() throws {
        let s = Stroke(sourceID: .mouse, tool: .pen, color: RGBAColor.palette[0], width: 0.004,
                       points: [StrokePoint(x: 0.1, y: 0.2)], seq: 7)
        let messages: [ServerMessage] = [
            .welcome(Welcome(macName: "Mac", display: DisplayInfo(id: 1, name: "Built-in", width: 1512, height: 982),
                             snapshot: [s], toolState: ToolState(), macDrawMode: false, screenPermission: true)),
            .liveBegan(s), .liveUpdated(id: s.id, points: s.points, replace: true), .liveCancelled(id: s.id),
            .committedChanged(added: [s], removed: [UUID()]), .toolChanged(source: .mouse, state: ToolState()),
            .drawModeChanged(true), .displayChanged(DisplayInfo(id: 2, name: "Ext", width: 2560, height: 1440)),
            .screenPermission(granted: false), .pairingToken("abc"), .sessionEnded(reason: "quit"), .pong(sentAt: 1),
        ]
        for m in messages {
            XCTAssertEqual(try MessageCodec.decode(ServerMessage.self, from: MessageCodec.encode(m)), m)
        }
    }

    func testVideoAndDetailPacketsRoundTrip() {
        let v = VideoPacket(isKeyframe: true, timestamp: 123.456, width: 1600, height: 1040,
                            parameterSets: [Data([0x67, 1, 2]), Data([0x68, 3])], avcc: Data(repeating: 9, count: 100))
        XCTAssertEqual(VideoPacket(decoding: v.encoded()), v)
        let d = DetailPacket(rect: NormRect(x: 0.25, y: 0.5, w: 0.1, h: 0.05), requestID: 42, jpeg: Data([1, 2, 3]))
        XCTAssertEqual(DetailPacket(decoding: d.encoded()), d)
        XCTAssertNil(VideoPacket(decoding: Data([1, 2])))
    }

    func testPairingLinkRoundTrip() {
        let secret = PairingSecret.generate()
        XCTAssertEqual(secret.token.count, 22)
        let url = secret.pairingURL(serviceName: "Washington’s MacBook Pro", host: "192.168.1.20", port: 7878)
        let link = PairingLink(url: url)
        XCTAssertEqual(link, PairingLink(serviceName: "Washington’s MacBook Pro", token: secret.token, host: "192.168.1.20", port: 7878))
        XCTAssertNil(PairingLink(string: "https://example.com/?t=x"))
    }

    private func keys(token: String?, mode: AuthMode, client: Curve25519.KeyAgreement.PrivateKey,
                      server: Curve25519.KeyAgreement.PrivateKey, cn: Data, sn: Data) throws -> HandshakeKeys {
        HandshakeKeys(shared: try client.sharedSecretFromKeyAgreement(with: server.publicKey), token: token, mode: mode,
                      clientNonce: cn, serverNonce: sn, clientPub: client.publicKey.rawRepresentation,
                      serverPub: server.publicKey.rawRepresentation)
    }

    func testHandshakeKeysAgreeAndDependOnToken() throws {
        let c = Curve25519.KeyAgreement.PrivateKey(), s = Curve25519.KeyAgreement.PrivateKey()
        let cn = Handshake.randomNonce(), sn = Handshake.randomNonce()
        let client = try keys(token: "tok", mode: .token, client: c, server: s, cn: cn, sn: sn)
        let server = HandshakeKeys(shared: try s.sharedSecretFromKeyAgreement(with: c.publicKey), token: "tok", mode: .token,
                                   clientNonce: cn, serverNonce: sn, clientPub: c.publicKey.rawRepresentation,
                                   serverPub: s.publicKey.rawRepresentation)
        XCTAssertTrue(server.isValidClientProof(client.clientProof))
        XCTAssertTrue(client.isValidServerProof(server.serverProof))
        XCTAssertEqual(client.confirmCode, server.confirmCode)
        XCTAssertEqual(client.confirmCode.count, 6)
        // A wrong token, or the other mode, gives a different key.
        XCTAssertFalse(server.isValidClientProof(try keys(token: "other", mode: .token, client: c, server: s, cn: cn, sn: sn).clientProof))
        XCTAssertNotEqual(try keys(token: nil, mode: .confirm, client: c, server: s, cn: cn, sn: sn).clientProof, client.clientProof)
        // Commitments bind the key.
        XCTAssertNotEqual(Handshake.commitment(to: c.publicKey.rawRepresentation), Handshake.commitment(to: s.publicKey.rawRepresentation))
    }

    /// Fixed values also printed in docs/protocol.md, so another implementation (Windows) can check itself.
    /// They were cross-checked with an independent implementation written from that document.
    func testHandshakeKeysMatchProtocolSpecVectors() throws {
        func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
        let c = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32))
        let s = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x22, count: 32))
        let cn = Data(repeating: 0xAA, count: 32), sn = Data(repeating: 0xBB, count: 32)
        XCTAssertEqual(hex(c.publicKey.rawRepresentation), "7b4e909bbe7ffe44c465a220037d608ee35897d31ef972f07f74892cb0f73f13")
        XCTAssertEqual(hex(s.publicKey.rawRepresentation), "0faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f20")
        XCTAssertEqual(hex(Handshake.commitment(to: c.publicKey.rawRepresentation)),
                       "602f73ae9dc4c13584eebb256cf73ef47436761db53b5bb222b7e2f57c7f44eb")
        let expected: [(AuthMode, String?, [String])] = [
            (.token, "token-123", ["2a333338b0308a156ed90448711b4c8368ed3130c4b0fb526b9f727da7152115",
                                   "d33f3fde4a92f91d304b4920dbe50a40cf40968ffd936a804a4826594b944fa3",
                                   "e973accf70c73a43ae6cbb93308a37bd7bcd117037758eb84c8f8bd32ea78ba7",
                                   "6af86210ef328c7cf670e0c07539dbf5c3b5c69c7425c21fa3bbdd6593d6ce83",
                                   "11714f39986989e72499a16b7463eafd78ffb0d34fa6cf248c4b1e84884d5f6d", "346892"]),
            (.confirm, nil, ["a8608049eda7e265d38e0cd3dfaf5655e5fe11672f47518d6d3a26af90798c21",
                             "49a1a4f4692b05fd0cdeb7f0d41701b6bc92fa3186186ee4e7d11e8004c409fe",
                             "ef4e8db42ee07992d8fff6c3a34ebe5e2f43e243663f1eca41986a997bccde91",
                             "077fbaaab24be29dcdf973312f630d4ae5358ce1c607dbf93c385c8ab0c5f486",
                             "b33276bdc30edf08758bbf1988b372217d2107369faacbff3cef03c1be68bc0a", "015112"]),
        ]
        for (mode, token, values) in expected {
            let k = HandshakeKeys(shared: try c.sharedSecretFromKeyAgreement(with: s.publicKey), token: token, mode: mode,
                                  clientNonce: cn, serverNonce: sn, clientPub: c.publicKey.rawRepresentation,
                                  serverPub: s.publicKey.rawRepresentation)
            XCTAssertEqual([hex(k.transcript), hex(k.clientProof), hex(k.serverProof),
                            hex(k.clientToServer.withUnsafeBytes { Data($0) }), hex(k.serverToClient.withUnsafeBytes { Data($0) }),
                            k.confirmCode], values, "\(mode)")
        }
    }

    func testFrameCipherRejectsReplayAndWrongKey() throws {
        let c = Curve25519.KeyAgreement.PrivateKey(), s = Curve25519.KeyAgreement.PrivateKey()
        let k = try keys(token: nil, mode: .confirm, client: c, server: s, cn: Handshake.randomNonce(), sn: Handshake.randomNonce())
        var tx = FrameCipher(key: k.clientToServer), rx = FrameCipher(key: k.clientToServer)
        let a = try tx.seal(Data("one".utf8)), b = try tx.seal(Data("two".utf8))
        XCTAssertEqual(try rx.open(a), Data("one".utf8))
        XCTAssertEqual(try rx.open(b), Data("two".utf8))
        XCTAssertThrowsError(try rx.open(a)) // replay: the counter moved on
        var other = FrameCipher(key: k.serverToClient)
        var fresh = FrameCipher(key: k.clientToServer)
        XCTAssertThrowsError(try other.open(fresh.seal(Data("x".utf8)))) // wrong direction key
    }

    func testFailureLimiterLocksAfterFiveFailures() {
        var l = FailureLimiter(maxFailures: 5, lockout: 30)
        let t0 = Date()
        for _ in 0..<4 { l.recordFailure("h", now: t0) }
        XCTAssertFalse(l.isLocked("h", now: t0))
        l.recordFailure("h", now: t0)
        XCTAssertTrue(l.isLocked("h", now: t0.addingTimeInterval(29)))
        XCTAssertFalse(l.isLocked("h", now: t0.addingTimeInterval(31)))
        XCTAssertFalse(l.isLocked("other", now: t0))
    }

    func testFailureLimiterCountsAttemptsInFlight() {
        var l = FailureLimiter(maxFailures: 5, lockout: 30)
        let t0 = Date()
        // Parallel connections: only 5 attempts may be open at once.
        for _ in 0..<5 { XCTAssertTrue(l.begin("h", now: t0)) }
        XCTAssertFalse(l.begin("h", now: t0))
        // All five fail: the host is locked out.
        for _ in 0..<5 { l.finish("h", success: false, now: t0) }
        XCTAssertTrue(l.isLocked("h", now: t0))
        XCTAssertFalse(l.begin("h", now: t0.addingTimeInterval(10)))
        XCTAssertTrue(l.begin("h", now: t0.addingTimeInterval(31)))
    }

    func testFailureLimiterSuccessClearsFailures() {
        var l = FailureLimiter(maxFailures: 5, lockout: 30)
        let t0 = Date()
        for _ in 0..<4 { l.recordFailure("h", now: t0) }
        XCTAssertTrue(l.begin("h", now: t0))
        l.finish("h", success: true, now: t0)
        // All 5 attempts are free again at the same moment: the 4 failures were cleared.
        for _ in 0..<5 { XCTAssertTrue(l.begin("h", now: t0)) }
    }

    func testOnlyConfirmPairingsReceiveTheToken() {
        XCTAssertTrue(AuthMode.confirm.receivesPairingToken)
        XCTAssertFalse(AuthMode.token.receivesPairingToken)
        XCTAssertEqual(ClientAuth.confirm(deviceName: "x").mode, .confirm)
        XCTAssertEqual(ClientAuth.token("t").mode, .token)
    }

    func testDisplayCode() {
        XCTAssertEqual(Handshake.displayCode("012345"), "012 345")
        XCTAssertEqual(Handshake.randomBytes(16).count, 16)
    }

    func testFailureLimiterForgetsOldFailures() {
        var l = FailureLimiter(maxFailures: 5, lockout: 30)
        let t0 = Date()
        for _ in 0..<4 { l.recordFailure("h", now: t0) }
        // Right away only one attempt is left...
        XCTAssertTrue(l.begin("h", now: t0))
        XCTAssertFalse(l.begin("h", now: t0))
        l.finish("h", success: true, now: t0)
        for _ in 0..<4 { l.recordFailure("h", now: t0) }
        // ...but a minute later the old failures no longer count.
        let later = t0.addingTimeInterval(60)
        for _ in 0..<5 { XCTAssertTrue(l.begin("h", now: later)) }
    }

    func testDeviceNameIsCleaned() {
        XCTAssertEqual(ConfirmRequest.displayName("Ana's iPhone\n\nCode verified ✓"), "Ana's iPhoneCode verified ✓")
        XCTAssertEqual(ConfirmRequest.displayName(String(repeating: "x", count: 100)).count, ConfirmRequest.maxNameLength)
        XCTAssertEqual(ConfirmRequest.displayName("  \t "), "Unknown device")
        XCTAssertEqual(ConfirmRequest.displayName(nil), "Unknown device")
    }
}

/// End-to-end over loopback TCP: both pairing modes, encrypted frames, and rejections.
final class SecureChannelLoopbackTests: XCTestCase {
    private var keep: [SecureChannel] = []
    private let keepLock = NSLock()

    private func startServer(token: String = "server-token",
                             approve: @escaping (ConfirmRequest, @escaping (Bool) -> Void) -> Void = { _, done in done(false) },
                             cancelApproval: @escaping (UUID) -> Void = { _ in },
                             limiter: LimiterBox = LimiterBox(),
                             onServerReady: @escaping () -> Void = {},
                             onFrame: @escaping (SecureChannel, FrameKind, Data) -> Void = { ch, kind, data in ch.send(kind, data + Data("!".utf8)) }) throws -> (NWListener, NWEndpoint.Port) {
        let listener = try NWListener(using: .lowLatencyTCP(), on: .any)
        listener.newConnectionHandler = { [weak self] conn in
            let auth = ServerAuth(token: token, approve: approve, cancelApproval: cancelApproval, limiter: limiter)
            let ch = SecureChannel(connection: conn, role: .server(auth), callbackQueue: .global())
            ch.onFrame = { onFrame(ch, $0, $1) }
            ch.onReady = onServerReady
            self?.keepLock.lock(); self?.keep.append(ch); self?.keepLock.unlock()
            ch.start()
        }
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        wait(for: [ready], timeout: 5)
        return (listener, listener.port!)
    }

    private func client(_ auth: ClientAuth, port: NWEndpoint.Port) -> SecureChannel {
        SecureChannel(connection: NWConnection(host: "127.0.0.1", port: port, using: .lowLatencyTCP()),
                      role: .client(auth), callbackQueue: .global())
    }

    func testTokenHandshakeAndEcho() throws {
        let (listener, port) = try startServer()
        defer { listener.cancel() }
        let c = client(.token("server-token"), port: port)
        let echoed = expectation(description: "echo")
        c.onReady = {
            XCTAssertEqual(c.authMode, .token)
            c.send(.video, Data("frame".utf8))
        }
        c.onFrame = { kind, data in
            XCTAssertEqual(kind, .video)
            XCTAssertEqual(data, Data("frame!".utf8))
            echoed.fulfill()
        }
        c.start()
        wait(for: [echoed], timeout: 5)
        c.cancel()
    }

    func testConfirmNeedsBothSidesAndShowsSameCode() throws {
        let serverAsked = expectation(description: "server prompt")
        var serverCode: String?
        var allow: ((Bool) -> Void)?
        let (listener, port) = try startServer(approve: { request, done in
            XCTAssertEqual(request.deviceName, "Test iPhone")
            serverCode = request.code
            allow = done
            serverAsked.fulfill()
        })
        defer { listener.cancel() }
        let c = client(.confirm(deviceName: "Test iPhone"), port: port)
        var clientCode: String?
        let shown = expectation(description: "code shown")
        let ready = expectation(description: "ready")
        c.onConfirmCode = { clientCode = $0; shown.fulfill() }
        c.onReady = { ready.fulfill() }
        c.start()
        // The Mac prompt opens before the phone user has confirmed anything.
        wait(for: [shown, serverAsked], timeout: 5)
        XCTAssertEqual(clientCode, serverCode)
        allow?(true)                    // Allow on the Mac alone is not enough...
        c.confirmCode(matches: true)    // ...the phone user must confirm too.
        wait(for: [ready], timeout: 5)
        XCTAssertEqual(c.authMode, .confirm)
        c.cancel()
    }

    func testAllowOnTheMacAloneDoesNotPair() throws {
        let serverReady = expectation(description: "server ready")
        serverReady.isInverted = true
        let (listener, port) = try startServer(approve: { _, done in done(true) }, onServerReady: { serverReady.fulfill() })
        defer { listener.cancel() }
        let c = client(.confirm(deviceName: "x"), port: port)
        let shown = expectation(description: "code shown")
        c.onConfirmCode = { _ in shown.fulfill() } // the phone user never taps "Codes Match"
        c.start()
        wait(for: [shown], timeout: 5)
        wait(for: [serverReady], timeout: 0.5)
        c.cancel()
    }

    func testCodesMatchOnThePhoneAloneDoesNotPairUntilAllow() throws {
        let asked = expectation(description: "asked")
        var allow: ((Bool) -> Void)?
        let notYet = expectation(description: "server ready too early")
        notYet.isInverted = true
        let serverReady = expectation(description: "server ready")
        var allowed = false
        let (listener, port) = try startServer(approve: { _, done in allow = done; asked.fulfill() },
                                               onServerReady: { allowed ? serverReady.fulfill() : notYet.fulfill() })
        defer { listener.cancel() }
        let c = client(.confirm(deviceName: "x"), port: port)
        let clientReady = expectation(description: "client ready")
        c.onConfirmCode = { _ in c.confirmCode(matches: true) } // the phone confirms first
        c.onReady = { clientReady.fulfill() }
        c.start()
        wait(for: [asked], timeout: 5)
        wait(for: [notYet], timeout: 0.5) // the proof has arrived, but nobody clicked Allow
        allowed = true
        allow?(true)
        wait(for: [serverReady, clientReady], timeout: 5)
        c.cancel()
    }

    func testDeclinedConfirmIsRejected() throws {
        let (listener, port) = try startServer(onFrame: { _, _, _ in XCTFail("no frames before pairing") })
        defer { listener.cancel() }
        let c = client(.confirm(deviceName: "x"), port: port)
        let closed = expectation(description: "closed")
        c.onConfirmCode = { _ in c.confirmCode(matches: true) }
        c.onReady = { XCTFail("must not become ready") }
        c.onClose = { XCTAssertEqual($0, .denied); closed.fulfill() }
        c.start()
        wait(for: [closed], timeout: 5)
    }

    func testCancelledPairingClosesTheMacPrompt() throws {
        let asked = expectation(description: "asked"), cancelled = expectation(description: "prompt closed")
        var askedID: UUID?
        let (listener, port) = try startServer(approve: { request, _ in askedID = request.id; asked.fulfill() },
                                               cancelApproval: { id in XCTAssertEqual(id, askedID); cancelled.fulfill() })
        defer { listener.cancel() }
        let c = client(.confirm(deviceName: "x"), port: port)
        c.start()
        wait(for: [asked], timeout: 5)
        c.confirmCode(matches: false) // the user tapped Cancel on the phone
        wait(for: [cancelled], timeout: 5)
    }

    func testWrongTokenIsRejected() throws {
        let (listener, port) = try startServer(onFrame: { _, _, _ in XCTFail("no frames from an unauthenticated client") })
        defer { listener.cancel() }
        let c = client(.token("wrong"), port: port)
        let closed = expectation(description: "closed")
        c.onReady = { XCTFail("must not become ready") }
        c.onClose = { XCTAssertEqual($0, .authFailed); closed.fulfill() }
        c.start()
        wait(for: [closed], timeout: 5)
    }

    func testLockedHostIsRefusedBeforeAnyGuess() throws {
        let limiter = LimiterBox(FailureLimiter(maxFailures: 1, lockout: 30))
        XCTAssertTrue(limiter.begin("127.0.0.1"))
        limiter.finish("127.0.0.1", success: false)
        let (listener, port) = try startServer(limiter: limiter)
        defer { listener.cancel() }
        let c = client(.token("server-token"), port: port)
        let closed = expectation(description: "closed")
        c.onClose = { XCTAssertEqual($0, .locked); closed.fulfill() }
        c.start()
        wait(for: [closed], timeout: 5)
    }

    func testRevealThatDoesNotMatchTheCommitmentIsRejected() throws {
        let (listener, port) = try startServer(approve: { _, _ in XCTFail("must not ask the user") })
        defer { listener.cancel() }
        let peer = RawPeer(port: port)
        let committed = Curve25519.KeyAgreement.PrivateKey(), other = Curve25519.KeyAgreement.PrivateKey()
        peer.sendJSON(ClientHello(v: ProtocolInfo.version, mode: .confirm, nonce: Handshake.randomNonce(),
                                  commit: Handshake.commitment(to: committed.publicKey.rawRepresentation), deviceName: "x"))
        let challenge = try XCTUnwrap(peer.receiveJSON(ServerChallenge.self))
        XCTAssertNotNil(challenge.pub)
        peer.sendJSON(ClientReveal(pub: other.publicKey.rawRepresentation)) // a different key than committed
        let result = try XCTUnwrap(peer.receiveJSON(ServerResult.self))
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "auth")
        peer.cancel()
    }

    func testOldProtocolVersionIsClosedWithoutAChallenge() throws {
        let (listener, port) = try startServer()
        defer { listener.cancel() }
        let peer = RawPeer(port: port)
        peer.sendJSON(ClientHello(v: 1, mode: .token, nonce: Handshake.randomNonce(),
                                  pub: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation))
        XCTAssertNil(peer.receive(), "the server must close without answering")
        peer.cancel()
    }

    func testOversizedHandshakeMessageClosesConnection() throws {
        let (listener, port) = try startServer()
        defer { listener.cancel() }
        let conn = NWConnection(host: "127.0.0.1", port: port, using: .lowLatencyTCP())
        let closed = expectation(description: "server closed")
        conn.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            var header = ByteWriter()
            header.u32(UInt32(SecureChannel.maxHandshakeFrameSize + 1))
            conn.send(content: header.data, completion: .idempotent)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, error in
                if isComplete || error != nil { closed.fulfill() }
            }
        }
        conn.start(queue: .global())
        wait(for: [closed], timeout: 5)
        conn.cancel()
    }
}

/// A plain TCP peer that speaks the handshake framing by hand, to send what a real client wouldn't.
private final class RawPeer {
    private let connection: NWConnection

    init(port: NWEndpoint.Port) {
        connection = NWConnection(host: "127.0.0.1", port: port, using: .lowLatencyTCP())
        connection.start(queue: .global())
    }

    func sendJSON(_ value: some Encodable) {
        let body = try! JSONEncoder().encode(value)
        var header = ByteWriter()
        header.u32(UInt32(body.count))
        connection.send(content: header.data + body, completion: .idempotent)
    }

    /// The next frame's payload, or nil when the server closed the connection (5 s limit).
    func receive() -> Data? {
        guard let header = read(4) else { return nil }
        var r = ByteReader(header)
        return read(Int(r.u32() ?? 0))
    }

    func receiveJSON<T: Decodable>(_ type: T.Type) -> T? {
        receive().flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    func cancel() { connection.cancel() }

    private func read(_ count: Int) -> Data? {
        let done = DispatchSemaphore(value: 0)
        var result: Data?
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, _ in
            if let data, data.count == count { result = data }
            done.signal()
        }
        return done.wait(timeout: .now() + 5) == .success ? result : nil
    }
}

/// A newer computer may send strokes with tools this build doesn't know.
final class UnknownToolTests: XCTestCase {
    private let pen = Stroke(sourceID: .mouse, tool: .pen, color: RGBAColor.palette[0], width: 0.004,
                             points: [StrokePoint(x: 0.1, y: 0.1)])
    private let future = Stroke(sourceID: .mouse, tool: .arrow, color: RGBAColor.palette[1], width: 0.004,
                                points: [StrokePoint(x: 0.2, y: 0.2), StrokePoint(x: 0.3, y: 0.3)])

    /// Re-encodes `message` with every "arrow" tool renamed to a tool this build doesn't have.
    private func withUnknownTool(_ message: ServerMessage) throws -> Data {
        let data = try MessageCodec.encode(message)
        var plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        func rename(_ value: Any) -> Any {
            if let dict = value as? [String: Any] {
                return dict.mapValues { ($0 as? String) == "arrow" ? "laser-pointer" : rename($0) }
            }
            if let array = value as? [Any] { return array.map(rename) }
            return value
        }
        plist = rename(plist)
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    func testCommittedChangesKeepTheStrokesThisBuildCanRead() throws {
        let removed = UUID()
        let data = try withUnknownTool(.committedChanged(added: [pen, future], removed: [removed]))
        XCTAssertEqual(try MessageCodec.decode(ServerMessage.self, from: data), .committedChanged(added: [pen], removed: [removed]))
    }

    func testWelcomeSnapshotSkipsUnknownStrokes() throws {
        let welcome = Welcome(macName: "Mac", display: DisplayInfo(id: 1, name: "D", width: 100, height: 50),
                              snapshot: [future, pen], toolState: ToolState(), macDrawMode: false, screenPermission: true)
        guard case .welcome(let decoded) = try MessageCodec.decode(ServerMessage.self, from: withUnknownTool(.welcome(welcome))) else {
            return XCTFail("welcome must still decode")
        }
        XCTAssertEqual(decoded.snapshot, [pen])
        XCTAssertEqual(decoded.macName, "Mac")
    }

    func testStrokeListIsAPlainArrayOnTheWire() throws {
        let asList = try PropertyListSerialization.propertyList(from: MessageCodec.encode(StrokeList([pen])), format: nil)
        let asArray = try PropertyListSerialization.propertyList(from: MessageCodec.encode([pen]), format: nil)
        XCTAssertEqual(asList as? NSArray, asArray as? NSArray)
    }
}
