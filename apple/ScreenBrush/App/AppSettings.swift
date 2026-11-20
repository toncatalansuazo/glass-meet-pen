import AppKit
import Carbon.HIToolbox

/// Persistent user preferences (UserDefaults-backed).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var showInDock: Bool { didSet { defaults.set(showInDock, forKey: "showInDock"); onShowInDockChanged?(showInDock) } }
    @Published var boardOpacity: Double { didSet { defaults.set(boardOpacity, forKey: "boardOpacity") } }
    /// Tools, colors and widths behind one button each instead of all in the toolbar.
    @Published var toolbarOpacity: Double { didSet { defaults.set(toolbarOpacity, forKey: "toolbarOpacity") } }
    @Published var compactToolbar: Bool { didSet { defaults.set(compactToolbar, forKey: "compactToolbar") } }
    @Published var toolbarPosition: ToolbarPosition { didSet { defaults.set(toolbarPosition.rawValue, forKey: "toolbarPosition") } }
    @Published var inkOpacity: Double { didSet { defaults.set(inkOpacity, forKey: "inkOpacity") } }
    /// Seconds before strokes fade; 0 means permanent.
    @Published var fadeDelay: Double { didSet { defaults.set(fadeDelay, forKey: "fadeDelaySeconds") } }
    @Published var drawHotKey: KeyCombo { didSet { save(drawHotKey, "drawHotKey"); onHotKeysChanged?() } }
    @Published var clearHotKey: KeyCombo { didSet { save(clearHotKey, "clearHotKey"); onHotKeysChanged?() } }
    @Published var defaultDisplayID: CGDirectDisplayID? {
        didSet {
            if let id = defaultDisplayID { defaults.set(Int(id), forKey: "defaultDisplayID") } else { defaults.removeObject(forKey: "defaultDisplayID") }
        }
    }

    /// Buy Me a Coffee page; leave the username empty to hide every coffee link.
    static let buyMeACoffeeUsername = "toncatalan"
    static var buyMeACoffeeURL: URL? {
        buyMeACoffeeUsername.isEmpty ? nil : URL(string: "https://buymeacoffee.com/\(buyMeACoffeeUsername)")
    }

    var onShowInDockChanged: ((Bool) -> Void)?
    var onHotKeysChanged: (() -> Void)?

    private init() {
        defaults.register(defaults: ["showInDock": true, "boardOpacity": 0.9, "inkOpacity": 1.0, "fadeDelaySeconds": 1.0, "compactToolbar": true, "toolbarOpacity": 1.0])
        showInDock = defaults.bool(forKey: "showInDock")
        boardOpacity = defaults.double(forKey: "boardOpacity")
        inkOpacity = defaults.double(forKey: "inkOpacity")
        compactToolbar = defaults.bool(forKey: "compactToolbar")
        toolbarOpacity = defaults.double(forKey: "toolbarOpacity")
        toolbarPosition = defaults.string(forKey: "toolbarPosition").flatMap(ToolbarPosition.init) ?? .bottom
        fadeDelay = defaults.double(forKey: "fadeDelaySeconds")
        drawHotKey = Self.load("drawHotKey") ?? KeyCombo(keyCode: UInt32(kVK_ANSI_D), modifiers: [.option, .command])
        clearHotKey = Self.load("clearHotKey") ?? KeyCombo(keyCode: UInt32(kVK_ANSI_K), modifiers: [.option, .command])
        let id = defaults.integer(forKey: "defaultDisplayID")
        defaultDisplayID = id == 0 ? nil : CGDirectDisplayID(id)
    }

    private func save(_ combo: KeyCombo, _ key: String) {
        defaults.set(try? JSONEncoder().encode(combo), forKey: key)
    }

    private static func load(_ key: String) -> KeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }
}

/// Where the toolbar sits: a bar along the bottom, or a sidebar on either side.
enum ToolbarPosition: String, CaseIterable {
    case bottom, left, right

    var isVertical: Bool { self != .bottom }

    var title: String {
        switch self {
        case .bottom: return "Bottom"
        case .left: return "Left Side"
        case .right: return "Right Side"
        }
    }

    var symbolName: String {
        switch self {
        case .bottom: return "rectangle.bottomthird.inset.filled"
        case .left: return "sidebar.left"
        case .right: return "sidebar.right"
        }
    }
}
