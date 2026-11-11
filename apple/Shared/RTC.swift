import Foundation
import WebRTC

enum RTC {
    static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    static let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

    static func peerConnection(server: URL, delegate: RTCPeerConnectionDelegate) async -> RTCPeerConnection? {
        let config = RTCConfiguration()
        config.iceServers = await iceServers(server: server)
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        return factory.peerConnection(with: config, constraints: constraints, delegate: delegate)
    }

    /// STUN by default; TURN when the Worker has Cloudflare TURN keys configured.
    static func iceServers(server: URL) async -> [RTCIceServer] {
        let fallback = [RTCIceServer(urlStrings: ["stun:stun.cloudflare.com:3478"])]
        guard let (data, _) = try? await URLSession.shared.data(from: server.appendingPathComponent("api/ice")),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = obj["iceServers"] as? [[String: Any]] else { return fallback }
        let servers = list.compactMap { entry -> RTCIceServer? in
            let urls = (entry["urls"] as? [String]) ?? (entry["urls"] as? String).map { [$0] } ?? []
            guard !urls.isEmpty else { return nil }
            return RTCIceServer(urlStrings: urls,
                                username: entry["username"] as? String,
                                credential: entry["credential"] as? String)
        }
        return servers.isEmpty ? fallback : servers
    }

    static func json(_ sdp: RTCSessionDescription) -> [String: Any] {
        ["type": RTCSessionDescription.string(for: sdp.type), "sdp": sdp.sdp]
    }

    static func sessionDescription(_ json: Any?) -> RTCSessionDescription? {
        guard let j = json as? [String: Any], let type = j["type"] as? String, let sdp = j["sdp"] as? String else { return nil }
        return RTCSessionDescription(type: RTCSessionDescription.type(for: type), sdp: sdp)
    }

    static func json(_ c: RTCIceCandidate) -> [String: Any] {
        ["candidate": c.sdp, "sdpMid": c.sdpMid ?? NSNull(), "sdpMLineIndex": c.sdpMLineIndex]
    }

    static func candidate(_ json: Any?) -> RTCIceCandidate? {
        guard let j = json as? [String: Any], let sdp = j["candidate"] as? String, !sdp.isEmpty else { return nil }
        let index = (j["sdpMLineIndex"] as? NSNumber)?.int32Value ?? 0
        return RTCIceCandidate(sdp: sdp, sdpMLineIndex: index, sdpMid: j["sdpMid"] as? String)
    }

    static func encode(_ object: [String: Any]) -> RTCDataBuffer? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return RTCDataBuffer(data: data, isBinary: false)
    }

    static func decode(_ buffer: RTCDataBuffer) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: buffer.data)) as? [String: Any]
    }
}

struct RTCFailure: Error {}

extension RTCPeerConnection {
    func createOffer() async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { c in
            offer(for: RTC.constraints) { sdp, error in
                if let sdp { c.resume(returning: sdp) } else { c.resume(throwing: error ?? RTCFailure()) }
            }
        }
    }

    func createAnswer() async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { c in
            answer(for: RTC.constraints) { sdp, error in
                if let sdp { c.resume(returning: sdp) } else { c.resume(throwing: error ?? RTCFailure()) }
            }
        }
    }

    func setLocal(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            setLocalDescription(sdp) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    func setRemote(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            setRemoteDescription(sdp) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }
}
