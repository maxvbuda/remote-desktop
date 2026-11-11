import Foundation
import WebRTC

/// The viewing side: joins a room, receives the screen and sends input over
/// the "input" data channel the host opens.
final class ViewerSession: NSObject, ObservableObject, Identifiable {
    enum Phase: Equatable {
        case connecting, waiting, starting, live, interrupted
        case ended(String)
    }

    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var controlAllowed = false
    @Published private(set) var videoTrack: RTCVideoTrack?

    let room: String
    private let pin: String
    private let server: URL
    private var signal: SignalingClient?
    private var pc: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var endMessage: String?
    private var pendingCandidates: [RTCIceCandidate] = []
    private var hasRemoteDescription = false

    var canControl: Bool { controlAllowed && phase == .live && channel?.readyState == .open }

    init(room: String, pin: String, server: URL) {
        self.room = room
        self.pin = pin
        self.server = server
        super.init()
        let signal = SignalingClient(server: server, room: room, query: ["role": "viewer", "pin": pin])
        signal.onMessage = { [weak self] in self?.handle($0) }
        signal.onClose = { [weak self] in
            guard let self else { return }
            self.end(self.endMessage ?? "Lost the connection to the server.")
        }
        self.signal = signal
    }

    func disconnect() { end("Disconnected.") }

    func send(_ event: [String: Any]) {
        guard canControl, let buffer = RTC.encode(event) else { return }
        channel?.sendData(buffer)
    }

    var statusText: String {
        switch phase {
        case .connecting: return "Connecting…"
        case .waiting: return "Waiting for the other computer to accept…"
        case .starting: return "Starting the stream…"
        case .live: return ""
        case .interrupted: return "Connection interrupted, trying to recover…"
        case .ended(let message): return message
        }
    }

    private func handle(_ msg: [String: Any]) {
        switch msg["type"] as? String {
        case "error": endMessage = msg["message"] as? String
        case "hello": phase = .waiting
        case "accepted": phase = .starting
        case "rejected": endMessage = "The other computer ended the connection."
        case "host-left": endMessage = "The other computer stopped sharing."
        case "status": controlAllowed = (msg["control"] as? Bool) ?? false
        case "signal": handleSignal(msg["data"] as? [String: Any] ?? [:])
        default: break
        }
    }

    private func handleSignal(_ data: [String: Any]) {
        if let sdp = RTC.sessionDescription(data["sdp"]) {
            Task { @MainActor in
                do {
                    if self.pc == nil { self.pc = await RTC.peerConnection(server: self.server, delegate: self) }
                    guard let pc = self.pc, !self.isEnded else { return }
                    try await pc.setRemote(sdp)
                    self.hasRemoteDescription = true
                    for c in self.pendingCandidates { pc.add(c) { _ in } }
                    self.pendingCandidates.removeAll()
                    if sdp.type == .offer {
                        let answer = try await pc.createAnswer()
                        try await pc.setLocal(answer)
                        self.signal?.send(["type": "signal", "data": ["sdp": RTC.json(answer)]])
                    }
                } catch {
                    self.end("Couldn't start the stream (\(error.localizedDescription)).")
                }
            }
        } else if let candidate = RTC.candidate(data["candidate"]) {
            if let pc, hasRemoteDescription { pc.add(candidate) { _ in } } else { pendingCandidates.append(candidate) }
        }
    }

    private var isEnded: Bool { if case .ended = phase { return true } else { return false } }

    private func end(_ message: String) {
        guard !isEnded else { return }
        signal?.close()
        signal = nil
        channel?.close()
        channel = nil
        pc?.close()
        pc = nil
        videoTrack = nil
        phase = .ended(message)
    }
}

extension ViewerSession: RTCPeerConnectionDelegate {
    func peerConnection(_ pc: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        DispatchQueue.main.async { self.videoTrack = track }
    }

    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        DispatchQueue.main.async {
            guard !self.isEnded else { return }
            switch newState {
            case .connected: self.phase = .live
            case .disconnected: self.phase = .interrupted
            case .failed: self.end("Couldn't connect directly. Ask the owner to set up a TURN server (see the README).")
            default: break
            }
        }
    }

    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        DispatchQueue.main.async {
            self.signal?.send(["type": "signal", "data": ["candidate": RTC.json(candidate)]])
        }
    }

    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        DispatchQueue.main.async {
            self.channel = dataChannel
            dataChannel.delegate = self
            self.objectWillChange.send()
        }
    }

    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
}

extension ViewerSession: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {}
}
