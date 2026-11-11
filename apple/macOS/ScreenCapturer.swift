import CoreMedia
import ScreenCaptureKit
import WebRTC

/// Captures one display with ScreenCaptureKit and feeds frames to WebRTC.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    enum CaptureError: LocalizedError {
        case noDisplay
        var errorDescription: String? { "No display found to share." }
    }

    var onStop: ((Error) -> Void)?

    private var stream: SCStream?
    private var source: RTCVideoSource?
    private var capturer: RTCVideoCapturer?
    private let queue = DispatchQueue(label: "screen-capture")
    private var lastBuffer: CVPixelBuffer?
    private var lastFrameTime = DispatchTime.now()
    private var repeatTimer: DispatchSourceTimer?

    static func displays() async throws -> [SCDisplay] {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).displays
    }

    func start(displayID: CGDirectDisplayID?, source: RTCVideoSource) async throws -> CGDirectDisplayID {
        let displays = try await Self.displays()
        guard let display = displays.first(where: { $0.displayID == displayID }) ?? displays.first else {
            throw CaptureError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        var width = Double(display.width) * Double(filter.pointPixelScale)
        var height = Double(display.height) * Double(filter.pointPixelScale)
        let maxWidth = 2560.0
        if width > maxWidth {
            height = height * maxWidth / width
            width = maxWidth
        }
        config.width = Int(width) & ~1
        config.height = Int(height) & ~1
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.showsCursor = true
        config.queueDepth = 6

        self.source = source
        capturer = RTCVideoCapturer(delegate: source)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        startRepeating()
        return display.displayID
    }

    func stop() {
        repeatTimer?.cancel()
        repeatTimer = nil
        stream?.stopCapture { _ in }
        stream = nil
        queue.async { self.lastBuffer = nil }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let buffer = sampleBuffer.imageBuffer else { return }
        lastBuffer = buffer
        deliver(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onStop?(error) }
    }

    // ScreenCaptureKit only sends frames when the screen changes. Repeat the last
    // one so newly joined viewers get a picture of a still screen.
    private func startRepeating() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self, let buffer = self.lastBuffer,
                  DispatchTime.now().uptimeNanoseconds - self.lastFrameTime.uptimeNanoseconds > 400_000_000 else { return }
            self.deliver(buffer)
        }
        timer.resume()
        repeatTimer = timer
    }

    private func deliver(_ buffer: CVPixelBuffer) {
        guard let source, let capturer else { return }
        lastFrameTime = .now()
        let timestamp = Int64(CACurrentMediaTime() * 1_000_000_000)
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: timestamp)
        source.capturer(capturer, didCapture: frame)
    }
}
