import AVFoundation
import BrushKit
import UIKit

/// Decodes and shows the Mac's H.264 stream with `AVSampleBufferDisplayLayer`.
final class VideoView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    private var format: CMVideoFormatDescription?

    /// Asked when the decoder needs a keyframe to (re)start.
    var onNeedKeyframe: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resize
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError() }

    func reset() {
        format = nil
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    func enqueue(_ packet: VideoPacket) {
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            format = nil
        }
        if packet.isKeyframe, packet.parameterSets.count >= 2 {
            format = Self.makeFormat(packet.parameterSets) ?? format
        }
        guard let format else {
            onNeedKeyframe?()
            return
        }
        guard let sample = Self.makeSample(packet.avcc, format: format) else { return }
        renderer.enqueue(sample)
    }

    private static func makeFormat(_ sets: [Data]) -> CMVideoFormatDescription? {
        var format: CMVideoFormatDescription?
        let datas = sets.map { [UInt8]($0) }
        let status = datas[0].withUnsafeBufferPointer { sps in
            datas[1].withUnsafeBufferPointer { pps in
                let pointers = [sps.baseAddress!, pps.baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        return status == noErr ? format : nil
    }

    private static func makeSample(_ avcc: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sample
    }
}
