import AppKit

/// Guides the user to grant Screen Recording, which the phone preview needs.
@MainActor
enum ScreenPermission {
    private static var prompted = false

    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt once, then a guided alert pointing to System Settings.
    static func promptIfNeeded() {
        guard !isGranted, !prompted else { return }
        prompted = true
        // Registers the app in the Screen Recording list and shows the system prompt the first time.
        _ = CGRequestScreenCaptureAccess()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard !isGranted else { return }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Allow Screen Recording for the iPhone/iPad preview"
            alert.informativeText = """
            Glasspen Meet needs Screen Recording permission to show your screen on the paired device. \
            Drawing from the device still works without it.

            Open System Settings → Privacy & Security → Screen & System Audio Recording, turn on Glasspen Meet, then reopen it.
            """
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Not Now")
            if alert.runModal() == .alertFirstButtonReturn { openSettings() }
        }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
