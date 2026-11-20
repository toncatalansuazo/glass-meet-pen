import Foundation

/// Identifies who produced a stroke: the Mac mouse, or a paired phone/iPad.
public struct SourceID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static let mouse = SourceID("mouse")
    public var isMouse: Bool { self == .mouse }
    public var description: String { rawValue }
}

public enum Tool: String, Codable, CaseIterable, Sendable {
    case pen, highlighter, line, arrow, rectangle, ellipse, phone, person, eraser

    /// Shapes are defined by two points (start, end) instead of a freehand path.
    public var isShape: Bool {
        switch self {
        case .line, .arrow, .rectangle, .ellipse, .phone, .person: return true
        default: return false
        }
    }

    /// Figures are pictograms drawn inside the box spanned by start and end.
    public var isFigure: Bool { self == .phone || self == .person }

    /// Natural width/height of a figure; Shift keeps it while dragging.
    public var figureAspect: Float? {
        switch self {
        case .phone: return 0.5
        case .person: return 0.55
        default: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .phone: return "Phone"
        case .person: return "Person"
        case .eraser: return "Eraser"
        }
    }

    public var symbolName: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .phone: return "iphone"
        case .person: return "figure.stand"
        case .eraser: return "eraser"
        }
    }

    /// Single-letter keyboard shortcut used on the Mac in draw mode.
    public var shortcutKey: Character {
        switch self {
        case .pen: return "p"
        case .highlighter: return "h"
        case .line: return "l"
        case .arrow: return "a"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .phone: return "i"
        case .person: return "f"
        case .eraser: return "e"
        }
    }
}

public struct RGBAColor: Hashable, Codable, Sendable {
    public var r: Float, g: Float, b: Float, a: Float
    public init(r: Float, g: Float, b: Float, a: Float = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public static let palette: [RGBAColor] = [
        RGBAColor(r: 1.00, g: 0.23, b: 0.19), // red
        RGBAColor(r: 1.00, g: 0.58, b: 0.00), // orange
        RGBAColor(r: 1.00, g: 0.84, b: 0.04), // yellow
        RGBAColor(r: 0.20, g: 0.78, b: 0.35), // green
        RGBAColor(r: 0.00, g: 0.48, b: 1.00), // blue
        RGBAColor(r: 0.69, g: 0.32, b: 0.87), // purple
        RGBAColor(r: 1.00, g: 1.00, b: 1.00), // white
        RGBAColor(r: 0.00, g: 0.00, b: 0.00), // black
    ]
}

/// A point in display-normalized coordinates: (0,0) is the top-left of the
/// selected display, (1,1) the bottom-right. `p` is pressure in 0...1
/// (1 when the input device has no pressure).
public struct StrokePoint: Hashable, Codable, Sendable {
    public var x: Float
    public var y: Float
    public var p: Float
    public init(x: Float, y: Float, p: Float = 1) {
        self.x = x; self.y = y; self.p = p
    }
    public init(_ point: CGPoint, pressure: CGFloat = 1) {
        self.init(x: Float(point.x), y: Float(point.y), p: Float(pressure))
    }
    public var cgPoint: CGPoint { CGPoint(x: CGFloat(x), y: CGFloat(y)) }
}

/// Stroke width presets, expressed in desktop points at the display's native
/// size. They are converted to a display-width fraction when a stroke starts,
/// so the same preset gives the same desktop width from the mouse or a phone,
/// at any zoom level.
public enum WidthPreset: Int, Codable, CaseIterable, Sendable {
    case fine = 0, medium, bold, heavy

    public var points: Float {
        switch self {
        case .fine: return 3
        case .medium: return 6
        case .bold: return 11
        case .heavy: return 18
        }
    }

    public func normalized(displayWidth: Float) -> Float {
        points / max(displayWidth, 1)
    }
}

public struct ToolState: Hashable, Codable, Sendable {
    public var tool: Tool
    public var color: RGBAColor
    public var width: WidthPreset
    public init(tool: Tool = .pen, color: RGBAColor = RGBAColor.palette[0], width: WidthPreset = .medium) {
        self.tool = tool; self.color = color; self.width = width
    }
}

public struct Stroke: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let sourceID: SourceID
    public let tool: Tool
    public let color: RGBAColor
    /// Width as a fraction of display width.
    public let width: Float
    /// For freehand tools: the sampled path. For shapes: exactly [start, end].
    public var points: [StrokePoint]
    /// Monotonic order assigned when the stroke is committed; used to keep
    /// z-order stable across undo/redo and network sync.
    public var seq: UInt64
    public var createdAt: Date

    public init(id: UUID = UUID(), sourceID: SourceID, tool: Tool, color: RGBAColor, width: Float,
                points: [StrokePoint], seq: UInt64 = 0, createdAt: Date = Date()) {
        self.id = id; self.sourceID = sourceID; self.tool = tool; self.color = color
        self.width = width; self.points = points; self.seq = seq; self.createdAt = createdAt
    }

    /// Color alpha is the ink opacity; highlighters are always at most 35% of it.
    public var effectiveAlpha: Float { tool == .highlighter ? 0.35 * color.a : color.a }

    /// Highlighters are wider than the selected preset.
    public var effectiveWidth: Float { tool == .highlighter ? width * 2.5 : width }
}

/// Describes the display the overlay covers, in points.
public struct DisplayInfo: Hashable, Codable, Sendable {
    public var id: UInt32
    public var name: String
    public var width: Float
    public var height: Float
    public init(id: UInt32, name: String, width: Float, height: Float) {
        self.id = id; self.name = name; self.width = width; self.height = height
    }
    public var aspect: Float { width / max(height, 1) }
}
