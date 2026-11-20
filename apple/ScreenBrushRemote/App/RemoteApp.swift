import BrushKit
import SwiftUI

@main
struct RemoteApp: App {
    @StateObject private var model = RemoteModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .onOpenURL { model.handle(url: $0) } // system Camera app scanning the QR opens us directly
                .alert("Connect to this Mac?", isPresented: Binding(get: { model.pendingLink != nil },
                                                                     set: { if !$0 { model.pendingLink = nil } }),
                       presenting: model.pendingLink) { _ in
                    Button("Connect") { model.acceptPendingLink() }
                    Button("Cancel", role: .cancel) { model.pendingLink = nil }
                } message: { link in
                    Text(verbatim: "\(link.serviceName)\n\nThis replaces the Mac Glasspen Remote is paired with now.")
                }
                .onAppear { model.resumeIfPossible() }
                .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(active: phase == .active) }
        }
    }
}

struct RootView: View {
    @ObservedObject var model: RemoteModel

    var body: some View {
        switch model.phase {
        case .pairing, .connecting:
            PairingView(model: model)
        case .connected, .reconnecting:
            CanvasScreen(model: model)
        }
    }
}

struct CanvasScreen: View {
    @ObservedObject var model: RemoteModel
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize

    /// Side rail on iPad (regular width) and on iPhone in landscape (compact height).
    private var useRail: Bool { hSize == .regular || vSize == .compact }

    var body: some View {
        ZStack {
            CanvasView(model: model)
                .ignoresSafeArea()

            if useRail {
                HStack {
                    ControlsBar(model: model, vertical: true)
                        .padding(.leading, 8)
                    Spacer()
                }
            } else {
                VStack {
                    Spacer()
                    ControlsBar(model: model, vertical: false)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)
                }
            }

            VStack {
                StatusPill(model: model)
                Spacer()
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
}

struct StatusPill: View {
    @ObservedObject var model: RemoteModel

    var body: some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .reconnecting(let name):
                ProgressView().controlSize(.small)
                Text("Reconnecting to \(name)…")
            default:
                Circle().fill(.green).frame(width: 8, height: 8)
                Text(model.macName)
                Text(model.mode == .paint ? "· Paint" : "· Move & zoom").foregroundStyle(.secondary)
            }
            Menu {
                Button("Disconnect", role: .destructive) { model.forgetMac() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.top, 6)
    }
}
