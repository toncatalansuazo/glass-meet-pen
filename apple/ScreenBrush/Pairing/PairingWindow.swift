import AppKit
import BrushKit
import CoreImage.CIFilterBuiltins
import SwiftUI

@MainActor
final class PairingWindowController {
    private var window: NSWindow?
    private let server: RemoteServer

    init(server: RemoteServer) { self.server = server }

    func show() {
        if window == nil {
            window = NSWindow.floatingPanel(title: "Connect iPhone or iPad", size: NSSize(width: 380, height: 520),
                                            content: PairingView(server: server))
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

extension NSWindow {
    /// A small titled window that floats above full-screen apps and the drawing overlay.
    static func floatingPanel(title: String, size: NSSize, content: some View) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = NSHostingView(rootView: content)
        w.center()
        return w
    }
}

struct PairingView: View {
    @ObservedObject var server: RemoteServer

    var body: some View {
        VStack(spacing: 16) {
            if let name = server.connectedName {
                Label("\(name) is connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
            } else {
                Text("Open **Glasspen Remote** on your iPhone or iPad and scan this code")
                    .multilineTextAlignment(.center)
                    .font(.callout)
            }

            if let qr = QRCode.image(for: server.pairingURL.absoluteString) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
            }

            Text("Or tap “\(server.serviceName)” in the app, then click Allow here when both screens show the same code.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let error = server.listenerError {
                Text("Network error: \(error)").foregroundStyle(.red).font(.caption)
            } else if let ip = server.lanAddress {
                Text("Manual address: \(ip):\(String(server.port))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Button("Reset Pairing") { server.resetPairing() }
                .help("Creates a new QR code and disconnects every paired device")
        }
        .padding(24)
        .frame(width: 380)
    }
}

/// "Allow this device to connect?" with the code the phone shows. Closing the
/// window, or waiting 60 seconds, declines.
@MainActor
final class ApprovalWindowController {
    private static let timeout: TimeInterval = 60
    private var window: NSWindow?
    private var requestID: UUID?
    private var completion: ((Bool) -> Void)?

    func ask(_ request: ConfirmRequest, completion: @escaping (Bool) -> Void) {
        self.completion = completion
        requestID = request.id
        let w = NSWindow.floatingPanel(title: "Connect a device", size: NSSize(width: 360, height: 240),
                                       content: ApprovalView(request: request) { [weak self] in self?.finish($0) })
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.finish(false) }
        }
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        declineAfterTimeout(w)
    }

    /// The device gave up (cancelled or disconnected): close its prompt.
    func cancel(id: UUID) {
        guard requestID == id else { return }
        finish(false)
    }

    private func declineAfterTimeout(_ w: NSWindow) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self, weak w] in
            guard let self, let w, self.window === w else { return }
            self.finish(false)
        }
    }

    private func finish(_ allowed: Bool) {
        guard let completion else { return }
        self.completion = nil
        requestID = nil
        let w = window
        window = nil
        w?.close()
        completion(allowed)
    }
}

private struct ApprovalView: View {
    let request: ConfirmRequest
    let answer: (Bool) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("Allow this device to connect?")
                .font(.headline)
            Text(verbatim: request.deviceName)
                .font(.title3.bold())
                .lineLimit(1)
                .truncationMode(.tail)
            Text(Handshake.displayCode(request.code))
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
            Text("Click Allow only if your iPhone or iPad shows this same code. It will be able to see this screen and draw on it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Deny") { answer(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Allow") { answer(true) }
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}

enum QRCode {
    static func image(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
