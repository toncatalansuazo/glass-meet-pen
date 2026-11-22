import Foundation

public enum ProtocolInfo {
    public static let version: Int = 2
    public static let bonjourType = "_paintscreen._tcp"
    public static let defaultPort: UInt16 = 7878
}

public enum ChannelRole: String, Codable, Sendable { case control, video }

/// Messages sent from the phone/iPad to the Mac.
public enum ClientMessage: Codable, Equatable, Sendable {
    case hello(version: Int, role: ChannelRole, deviceName: String, sourceID: SourceID, isPad: Bool)
    case strokeBegin(Stroke)
    case strokeAppend(id: UUID, points: [StrokePoint])
    case strokeEnd(id: UUID)
    case strokeCancel(id: UUID)
    case erase(points: [StrokePoint], radius: Float)
    case undo
    case redo
    case clear
    case setTool(ToolState)
    case setMacDrawMode(Bool)
    /// Visible region of the display in normalized coords and its size in device pixels.
    /// `nil` rect means "fit / no detail needed".
    case viewport(rect: NormRect?, pixelWidth: Int, pixelHeight: Int)
    case requestKeyframe
    case ping(sentAt: Double)
}

/// Messages sent from the Mac to the phone/iPad.
public enum ServerMessage: Codable, Equatable, Sendable {
    case welcome(Welcome)
    case liveBegan(Stroke)
    case liveUpdated(id: UUID, points: [StrokePoint], replace: Bool)
    case liveCancelled(id: UUID)
    case committedChanged(added: StrokeList, removed: [UUID])
    case toolChanged(source: SourceID, state: ToolState)
    case drawModeChanged(Bool)
    case displayChanged(DisplayInfo)
    case screenPermission(granted: Bool)
    /// Sent after code pairing so the phone can reconnect later with the strong token.
    case pairingToken(String)
    case sessionEnded(reason: String)
    case pong(sentAt: Double)

    public init(_ event: DocumentEvent) {
        switch event {
        case .liveBegan(let s): self = .liveBegan(s)
        case .liveUpdated(let id, let pts, let replace): self = .liveUpdated(id: id, points: pts, replace: replace)
        case .liveCancelled(let id): self = .liveCancelled(id: id)
        case .committedChanged(let a, let r): self = .committedChanged(added: StrokeList(a), removed: r)
        }
    }

    public var documentEvent: DocumentEvent? {
        switch self {
        case .liveBegan(let s): return .liveBegan(s)
        case .liveUpdated(let id, let pts, let replace): return .liveUpdated(id: id, points: pts, replace: replace)
        case .liveCancelled(let id): return .liveCancelled(id: id)
        case .committedChanged(let a, let r): return .committedChanged(added: a.strokes, removed: r)
        default: return nil
        }
    }
}

public struct Welcome: Codable, Equatable, Sendable {
    public var macName: String
    public var display: DisplayInfo
    /// Sent as "snapshot"; strokes this build can't read are skipped (see `StrokeList`).
    private var snapshotList: StrokeList
    public var snapshot: [Stroke] {
        get { snapshotList.strokes }
        set { snapshotList = StrokeList(newValue) }
    }
    public var toolState: ToolState
    public var macDrawMode: Bool
    public var screenPermission: Bool

    public init(macName: String, display: DisplayInfo, snapshot: [Stroke], toolState: ToolState,
                macDrawMode: Bool, screenPermission: Bool) {
        self.macName = macName; self.display = display; self.snapshotList = StrokeList(snapshot)
        self.toolState = toolState; self.macDrawMode = macDrawMode; self.screenPermission = screenPermission
    }

    private enum CodingKeys: String, CodingKey {
        case macName, display, snapshotList = "snapshot", toolState, macDrawMode, screenPermission
    }
}

/// A list of strokes, sent as a plain array. When decoding it skips strokes this
/// build can't read (for example one drawn with a tool added in a later version),
/// so a newer computer never breaks an older phone's whole message.
public struct StrokeList: Codable, Equatable, Sendable, ExpressibleByArrayLiteral {
    public var strokes: [Stroke]

    public init(_ strokes: [Stroke]) { self.strokes = strokes }
    public init(arrayLiteral elements: Stroke...) { strokes = elements }

    private struct Skip: Decodable {}

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [Stroke] = []
        while !c.isAtEnd {
            if let stroke = try? c.decode(Stroke.self) { out.append(stroke) } else { _ = try c.decode(Skip.self) }
        }
        strokes = out
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(strokes)
    }
}

public struct NormRect: Codable, Hashable, Sendable {
    public var x: Float, y: Float, w: Float, h: Float
    public init(x: Float, y: Float, w: Float, h: Float) { self.x = x; self.y = y; self.w = w; self.h = h }
    public init(_ r: CGRect) { self.init(x: Float(r.minX), y: Float(r.minY), w: Float(r.width), h: Float(r.height)) }
    public var cgRect: CGRect { CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h)) }
}

/// Frame kinds carried inside an (encrypted) channel frame.
public enum FrameKind: UInt8, Sendable {
    case message = 0
    case video = 1
    case detail = 2
}

public enum MessageCodec {
    private static let encoder: PropertyListEncoder = {
        let e = PropertyListEncoder()
        e.outputFormat = .binary
        return e
    }()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try PropertyListDecoder().decode(type, from: data)
    }
}

// MARK: Binary payloads

/// One encoded H.264 access unit. Keyframes carry SPS/PPS so the phone can (re)build
/// its decoder format from any keyframe.
public struct VideoPacket: Equatable, Sendable {
    public var isKeyframe: Bool
    public var timestamp: Double
    public var width: UInt16
    public var height: UInt16
    public var parameterSets: [Data] // [SPS, PPS] on keyframes, empty otherwise
    public var avcc: Data            // length-prefixed NAL units

    public init(isKeyframe: Bool, timestamp: Double, width: UInt16, height: UInt16, parameterSets: [Data], avcc: Data) {
        self.isKeyframe = isKeyframe; self.timestamp = timestamp; self.width = width; self.height = height
        self.parameterSets = parameterSets; self.avcc = avcc
    }

    public func encoded() -> Data {
        var w = ByteWriter()
        w.u8(isKeyframe ? 1 : 0)
        w.f64(timestamp)
        w.u16(width); w.u16(height)
        w.u8(UInt8(parameterSets.count))
        for ps in parameterSets { w.u32(UInt32(ps.count)); w.bytes(ps) }
        w.bytes(avcc)
        return w.data
    }

    public init?(decoding data: Data) {
        var r = ByteReader(data)
        guard let key = r.u8(), let ts = r.f64(), let w = r.u16(), let h = r.u16(), let n = r.u8() else { return nil }
        var sets: [Data] = []
        for _ in 0..<n {
            guard let len = r.u32(), let d = r.bytes(Int(len)) else { return nil }
            sets.append(d)
        }
        self.init(isKeyframe: key == 1, timestamp: ts, width: w, height: h, parameterSets: sets, avcc: r.rest())
    }
}

/// A high-resolution still of part of the display (JPEG). Request ID 0 with the full rect is a
/// whole-screen frame, which a computer without H.264 video (the Windows app) sends instead.
public struct DetailPacket: Equatable, Sendable {
    public static let fullFrameID: UInt32 = 0

    /// A whole-screen frame rather than a close-up of the zoomed area.
    public var isFullFrame: Bool { requestID == Self.fullFrameID }

    public var rect: NormRect
    public var requestID: UInt32
    public var jpeg: Data

    public init(rect: NormRect, requestID: UInt32, jpeg: Data) {
        self.rect = rect; self.requestID = requestID; self.jpeg = jpeg
    }

    public func encoded() -> Data {
        var w = ByteWriter()
        w.f32(rect.x); w.f32(rect.y); w.f32(rect.w); w.f32(rect.h)
        w.u32(requestID)
        w.bytes(jpeg)
        return w.data
    }

    public init?(decoding data: Data) {
        var r = ByteReader(data)
        guard let x = r.f32(), let y = r.f32(), let w = r.f32(), let h = r.f32(), let id = r.u32() else { return nil }
        self.init(rect: NormRect(x: x, y: y, w: w, h: h), requestID: id, jpeg: r.rest())
    }
}

// MARK: Byte helpers (big-endian)

public struct ByteWriter {
    public private(set) var data = Data()
    public init() {}
    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    public mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    public mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    public mutating func f32(_ v: Float) { u32(v.bitPattern) }
    public mutating func f64(_ v: Double) { u64(v.bitPattern) }
    public mutating func bytes(_ d: Data) { data.append(d) }
}

public struct ByteReader {
    private let data: Data
    private var offset: Int
    public init(_ data: Data) { self.data = data; self.offset = data.startIndex }

    public mutating func bytes(_ n: Int) -> Data? {
        guard n >= 0, offset + n <= data.endIndex else { return nil }
        defer { offset += n }
        return data.subdata(in: offset..<(offset + n))
    }
    private mutating func int<T: FixedWidthInteger>(_: T.Type) -> T? {
        guard let d = bytes(MemoryLayout<T>.size) else { return nil }
        return d.reduce(T(0)) { ($0 << 8) | T($1) }
    }
    public mutating func u8() -> UInt8? { int(UInt8.self) }
    public mutating func u16() -> UInt16? { int(UInt16.self) }
    public mutating func u32() -> UInt32? { int(UInt32.self) }
    public mutating func u64() -> UInt64? { int(UInt64.self) }
    public mutating func f32() -> Float? { u32().map(Float.init(bitPattern:)) }
    public mutating func f64() -> Double? { u64().map(Double.init(bitPattern:)) }
    public mutating func rest() -> Data {
        defer { offset = data.endIndex }
        return data.subdata(in: offset..<data.endIndex)
    }
}
