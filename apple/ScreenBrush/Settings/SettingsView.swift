import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("App") {
                Toggle("Show Glasspen Meet in the Dock", isOn: $settings.showInDock)
                Text("The menu-bar icon is always shown.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Toolbar") {
                Toggle("Compact toolbar", isOn: $model.compactToolbar)
                Text("On: tools, colors and widths open from one button each. Off: every option is shown in the toolbar.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Background") {
                    HStack {
                        Slider(value: $model.toolbarOpacity, in: 0...1).frame(width: 180)
                        Text("\(Int(model.toolbarOpacity * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Picker("Position", selection: $model.toolbarPosition) {
                    ForEach(ToolbarPosition.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }

            Section("Shortcuts") {
                LabeledContent("Toggle drawing") { HotKeyRecorder(combo: $settings.drawHotKey) }
                LabeledContent("Clear all") { HotKeyRecorder(combo: $settings.clearHotKey) }
                Text("While drawing: ⌘Z undo · ⇧⌘Z redo · P H L A R O I F E tools · 1–8 colors · [ ] width · Esc stop · Shift constrains shapes")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Display") {
                Picker("Draw on", selection: Binding(
                    get: { model.display.id },
                    set: { id in
                        if let screen = AppModel.screen(for: id) {
                            model.selectDisplay(screen)
                            settings.defaultDisplayID = id
                        }
                    })) {
                    ForEach(model.screens, id: \.self) { screen in
                        Text(screen.localizedName).tag(AppModel.displayID(of: screen))
                    }
                }
            }

            if let coffee = AppSettings.buyMeACoffeeURL {
                Section("Support") {
                    LabeledContent("Enjoying the app?") {
                        Link(destination: coffee) {
                            Label("Buy me a coffee", systemImage: "cup.and.saucer.fill")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Click, then press a key combination with at least one of ⌘ ⌥ ⌃.
struct HotKeyRecorder: View {
    @Binding var combo: KeyCombo
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Press shortcut…" : combo.displayString) {
            recording ? stop() : start()
        }
        .frame(minWidth: 120)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil } // Esc cancels
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !mods.intersection([.command, .option, .control]).isEmpty else { NSSound.beep(); return nil }
            combo = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: mods)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
