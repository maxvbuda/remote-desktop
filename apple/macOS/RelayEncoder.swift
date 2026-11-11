import CoreMedia
import Foundation
import QuartzCore
import VideoToolbox

/// Encodes captured frames to H.264 for relay mode, when a viewer can't
/// connect directly and video goes through the Worker instead.
///
/// Packets (see RelayPlayer): 0x01 + parameter sets, sent before every keyframe,
/// and 0x02 + an AVCC frame (4-byte length-prefixed NAL units).
final class RelayEncoder {
    /// Called on an arbitrary thread with (packet, isKeyFrameOrParameters).
    var onPacket: ((Data, Bool) -> Void)?

    private static let frameInterval = 1.0 / 15
    private static let bitrate = 2_500_000

    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var forceKeyFrame = true
    private var lastEncode: CFTimeInterval = 0

    func requestKeyFrame() {
        lock.lock()
        forceKeyFrame = true
        lock.unlock()
    }

    func encode(_ buffer: CVPixelBuffer) {
        lock.lock()
        defer { lock.unlock() }
        let now = CACurrentMediaTime()
        guard forceKeyFrame || now - lastEncode >= Self.frameInterval else { return }
        lastEncode = now

        let w = Int32(CVPixelBufferGetWidth(buffer)), h = Int32(CVPixelBufferGetHeight(buffer))
        if session == nil || w != width || h != height {
            makeSession(width: w, height: h)
        }
        guard let session else { return }

        var properties: CFDictionary?
        if forceKeyFrame {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            forceKeyFrame = false
        }
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer,
            presentationTimeStamp: CMTime(seconds: now, preferredTimescale: 1000),
            duration: .invalid, frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            self?.output(sampleBuffer)
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    private func makeSession(width: Int32, height: Int32) {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        var created: VTCompressionSession?
        guard VTCompressionSessionCreate(
            allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created) == noErr,
            let created else { return }

        let set = { (key: CFString, value: CFTypeRef) in VTSessionSetProperty(created, key: key, value: value) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AverageBitRate, Self.bitrate as CFNumber)
        set(kVTCompressionPropertyKey_DataRateLimits, [Self.bitrate / 8 * 2, 1] as CFArray)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, 15 as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 60 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(created)

        session = created
        self.width = width
        self.height = height
        forceKeyFrame = true
    }

    private func output(_ sample: CMSampleBuffer) {
        guard let block = sample.dataBuffer else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)

        if isKey, let format = sample.formatDescription, let params = Self.parameterSets(format) {
            onPacket?(params, true)
        }
        var packet = Data([0x02])
        let length = CMBlockBufferGetDataLength(block)
        var bytes = Data(count: length)
        let status = bytes.withUnsafeMutableBytes { ptr in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { return }
        packet.append(bytes)
        onPacket?(packet, isKey)
    }

    /// 0x01, then each parameter set (SPS, PPS…) as a 2-byte big-endian length + bytes.
    private static func parameterSets(_ format: CMFormatDescription) -> Data? {
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr, count > 0 else { return nil }
        var packet = Data([0x01])
        for i in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
            packet.append(UInt8(size >> 8))
            packet.append(UInt8(size & 0xFF))
            packet.append(pointer, count: size)
        }
        return packet
    }
}
