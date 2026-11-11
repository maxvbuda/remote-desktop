import SwiftUI
import WebRTC

#if os(macOS)
import AppKit
typealias PlatformView = NSView
typealias PlatformVideoView = RTCMTLNSVideoView
#else
import UIKit
typealias PlatformView = UIView
typealias PlatformVideoView = RTCMTLVideoView
#endif

/// Shows the remote screen letterboxed (aspect fit) and maps local points to
/// 0...1 coordinates on the picture. Platform subclasses add input capture.
class RemoteVideoContainer: PlatformView, RTCVideoViewDelegate {
    let videoView = PlatformVideoView(frame: .zero)
    var send: ([String: Any]) -> Void = { _ in }
    var canControl = false

    var track: RTCVideoTrack? {
        didSet {
            guard oldValue !== track else { return }
            oldValue?.remove(videoView)
            track?.add(videoView)
        }
    }

    private var videoSize = CGSize.zero {
        didSet { layoutVideo() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        videoView.delegate = self
        addSubview(videoView)
        #if os(macOS)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        #else
        backgroundColor = .black
        videoView.isUserInteractionEnabled = false
        videoView.videoContentMode = .scaleAspectFit
        #endif
    }

    required init?(coder: NSCoder) { fatalError() }

    #if os(macOS)
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        layoutVideo()
    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        layoutVideo()
    }
    #endif

    var videoRect: CGRect {
        guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func layoutVideo() {
        videoView.frame = videoRect
    }

    /// `point` is in this view's coordinates (top-left origin on both platforms).
    func normalized(_ point: CGPoint, clamp: Bool) -> CGPoint? {
        let r = videoRect
        guard r.width > 0 else { return nil }
        var x = (point.x - r.minX) / r.width
        var y = (point.y - r.minY) / r.height
        if clamp {
            x = min(1, max(0, x))
            y = min(1, max(0, y))
        } else if x < 0 || x > 1 || y < 0 || y > 1 {
            return nil
        }
        return CGPoint(x: (x * 10000).rounded() / 10000, y: (y * 10000).rounded() / 10000)
    }

    func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        DispatchQueue.main.async { self.videoSize = size }
    }
}

#if os(macOS)
struct RemoteVideo: NSViewRepresentable {
    @ObservedObject var session: ViewerSession

    func makeNSView(context: Context) -> MacRemoteView { MacRemoteView(frame: .zero) }

    func updateNSView(_ view: MacRemoteView, context: Context) {
        view.track = session.videoTrack
        view.canControl = session.canControl
        view.send = { [weak session] in session?.send($0) }
        if session.canControl, view.window?.firstResponder !== view {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }
}
#else
struct RemoteVideo: UIViewRepresentable {
    @ObservedObject var session: ViewerSession
    @Binding var showKeyboard: Bool

    func makeUIView(context: Context) -> TouchRemoteView { TouchRemoteView(frame: .zero) }

    func updateUIView(_ view: TouchRemoteView, context: Context) {
        view.track = session.videoTrack
        view.canControl = session.canControl
        view.send = { [weak session] in session?.send($0) }
        DispatchQueue.main.async {
            if showKeyboard && session.canControl, !view.isFirstResponder { view.becomeFirstResponder() }
            if !showKeyboard, view.isFirstResponder { view.resignFirstResponder() }
        }
    }
}
#endif
