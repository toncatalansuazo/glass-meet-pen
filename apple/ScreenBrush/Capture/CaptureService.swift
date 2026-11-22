import AppKit
import BrushKit
import CoreMedia
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

/// Captures the selected display (excluding Glasspen Meet's own windows, so the
/// phone renders annotations itself as vectors), encodes it to H.264 and sends
/// it on the phone's video channel. Also produces high-resolution "detail"
/// stills of the region the phone is zoomed into.
final class CaptureService: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "CaptureService")
    private var stream: SCStream?
    private var filter: SCContentFilter?
    private var display: SCDisplay?
    private var encoder: VideoEncoder?
    private var channel: SecureChannel?
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastPTS: CMTime = .zero
    private var forceKeyframe = true
    private var streamSize: CGSize = .zero

    // Adaptive rate control
    private var dropsThisWindow = 0
    private var framesThisWindow = 0
    private var windowStart = Date()
    private var skipAlternate = false
    private var frameCounter = 0

    // Detail stills
    private var viewport: CGRect?
    private var viewportPixels = CGSize.zero
    private var detailRequestID: UInt32 = 0
    private var detailWorkItem: DispatchWorkItem?
    private var lastDetailCapture = Date.distantPast

    static let maxLongSide: CGFloat = 1600
    static let minBitrate = 800_000
    static let maxBitrate = 8_000_000

    /// Called on the main queue when capture fails because Screen Recording is not granted.
    var onPermissionDenied: (() -> Void)?

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    // MARK: Lifecycle

    func start(displayID: CGDirectDisplayID, channel: SecureChannel) {
        queue.async { [self] in
            self.channel = channel
            forceKeyframe = true
            Task { await self.startStream(displayID: displayID) }
        }
    }

    func switchDisplay(to displayID: CGDirectDisplayID) {
        queue.async { [self] in
            guard let channel else { return }
            stopOnQueue()
            self.channel = channel
            forceKeyframe = true
            Task { await self.startStream(displayID: displayID) }
        }
    }

    func stop() {
        queue.async { [self] in
            stopOnQueue()
        }
    }

    private func stopOnQueue() {
        stream?.stopCapture { _ in }
        stream = nil
        encoder = nil
        channel = nil
        lastPixelBuffer = nil
        viewport = nil
        detailWorkItem?.cancel()
    }

    func requestKeyframe() {
        queue.async { [self] in
            forceKeyframe = true
            // A static screen produces no new frames, so re-encode the last one.
            if let pb = lastPixelBuffer {
                lastPTS = CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 600))
                encoder?.encode(pb, pts: lastPTS, forceKeyframe: true)
                forceKeyframe = false
            }
        }
    }

    private func startStream(displayID: CGDirectDisplayID) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { return }
            let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

            let scale = CGFloat(filter.pointPixelScale)
            var size = CGSize(width: CGFloat(display.width) * scale, height: CGFloat(display.height) * scale)
            let longSide = max(size.width, size.height)
            if longSide > Self.maxLongSide { size = CGSize(width: size.width * Self.maxLongSide / longSide, height: size.height * Self.maxLongSide / longSide) }
            // H.264 needs even dimensions.
            size = CGSize(width: (size.width / 2).rounded() * 2, height: (size.height / 2).rounded() * 2)

            let config = SCStreamConfiguration()
            config.width = Int(size.width)
            config.height = Int(size.height)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.queueDepth = 5
            config.showsCursor = true
            config.colorSpaceName = CGColorSpace.sRGB

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()

            queue.async { [self] in
                guard channel != nil else { stream.stopCapture { _ in }; return }
                self.stream = stream
                self.filter = filter
                self.display = display
                self.streamSize = size
                self.encoder = VideoEncoder(width: Int(size.width), height: Int(size.height), bitrate: 4_000_000) { [weak self] packet in
                    self?.channel?.send(.video, packet.encoded())
                }
                forceKeyframe = true
            }
        } catch {
            NSLog("Glasspen Meet capture failed: \(error)")
            if !Self.hasPermission {
                DispatchQueue.main.async { [weak self] in self?.onPermissionDenied?() }
            }
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let channel, let encoder,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let statusRaw = info[.status] as? Int, SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        lastPixelBuffer = pixelBuffer
        lastPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if let dirty = info[.dirtyRects] as? [NSDictionary] {
            checkDetailInvalidation(dirty.compactMap { CGRect(dictionaryRepresentation: $0) })
        }

        frameCounter += 1
        framesThisWindow += 1
        adaptRate()

        // Backpressure: never more than 2 frames in flight; skip *before* encoding so the
        // H.264 reference chain stays intact.
        if channel.pendingSends > 2 || (skipAlternate && frameCounter % 2 == 0 && !forceKeyframe) {
            dropsThisWindow += 1
            return
        }
        encoder.encode(pixelBuffer, pts: lastPTS, forceKeyframe: forceKeyframe)
        forceKeyframe = false
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Glasspen Meet stream stopped: \(error)")
        queue.async { [self] in
            if self.stream === stream { self.stream = nil }
        }
    }

    /// Every second: back off bitrate (and frame rate at the floor) when frames were dropped,
    /// recover slowly when the link keeps up.
    private func adaptRate() {
        guard let encoder, Date().timeIntervalSince(windowStart) >= 1 else { return }
        let dropRatio = framesThisWindow > 0 ? Double(dropsThisWindow) / Double(framesThisWindow) : 0
        var bitrate = encoder.bitrate
        if dropRatio > 0.1 {
            bitrate = max(Int(Double(bitrate) * 0.7), Self.minBitrate)
            skipAlternate = bitrate == Self.minBitrate
        } else if dropRatio == 0 {
            bitrate = min(Int(Double(bitrate) * 1.1), Self.maxBitrate)
            if bitrate > Self.minBitrate * 2 { skipAlternate = false }
        }
        if bitrate != encoder.bitrate { encoder.setBitrate(bitrate) }
        dropsThisWindow = 0
        framesThisWindow = 0
        windowStart = Date()
    }

    // MARK: Detail stills

    /// `rect` is normalized; `pixels` is the phone's on-screen pixel size for that region.
    func setViewport(_ rect: CGRect?, pixels: CGSize) {
        queue.async { [self] in
            viewport = rect
            viewportPixels = pixels
            detailRequestID &+= 1
            if detailRequestID == DetailPacket.fullFrameID { detailRequestID = 1 } // 0 means a whole-screen frame
            detailWorkItem?.cancel()
            if rect != nil { scheduleDetail(after: 0.15) }
        }
    }

    private func checkDetailInvalidation(_ dirtyRects: [CGRect]) {
        guard let viewport, streamSize.width > 0 else { return }
        let vp = CGRect(x: viewport.minX * streamSize.width, y: viewport.minY * streamSize.height,
                        width: viewport.width * streamSize.width, height: viewport.height * streamSize.height)
        if dirtyRects.contains(where: { $0.intersects(vp) }) {
            // Throttle refreshes of the detail image to ~2 per second.
            let wait = max(0.5 - Date().timeIntervalSince(lastDetailCapture), 0.1)
            if detailWorkItem == nil || detailWorkItem!.isCancelled { scheduleDetail(after: wait) }
        }
    }

    private func scheduleDetail(after delay: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in self?.captureDetail() }
        detailWorkItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func captureDetail() {
        detailWorkItem = nil
        guard let viewport, let filter, let display, let channel else { return }
        lastDetailCapture = Date()
        let requestID = detailRequestID
        let scale = CGFloat(filter.pointPixelScale)
        let source = CGRect(x: viewport.minX * CGFloat(display.width), y: viewport.minY * CGFloat(display.height),
                            width: viewport.width * CGFloat(display.width), height: viewport.height * CGFloat(display.height))
        // No more pixels than the display natively has, nor than the phone can show.
        let native = CGSize(width: source.width * scale, height: source.height * scale)
        let factor = min(1, viewportPixels.width / max(native.width, 1), viewportPixels.height / max(native.height, 1))
        let config = SCStreamConfiguration()
        config.sourceRect = source
        config.width = max(Int(native.width * factor), 16)
        config.height = max(Int(native.height * factor), 16)
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.sRGB

        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { [weak self] image, error in
            guard let self, let image else { return }
            self.queue.async {
                guard requestID == self.detailRequestID, let jpeg = Self.jpeg(image) else { return }
                channel.send(.detail, DetailPacket(rect: NormRect(viewport), requestID: requestID, jpeg: jpeg).encoded())
            }
        }
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
