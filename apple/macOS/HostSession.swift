import AppKit
import ScreenCaptureKit
import WebRTC

/// The sharing side: captures a display, waits for viewers in the room,
/// streams to the ones the user accepts, and replays their input while
/// "Allow control" is on.
final class HostSession: NSObject, ObservableObject {
    struct Viewer: Identifiable {
        enum State { case pending, connecting, connected, relayed, failed }
        let id: String
        let place: String
        let ip: String
        var state: State
    }

    @Published private(set) var isSharing = false
    @Published private(set) var isStarting = false
    @Published private(set) var online = false
    @Published private(set) var locked = false
    @Published private(set) var viewers: [Viewer] = []
    @Published private(set) var room: String
    @Published private(set) var pin: String
    @Published var error: String?
    @Published var needsScreenPermission = false
    @Published private(set) var accessibilityTrusted = InputInjector.isTrusted
    @Published var displays: [SCDisplay] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var allowControl = false {
        didSet {
            signal?.send(["type": "control", "enabled": allowControl])
            if !allowControl { injector.releaseAll() }
            if allowControl && !accessibilityTrusted { InputInjector.requestTrust() }
        }
    }

    private var signal: SignalingClient?
    private var peers: [String: HostPeer] = [:]
    private let capturer = ScreenCapturer()
    private var videoTrack: RTCVideoTrack?
    private let injector = InputInjector()
    private var retryTimer: Timer?
    private var trustTimer: Timer?
    private var fatalCode: String?
    private let relayEncoder = RelayEncoder()
    /// Viewers receiving video through the Worker because a direct connection failed.
    private var relayViewers = Set<String>() {
        didSet { capturer.onFrame = relayViewers.isEmpty ? nil : { [weak self] in self?.relayEncoder.encode($0) } }
    }

    override init() {
        let defaults = UserDefaults.standard
        if let r = defaults.string(forKey: "hostRoom"), r.count == 9, let p = defaults.string(forKey: "hostPin") {
            room = r
            pin = p
        } else {
            (room, pin) = Self.newCredentials()
        }
        super.init()
        capturer.onStop = { [weak self] _ in self?.stop() }
        relayEncoder.onPacket = { [weak self] packet, isKey in
            DispatchQueue.main.async { self?.sendRelayPacket(packet, isKey: isKey) }
        }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let trusted = InputInjector.isTrusted
            if trusted != self.accessibilityTrusted { self.accessibilityTrusted = trusted }
        }
    }

    // MARK: - Lifecycle

    @MainActor
    func loadDisplays() async {
        guard CGPreflightScreenCaptureAccess() else { return }
        displays = (try? await ScreenCapturer.displays()) ?? []
        if selectedDisplayID == nil || !displays.contains(where: { $0.displayID == selectedDisplayID }) {
            selectedDisplayID = displays.first(where: { $0.displayID == CGMainDisplayID() })?.displayID ?? displays.first?.displayID
        }
    }

    @MainActor
    func start() async {
        error = nil
        guard let server = AppConfig.serverURL else {
            error = "Set the server address in Settings first."
            return
        }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            needsScreenPermission = true
            return
        }
        needsScreenPermission = false
        isStarting = true
        defer { isStarting = false }
        do {
            let source = RTC.factory.videoSource()
            videoTrack = RTC.factory.videoTrack(with: source, trackId: "screen")
            injector.displayID = try await capturer.start(displayID: selectedDisplayID, source: source)
            isSharing = true
            connect(server: server)
        } catch {
            self.error = "Couldn't capture the screen: \(error.localizedDescription)"
            needsScreenPermission = !CGPreflightScreenCaptureAccess()
        }
    }

    func stop() {
        guard isSharing else { return }
        isSharing = false
        retryTimer?.invalidate()
        signal?.close()
        signal = nil
        closeAllPeers()
        capturer.stop()
        videoTrack = nil
        injector.releaseAll()
        online = false
        allowControl = false
    }

    func resetCredentials() {
        (room, pin) = Self.newCredentials()
        guard isSharing, let server = AppConfig.serverURL else { return }
        signal?.close()
        closeAllPeers()
        connect(server: server)
    }

    private static func newCredentials() -> (String, String) {
        let digits = "0123456789", letters = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
        let room = String("123456789".randomElement()!) + String((0..<8).map { _ in digits.randomElement()! })
        let pin = String((0..<6).map { _ in letters.randomElement()! })
        UserDefaults.standard.set(room, forKey: "hostRoom")
        UserDefaults.standard.set(pin, forKey: "hostPin")
        return (room, pin)
    }

    // MARK: - Signaling

    private func connect(server: URL) {
        retryTimer?.invalidate()
        fatalCode = nil
        let signal = SignalingClient(server: server, room: room, query: ["role": "host", "pin": pin])
        signal.onMessage = { [weak self] in self?.handle($0, server: server) }
        signal.onClose = { [weak self] in self?.signalClosed(server: server) }
        self.signal = signal
    }

    private func signalClosed(server: URL) {
        online = false
        closeAllPeers()
        guard isSharing else { return }
        if fatalCode == "replaced" {
            stop()
            error = "Sharing was started from another window."
            return
        }
        if fatalCode == "in-use" { (room, pin) = Self.newCredentials() }
        retryTimer = Timer.scheduledTimer(withTimeInterval: fatalCode == "in-use" ? 0 : 2, repeats: false) { [weak self] _ in
            self?.connect(server: server)
        }
    }

    private func handle(_ msg: [String: Any], server: URL) {
        switch msg["type"] as? String {
        case "hello":
            online = true
            locked = false
            signal?.send(["type": "control", "enabled": allowControl])
        case "error":
            fatalCode = msg["code"] as? String
        case "replaced":
            fatalCode = "replaced"
        case "locked":
            locked = true
        case "viewer-joined":
            guard let id = msg["id"] as? String else { return }
            let info = msg["info"] as? [String: String] ?? [:]
            let place = [info["city"], info["region"], info["country"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            viewers.append(Viewer(id: id, place: place.isEmpty ? "Unknown location" : place, ip: info["ip"] ?? "", state: .pending))
            NSApp.requestUserAttention(.informationalRequest)
        case "viewer-left":
            if let id = msg["from"] as? String ?? msg["id"] as? String { removePeer(id) }
        case "signal":
            guard let from = msg["from"] as? String, let data = msg["data"] as? [String: Any] else { return }
            peers[from]?.handleSignal(data)
        case "relay-request":
            guard let from = msg["from"] as? String, let peer = peers[from] else { return }
            peer.close()
            relayViewers.insert(from)
            relayEncoder.requestKeyFrame()
            setState(from, .relayed)
        case "input":
            guard let from = msg["from"] as? String, relayViewers.contains(from),
                  allowControl, accessibilityTrusted, let event = msg["ev"] as? [String: Any] else { return }
            injector.handle(event)
        default:
            break
        }
    }

    // MARK: - Viewers

    func accept(_ id: String) {
        guard let server = AppConfig.serverURL, let track = videoTrack, peers[id] == nil else { return }
        setState(id, .connecting)
        signal?.send(["type": "accept", "to": id])
        let peer = HostPeer(id: id, track: track)
        peer.sendSignal = { [weak self] data in self?.signal?.send(["type": "signal", "to": id, "data": data]) }
        peer.onState = { [weak self] state in self?.setState(id, state) }
        peer.onInput = { [weak self] event in
            guard let self, self.allowControl, self.accessibilityTrusted else { return }
            self.injector.handle(event)
        }
        peers[id] = peer
        Task { @MainActor in await peer.start(server: server) }
    }

    func disconnect(_ id: String) {
        signal?.send(["type": "kick", "to": id])
        removePeer(id)
    }

    private func sendRelayPacket(_ packet: Data, isKey: Bool) {
        guard let signal, !relayViewers.isEmpty else { return }
        // Drop frames rather than fall behind; the next keyframe catches viewers up.
        if signal.pendingBinarySends > 6 {
            if isKey { relayEncoder.requestKeyFrame() }
            return
        }
        signal.send(packet)
    }

    private func removePeer(_ id: String) {
        relayViewers.remove(id)
        peers.removeValue(forKey: id)?.close()
        viewers.removeAll { $0.id == id }
        if peers.isEmpty { injector.releaseAll() }
    }

    private func closeAllPeers() {
        for peer in peers.values { peer.close() }
        peers.removeAll()
        relayViewers.removeAll()
        relayEncoder.stop()
        viewers.removeAll()
        injector.releaseAll()
    }

    private func setState(_ id: String, _ state: Viewer.State) {
        guard let i = viewers.firstIndex(where: { $0.id == id }) else { return }
        if viewers[i].state == .relayed && state != .relayed { return }  // the closed direct connection reporting in
        viewers[i].state = state
    }
}

/// One accepted viewer: a peer connection carrying the screen track and an
/// "input" data channel.
final class HostPeer: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    let id: String
    var sendSignal: ([String: Any]) -> Void = { _ in }
    var onState: (HostSession.Viewer.State) -> Void = { _ in }
    var onInput: ([String: Any]) -> Void = { _ in }

    private let track: RTCVideoTrack
    private var pc: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var closed = false
    private var pendingCandidates: [RTCIceCandidate] = []
    private var hasRemoteDescription = false

    init(id: String, track: RTCVideoTrack) {
        self.id = id
        self.track = track
    }

    @MainActor
    func start(server: URL) async {
        guard let pc = await RTC.peerConnection(server: server, delegate: self), !closed else { return }
        self.pc = pc
        pc.add(track, streamIds: ["screen"])
        let config = RTCDataChannelConfiguration()
        config.isOrdered = true
        channel = pc.dataChannel(forLabel: "input", configuration: config)
        channel?.delegate = self
        do {
            let offer = try await pc.createOffer()
            try await pc.setLocal(offer)
            sendSignal(["sdp": RTC.json(offer)])
        } catch {
            onState(.failed)
        }
    }

    func handleSignal(_ data: [String: Any]) {
        if let sdp = RTC.sessionDescription(data["sdp"]) {
            Task { @MainActor in
                guard let pc = self.pc else { return }
                try? await pc.setRemote(sdp)
                self.hasRemoteDescription = true
                for c in self.pendingCandidates { pc.add(c) { _ in } }
                self.pendingCandidates.removeAll()
                self.tuneBitrate()
            }
        } else if let candidate = RTC.candidate(data["candidate"]) {
            if let pc, hasRemoteDescription { pc.add(candidate) { _ in } } else { pendingCandidates.append(candidate) }
        }
    }

    func close() {
        closed = true
        channel?.close()
        pc?.close()
        pc = nil
    }

    private func tuneBitrate() {
        guard let sender = pc?.senders.first(where: { $0.track?.kind == "video" }) else { return }
        let params = sender.parameters
        for encoding in params.encodings { encoding.maxBitrateBps = NSNumber(value: 8_000_000) }
        params.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainResolution.rawValue)
        sender.parameters = params
    }

    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        DispatchQueue.main.async {
            switch newState {
            case .connected: self.onState(.connected)
            case .failed: self.onState(.failed)
            case .disconnected, .connecting, .new: self.onState(.connecting)
            default: break
            }
        }
    }

    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        DispatchQueue.main.async { self.sendSignal(["candidate": RTC.json(candidate)]) }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let event = RTC.decode(buffer) else { return }
        DispatchQueue.main.async { if !self.closed { self.onInput(event) } }
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
