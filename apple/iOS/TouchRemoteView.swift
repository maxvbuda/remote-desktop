import UIKit

/// Touch control of the remote Mac: tap = click, double-tap = double-click,
/// touch and hold = right-click, drag = click and drag, two fingers = scroll.
/// As first responder it also takes on-screen keyboard typing.
final class TouchRemoteView: RemoteVideoContainer, UIKeyInput {
    private var lastTap: (time: TimeInterval, point: CGPoint, count: Int) = (0, .zero, 0)
    private var dragging = false

    // UITextInputTraits
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap))
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(onHold))
        hold.minimumPressDuration = 0.45
        let drag = UIPanGestureRecognizer(target: self, action: #selector(onDrag))
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.allowedScrollTypesMask = .all
        for g in [tap, hold, drag, scroll] { addGestureRecognizer(g) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func point(_ g: UIGestureRecognizer, clamp: Bool = false) -> CGPoint? {
        normalized(g.location(in: self), clamp: clamp)
    }

    private func click(_ p: CGPoint, button: Int, count: Int) {
        send(["t": "move", "x": p.x, "y": p.y])
        send(["t": "down", "b": button, "x": p.x, "y": p.y, "c": count])
        send(["t": "up", "b": button, "x": p.x, "y": p.y, "c": count])
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        guard canControl, let p = point(g) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let near = hypot(p.x - lastTap.point.x, p.y - lastTap.point.y) < 0.03
        let count = (now - lastTap.time < 0.4 && near) ? lastTap.count + 1 : 1
        lastTap = (now, p, count)
        click(p, button: 0, count: count)
    }

    @objc private func onHold(_ g: UILongPressGestureRecognizer) {
        guard canControl, g.state == .began, let p = point(g) else { return }
        click(p, button: 2, count: 1)
    }

    @objc private func onDrag(_ g: UIPanGestureRecognizer) {
        guard canControl else { return }
        switch g.state {
        case .began:
            let start = g.location(in: self) - g.translation(in: self)
            guard let p = normalized(start, clamp: false) else { return }
            dragging = true
            send(["t": "move", "x": p.x, "y": p.y])
            send(["t": "down", "b": 0, "x": p.x, "y": p.y, "c": 1])
            fallthrough
        case .changed:
            guard dragging, let p = point(g, clamp: true) else { return }
            send(["t": "move", "x": p.x, "y": p.y])
        case .ended, .cancelled, .failed:
            guard dragging else { return }
            dragging = false
            let p = point(g, clamp: true) ?? .zero
            send(["t": "up", "b": 0, "x": p.x, "y": p.y, "c": 1])
        default:
            break
        }
    }

    @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        guard canControl, g.state == .changed else { return }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        send(["t": "scroll", "dx": t.x * 2, "dy": t.y * 2])
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    func insertText(_ text: String) {
        guard canControl else { return }
        if text == "\n" {
            pressKey(36)  // Return
        } else {
            send(["t": "text", "s": text])
        }
    }

    func deleteBackward() {
        guard canControl else { return }
        pressKey(51)  // Delete (backspace)
    }

    private func pressKey(_ code: Int) {
        send(["t": "key", "k": code, "d": true, "f": 0])
        send(["t": "key", "k": code, "d": false, "f": 0])
    }
}

private func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
