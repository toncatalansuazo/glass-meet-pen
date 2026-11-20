import CryptoKit
import Foundation

/// The Mac's long-term pairing secret: 16 random bytes, base64url. It travels in
/// the QR code and is handed to a phone after the user confirms a pairing on the Mac.
public struct PairingSecret: Equatable, Sendable {
    public let token: String

    public init(token: String) { self.token = token }

    public static func generate() -> PairingSecret {
        PairingSecret(token: Handshake.randomBytes(16).base64URLEncoded)
    }

    /// `paintscreen://pair?svc=<bonjour name>&t=<token>&h=<host>&p=<port>`
    public func pairingURL(serviceName: String, host: String?, port: UInt16) -> URL {
        var c = URLComponents()
        c.scheme = "paintscreen"
        c.host = "pair"
        var items = [URLQueryItem(name: "svc", value: serviceName), URLQueryItem(name: "t", value: token)]
        if let host { items.append(URLQueryItem(name: "h", value: host)) }
        items.append(URLQueryItem(name: "p", value: String(port)))
        c.queryItems = items
        return c.url!
    }
}

/// Parsed contents of a pairing QR code.
public struct PairingLink: Equatable, Sendable {
    public var serviceName: String
    public var token: String
    public var host: String?
    public var port: UInt16?

    public init(serviceName: String, token: String, host: String? = nil, port: UInt16? = nil) {
        self.serviceName = serviceName; self.token = token; self.host = host; self.port = port
    }

    public init?(url: URL) {
        guard url.scheme == "paintscreen", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let svc = items.first(where: { $0.name == "svc" })?.value,
              let token = items.first(where: { $0.name == "t" })?.value, !token.isEmpty
        else { return nil }
        self.serviceName = svc
        self.token = token
        self.host = items.first(where: { $0.name == "h" })?.value
        self.port = items.first(where: { $0.name == "p" })?.value.flatMap(UInt16.init)
    }

    public init?(string: String) {
        guard let url = URL(string: string) else { return nil }
        self.init(url: url)
    }
}

/// How a phone proves it may connect.
/// - `token`: it knows the Mac's 128-bit token (QR code or a remembered pairing).
/// - `confirm`: the user compares a 6-digit code shown on both screens and clicks Allow on the Mac.
public enum AuthMode: String, Codable, Sendable {
    case token, confirm

    /// The server sends its token only after a pairing the user confirmed; the phone
    /// then reconnects with it. A token-mode client already has the token.
    public var receivesPairingToken: Bool { self == .confirm }
}

// MARK: Handshake messages (sent unencrypted, JSON)

/// `pub` is sent here in token mode. In confirm mode only `commit` = SHA-256(pub) is sent,
/// and `pub` follows in `ClientReveal` after the server has shown its own key.
public struct ClientHello: Codable, Sendable {
    public var v: Int
    public var mode: AuthMode
    public var nonce: Data
    public var pub: Data?
    public var commit: Data?
    public var deviceName: String?
}
public struct ServerChallenge: Codable, Sendable {
    public var nonce: Data
    public var pub: Data?
    public var locked: Bool
}
public struct ClientReveal: Codable, Sendable { public var pub: Data }
public struct ClientProof: Codable, Sendable { public var mac: Data }
public struct ServerResult: Codable, Sendable { public var ok: Bool; public var mac: Data?; public var reason: String? }

/// Keys for one handshake. Every connection does a fresh X25519 exchange, so a
/// recording of the traffic can't be decrypted later, even with the token.
/// Both sides then prove they derived the same key, client first.
public struct HandshakeKeys {
    public let key: SymmetricKey
    public let transcript: Data

    /// - Parameters:
    ///   - token: mixed into the key in token mode; `nil` in confirm mode.
    public init(shared: SharedSecret, token: String?, mode: AuthMode,
                clientNonce: Data, serverNonce: Data, clientPub: Data, serverPub: Data) {
        transcript = Data(SHA256.hash(data: Data("glasspen-v2-\(mode.rawValue)".utf8)
            + clientNonce + serverNonce + clientPub + serverPub))
        var ikm = shared.withUnsafeBytes { Data($0) }
        if let token { ikm += Data(token.utf8) }
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: transcript,
                                     info: Data("glasspen-v2-key".utf8), outputByteCount: 32)
    }

    public var clientProof: Data { mac("client") }
    public var serverProof: Data { mac("server") }

    /// Constant-time checks of the other side's proof.
    public func isValidClientProof(_ mac: Data) -> Bool { isValid(mac, "client") }
    public func isValidServerProof(_ mac: Data) -> Bool { isValid(mac, "server") }
    public var clientToServer: SymmetricKey { derive("c2s", 32) }
    public var serverToClient: SymmetricKey { derive("s2c", 32) }

    /// The 6 digits both screens show in confirm mode.
    public var confirmCode: String {
        let bytes = derive("sas", 4).withUnsafeBytes { Array($0) }
        let n = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return String(format: "%06u", n % 1_000_000)
    }

    private func mac(_ label: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8) + transcript, using: key))
    }

    private func isValid(_ mac: Data, _ label: String) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: Data(label.utf8) + transcript, using: key)
    }

    private func derive(_ info: String, _ count: Int) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: transcript, info: Data(info.utf8), outputByteCount: count)
    }
}

public enum Handshake {
    public static func randomBytes(_ count: Int) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }

    public static func randomNonce() -> Data { randomBytes(32) }

    /// How both screens show a confirm code: "123 456".
    public static func displayCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    public static func commitment(to pub: Data) -> Data {
        Data(SHA256.hash(data: Data("glasspen-v2-commit".utf8) + pub))
    }

    /// Constant-time comparison (used for the commitment; proofs use `HandshakeKeys.isValid…`).
    public static func verify(_ mac: Data, expected: Data) -> Bool {
        guard mac.count == expected.count else { return false }
        return zip(mac, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Authenticated encryption for one direction of a channel. Nonces are a frame
/// counter, so reordered, replayed or dropped frames fail to decrypt.
public struct FrameCipher: Sendable {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    public init(key: SymmetricKey) { self.key = key }

    private func nonce(_ n: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        withUnsafeBytes(of: n.bigEndian) { bytes.replaceSubrange(4..<12, with: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    public mutating func seal(_ plaintext: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce(counter))
        counter += 1
        return box.ciphertext + box.tag
    }

    public mutating func open(_ data: Data) throws -> Data {
        guard data.count >= 16 else { throw CryptoKitError.incorrectParameterSize }
        let box = try ChaChaPoly.SealedBox(nonce: nonce(counter), ciphertext: data.dropLast(16), tag: data.suffix(16))
        let plain = try ChaChaPoly.open(box, using: key)
        counter += 1
        return plain
    }
}

/// Limits handshakes per remote host. An attempt is counted when it starts, not
/// when it fails, so parallel connections can't get extra tries. A host may have at
/// most `maxFailures` open attempts plus recent failures. Failures are forgotten
/// `lockout` seconds after the last one; reaching `maxFailures` locks the host for `lockout`.
public struct FailureLimiter: Sendable {
    public let maxFailures: Int
    public let lockout: TimeInterval
    private struct Entry { var count = 0; var last = Date.distantPast; var lockedUntil: Date? }
    private var failures: [String: Entry] = [:]
    private var inFlight: [String: Int] = [:]

    public init(maxFailures: Int = 5, lockout: TimeInterval = 30) {
        self.maxFailures = maxFailures; self.lockout = lockout
    }

    public func isLocked(_ host: String, now: Date = Date()) -> Bool {
        guard let until = failures[host]?.lockedUntil else { return false }
        return until > now
    }

    /// Failures still counted for `host` (old ones and expired lockouts are dropped).
    private func recentFailures(_ host: String, now: Date) -> Entry? {
        guard let entry = failures[host] else { return nil }
        if let until = entry.lockedUntil { return until > now ? entry : nil }
        return now.timeIntervalSince(entry.last) < lockout ? entry : nil
    }

    /// Reserves one attempt. Returns false when the host is locked or has too many attempts open.
    public mutating func begin(_ host: String, now: Date = Date()) -> Bool {
        failures[host] = recentFailures(host, now: now)
        guard !isLocked(host, now: now) else { return false }
        let open = inFlight[host, default: 0]
        guard open + (failures[host]?.count ?? 0) < maxFailures else { return false }
        inFlight[host] = open + 1
        return true
    }

    /// Ends an attempt reserved with `begin`.
    public mutating func finish(_ host: String, success: Bool, now: Date = Date()) {
        let open = inFlight[host, default: 0] - 1
        inFlight[host] = open > 0 ? open : nil
        if success { failures[host] = nil } else { recordFailure(host, now: now) }
    }

    public mutating func recordFailure(_ host: String, now: Date = Date()) {
        var entry = recentFailures(host, now: now) ?? Entry()
        entry.count += 1
        entry.last = now
        if entry.count >= maxFailures { entry.lockedUntil = now.addingTimeInterval(lockout); entry.count = 0 }
        failures[host] = entry
    }
}

extension Data {
    public var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
