import Foundation

/// WebSocket connection to the Room Durable Object on the Worker.
/// Callbacks are delivered on the main queue.
final class SignalingClient: NSObject, URLSessionWebSocketDelegate {
    var onMessage: (([String: Any]) -> Void)?
    var onClose: (() -> Void)?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var finished = false

    init(server: URL, room: String, query: [String: String]) {
        super.init()
        var comps = URLComponents(url: server.appendingPathComponent("ws/\(room)"), resolvingAgainstBaseURL: false)!
        comps.scheme = comps.scheme == "http" ? "ws" : "wss"
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        task = session.webSocketTask(with: comps.url!)
        task?.resume()
        receive()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.task?.send(.string("ping")) { _ in }
        }
    }

    func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    /// Closes without calling onClose.
    func close() {
        guard !finished else { return }
        finished = true
        pingTimer?.invalidate()
        task?.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    private func receive() {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.finished else { return }
                switch result {
                case .success(.string(let text)):
                    if text != "pong",
                       let data = text.data(using: .utf8),
                       let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        self.onMessage?(obj)
                    }
                    self.receive()
                case .success:
                    self.receive()
                case .failure:
                    self.finish()
                }
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish()
    }

    private func finish() {
        guard !finished else { return }
        close()
        onClose?()
    }
}
