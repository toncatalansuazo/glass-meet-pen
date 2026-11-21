import Foundation

/// When the whiteboard covers the screen. It stays up while you click through to
/// your apps (so you can keep presenting on it), and goes away with the toolbar, so
/// closing the toolbar always uncovers the apps.
public enum Whiteboard {
    public static func visibleOpacity(enabled: Bool, opacity: Double, toolbarVisible: Bool) -> Float {
        enabled && toolbarVisible ? Float(opacity) : 0
    }
}
