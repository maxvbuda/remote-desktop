import AVFoundation
import CoreMedia

/// Plays relay-mode video: H.264 packets from RelayEncoder, received over the
/// signaling WebSocket when the devices can't connect directly.
final class RelayPlayer {
    let layer = AVSampleBufferDisplayLayer()
    var onSize: ((CGSize) -> Void)?

    private var format: CMVideoFormatDescription?
    private var size = CGSize.zero

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    /// Call on the main thread. Returns true once a frame was shown.
    @discardableResult
    func handle(_ packet: Data) -> Bool {
        guard let kind = packet.first else { return false }
        let body = packet.dropFirst()
        switch kind {
        case 0x01:
            setFormat(Array(body))
            return false
        case 0x02:
            return enqueue(body)
        default:
            return false
        }
    }

    private func setFormat(_ bytes: [UInt8]) {
        var sets: [[UInt8]] = []
        var i = 0
        while i + 2 <= bytes.count {
            let length = Int(bytes[i]) << 8 | Int(bytes[i + 1])
            i += 2
            guard i + length <= bytes.count else { return }
            sets.append(Array(bytes[i..<i + length]))
            i += length
        }
        guard !sets.isEmpty else { return }

        var newFormat: CMVideoFormatDescription?
        let status = withPointers(sets) { pointers, sizes in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &newFormat)
        }
        guard status == noErr, let newFormat else { return }
        format = newFormat
        let dims = CMVideoFormatDescriptionGetDimensions(newFormat)
        let newSize = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
        if newSize != size {
            size = newSize
            onSize?(newSize)
        }
    }

    private func enqueue(_ frame: Data) -> Bool {
        guard let format, !frame.isEmpty else { return false }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: frame.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: frame.count,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == kCMBlockBufferNoErr,
            let block else { return false }
        let copied = frame.withUnsafeBytes { ptr in
            CMBlockBufferReplaceDataBytes(with: ptr.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: frame.count)
        }
        guard copied == kCMBlockBufferNoErr else { return false }

        var sample: CMSampleBuffer?
        var sampleSize = frame.count
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr,
            let sample else { return false }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        if layer.status == .failed { layer.flush() }
        layer.enqueue(sample)
        return true
    }
}

private func withPointers<R>(_ sets: [[UInt8]], _ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
    let buffers = sets.map { set -> UnsafeMutablePointer<UInt8> in
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
        p.initialize(from: set, count: set.count)
        return p
    }
    defer { buffers.forEach { $0.deallocate() } }
    return body(buffers.map { UnsafePointer($0) }, sets.map(\.count))
}
