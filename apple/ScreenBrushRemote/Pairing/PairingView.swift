import BrushKit
import SwiftUI

struct PairingView: View {
    @ObservedObject var model: RemoteModel
    @StateObject private var browser = MacBrowser()
    @State private var scanning = false
    @State private var showManual = false

    var body: some View {
        NavigationStack {
            List {
                if let message = model.message {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Button {
                        scanning = true
                    } label: {
                        Label("Scan QR Code from Mac", systemImage: "qrcode.viewfinder")
                            .font(.headline)
                    }
                } footer: {
                    Text("On your Mac, open Glasspen Meet in the menu bar → Connect iPhone/iPad…")
                }

                Section("Macs on this network") {
                    if browser.permissionDenied {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Local Network access is off", systemImage: "wifi.exclamationmark")
                                .font(.headline)
                            Text("Glasspen Remote needs Local Network access to find your Mac. Turn it on in Settings → Privacy & Security → Local Network.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        }
                    } else if browser.macs.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking for Glasspen Meet…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(browser.macs, id: \.self) { name in
                        Button {
                            model.pair(target: .service(name: name))
                        } label: {
                            Label(name, systemImage: "laptopcomputer")
                        }
                    }
                    Button("Enter address manually…") { showManual = true }
                        .font(.callout)
                }

                if let code = model.confirmCode {
                    Section {
                        ConfirmCodeView(code: code, confirmed: model.codeConfirmed,
                                        onMatch: { model.codesMatch() }, onCancel: { model.cancelPairing() })
                    }
                } else if case .connecting(let name) = model.phase {
                    Section {
                        HStack { ProgressView(); Text("Connecting to \(name)…") }
                    }
                }
            }
            .navigationTitle("Glasspen Remote")
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
        .sheet(isPresented: $scanning) {
            QRScannerView { code in
                if let link = PairingLink(string: code) { model.pair(with: link) }
            }
        }
        .sheet(isPresented: $showManual) {
            ManualAddressView { target in
                model.pair(target: target)
            }
            .presentationDetents([.medium])
        }
    }
}

/// Both screens show the same code; the user confirms here and clicks Allow on the Mac.
struct ConfirmCodeView: View {
    let code: String
    let confirmed: Bool
    let onMatch: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("Does your Mac show the same code?").font(.callout)
            Text(Handshake.displayCode(code))
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
            if confirmed {
                HStack { ProgressView(); Text("Now click **Allow** on the Mac.") }
                    .font(.callout)
            } else {
                Button("Codes Match", action: onMatch)
                    .buttonStyle(.borderedProminent)
                Text("If the codes are different, cancel: another device may be pretending to be your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Cancel", role: .cancel, action: onCancel)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ManualAddressView: View {
    let onContinue: (MacTarget) -> Void
    @State private var host = ""
    @State private var port = "\(ProtocolInfo.defaultPort)"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("IP address (e.g. 192.168.1.20)", text: $host)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                } footer: {
                    Text("The Mac shows its address at the bottom of the Connect iPhone/iPad window.")
                }
            }
            .navigationTitle("Manual address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Next") {
                        let target = MacTarget.hostPort(host: host.trimmingCharacters(in: .whitespaces), port: UInt16(port) ?? ProtocolInfo.defaultPort)
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { onContinue(target) }
                    }
                    .disabled(host.isEmpty)
                }
            }
        }
    }
}
