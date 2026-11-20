import AppKit
import BrushKit
import SwiftUI

@main
struct ScreenBrushApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model, delegate: delegate)
        } label: {
            Image(systemName: model.drawMode ? "paintbrush.pointed.fill" : "paintbrush.pointed")
        }

        Settings {
            SettingsView(settings: AppSettings.shared, model: model)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    let delegate: AppDelegate

    var body: some View {
        Button(model.drawMode ? "Stop Drawing" : "Start Drawing") { model.toggleDrawMode() }
        Text("Shortcut: \(model.settings.drawHotKey.displayString)")
        Button(model.toolbarVisible ? "Hide Toolbar" : "Show Toolbar") { model.toolbarVisible.toggle() }
        Picker("Toolbar Position", selection: $model.toolbarPosition) {
            ForEach(ToolbarPosition.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Button("Clear All") { model.clear() }

        Divider()

        if let name = model.phoneName {
            Text("Connected: \(name)")
        } else {
            Text("No device connected")
        }
        Button("Connect iPhone/iPad…") { delegate.server?.showPairing() }
        Button("Reset Pairing") { delegate.server?.resetPairing() }

        Divider()

        Menu("Display") {
            ForEach(model.screens, id: \.self) { screen in
                Button {
                    model.selectDisplay(screen)
                } label: {
                    if AppModel.displayID(of: screen) == model.display.id {
                        Text("✓ \(screen.localizedName)")
                    } else {
                        Text("    \(screen.localizedName)")
                    }
                }
            }
        }
        if !ScreenPermission.isGranted {
            Button("Allow Screen Recording…") { ScreenPermission.openSettings() }
        }

        Divider()

        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        if let coffee = AppSettings.buyMeACoffeeURL {
            Button("☕ Buy Me a Coffee…") { NSWorkspace.shared.open(coffee) }
        }
        Button("Quit Glasspen Meet") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
