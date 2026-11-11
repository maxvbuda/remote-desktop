import AppKit

/// Captures mouse and keyboard over the remote picture and sends them as
/// InputInjector messages (macOS virtual key codes, CGEventFlags).
final class MacRemoteView: RemoteVideoContainer {
    private var pressedKeys = Set<UInt16>()
    private var trackingArea: NSTrackingArea?

    // Modifier key code → flag, used to tell press from release in flagsChanged.
    private static let modifierFlags: [UInt16: NSEvent.ModifierFlags] = [
        54: .command, 55: .command, 56: .shift, 60: .shift,
        58: .option, 61: .option, 59: .control, 62: .control,
        57: .capsLock, 63: .function,
    ]

    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    private func location(_ e: NSEvent, clamp: Bool) -> CGPoint? {
        normalized(convert(e.locationInWindow, from: nil), clamp: clamp)
    }

    // MARK: Mouse

    override func mouseMoved(with e: NSEvent) { sendMove(e, clamp: false) }
    override func mouseDragged(with e: NSEvent) { sendMove(e, clamp: true) }
    override func rightMouseDragged(with e: NSEvent) { sendMove(e, clamp: true) }
    override func otherMouseDragged(with e: NSEvent) { sendMove(e, clamp: true) }

    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); sendButton(e, 0, down: true) }
    override func mouseUp(with e: NSEvent) { sendButton(e, 0, down: false) }
    override func rightMouseDown(with e: NSEvent) { window?.makeFirstResponder(self); sendButton(e, 2, down: true) }
    override func rightMouseUp(with e: NSEvent) { sendButton(e, 2, down: false) }
    override func otherMouseDown(with e: NSEvent) { sendButton(e, 1, down: true) }
    override func otherMouseUp(with e: NSEvent) { sendButton(e, 1, down: false) }

    private func sendMove(_ e: NSEvent, clamp: Bool) {
        guard canControl, let p = location(e, clamp: clamp) else { return }
        send(["t": "move", "x": p.x, "y": p.y])
    }

    private func sendButton(_ e: NSEvent, _ button: Int, down: Bool) {
        guard canControl, let p = location(e, clamp: !down) else { return }
        send(["t": down ? "down" : "up", "b": button, "x": p.x, "y": p.y, "c": e.clickCount])
    }

    override func scrollWheel(with e: NSEvent) {
        guard canControl else { return }
        let scale = e.hasPreciseScrollingDeltas ? 1.0 : 10.0
        send(["t": "scroll", "dx": e.scrollingDeltaX * scale, "dy": e.scrollingDeltaY * scale])
    }

    // MARK: Keyboard

    private func flags(_ e: NSEvent) -> UInt { e.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue }

    override func keyDown(with e: NSEvent) {
        guard canControl else { return super.keyDown(with: e) }
        pressedKeys.insert(e.keyCode)
        send(["t": "key", "k": Int(e.keyCode), "d": true, "f": flags(e)])
    }

    override func keyUp(with e: NSEvent) {
        guard canControl else { return super.keyUp(with: e) }
        pressedKeys.remove(e.keyCode)
        send(["t": "key", "k": Int(e.keyCode), "d": false, "f": flags(e)])
    }

    override func flagsChanged(with e: NSEvent) {
        guard canControl, let flag = Self.modifierFlags[e.keyCode] else { return super.flagsChanged(with: e) }
        let down = e.modifierFlags.contains(flag)
        send(["t": "key", "k": Int(e.keyCode), "d": down, "f": flags(e)])
        // macOS doesn't deliver keyUp for keys pressed while ⌘ is held; release them with ⌘.
        if flag == .command && !down {
            for code in pressedKeys { send(["t": "key", "k": Int(code), "d": false, "f": flags(e)]) }
            pressedKeys.removeAll()
        }
    }

    // ⌘ shortcuts go to the remote Mac instead of this app's menus while controlling.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard canControl, window?.firstResponder === self, e.type == .keyDown else {
            return super.performKeyEquivalent(with: e)
        }
        keyDown(with: e)
        return true
    }

    override func resignFirstResponder() -> Bool {
        if !pressedKeys.isEmpty || canControl { send(["t": "reset"]) }
        pressedKeys.removeAll()
        return super.resignFirstResponder()
    }
}
