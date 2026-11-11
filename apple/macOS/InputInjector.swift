import ApplicationServices
import CoreGraphics

/// Replays viewer input on this Mac with CGEvents.
/// Requires Accessibility permission (AXIsProcessTrusted).
///
/// Messages: move {x,y} · down/up {b,x,y,c} · scroll {dx,dy} · key {k,d,f} · text {s} · reset
/// x/y are 0...1 on the shared display, k is a macOS virtual key code, f are CGEventFlags.
final class InputInjector {
    var displayID: CGDirectDisplayID = CGMainDisplayID()

    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttons = Set<Int>()
    private var keys = Set<CGKeyCode>()
    private var lastPoint = CGPoint.zero
    private var scrollRemainder = CGPoint.zero

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func handle(_ m: [String: Any]) {
        switch m["t"] as? String {
        case "move": move(to: point(m))
        case "down": mouse(button: int(m, "b"), down: true, at: point(m), clicks: int(m, "c", 1))
        case "up": mouse(button: int(m, "b"), down: false, at: point(m), clicks: int(m, "c", 1))
        case "scroll": scroll(dx: num(m, "dx"), dy: num(m, "dy"))
        case "key": key(CGKeyCode(clamping: int(m, "k")), down: (m["d"] as? Bool) ?? false, flags: UInt64(clamping: int(m, "f")))
        case "text": type((m["s"] as? String) ?? "")
        case "reset": releaseAll()
        default: break
        }
    }

    func releaseAll() {
        for k in keys { post(CGEvent(keyboardEventSource: source, virtualKey: k, keyDown: false)) }
        for b in buttons { mouse(button: b, down: false, at: lastPoint, clicks: 1) }
        keys.removeAll()
        buttons.removeAll()
    }

    // MARK: - Mouse

    private func point(_ m: [String: Any]) -> CGPoint {
        let bounds = CGDisplayBounds(displayID)
        let x = min(1, max(0, num(m, "x"))), y = min(1, max(0, num(m, "y")))
        return CGPoint(x: bounds.minX + x * (bounds.width - 1), y: bounds.minY + y * (bounds.height - 1))
    }

    private func move(to p: CGPoint) {
        lastPoint = p
        let (type, button): (CGEventType, CGMouseButton) =
            buttons.contains(0) ? (.leftMouseDragged, .left) :
            buttons.contains(2) ? (.rightMouseDragged, .right) :
            buttons.contains(1) ? (.otherMouseDragged, .center) : (.mouseMoved, .left)
        post(CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button))
    }

    private func mouse(button b: Int, down: Bool, at p: CGPoint, clicks: Int) {
        let type: CGEventType
        let button: CGMouseButton
        switch b {
        case 2: (type, button) = (down ? .rightMouseDown : .rightMouseUp, .right)
        case 1: (type, button) = (down ? .otherMouseDown : .otherMouseUp, .center)
        default: (type, button) = (down ? .leftMouseDown : .leftMouseUp, .left)
        }
        lastPoint = p
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clicks)))
        event.post(tap: .cghidEventTap)
        if down { buttons.insert(b) } else { buttons.remove(b) }
    }

    private func scroll(dx: Double, dy: Double) {
        scrollRemainder.x += dx
        scrollRemainder.y += dy
        let x = Int32(scrollRemainder.x.rounded(.towardZero)), y = Int32(scrollRemainder.y.rounded(.towardZero))
        guard x != 0 || y != 0 else { return }
        scrollRemainder.x -= Double(x)
        scrollRemainder.y -= Double(y)
        post(CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
    }

    // MARK: - Keyboard

    private func key(_ code: CGKeyCode, down: Bool, flags: UInt64) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        event.flags = CGEventFlags(rawValue: flags)
        event.post(tap: .cghidEventTap)
        if down { keys.insert(code) } else { keys.remove(code) }
    }

    private func type(_ text: String) {
        let units = Array(text.prefix(5000).utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 20, units.count)])
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event.post(tap: .cghidEventTap)
            }
            i += 20
        }
    }

    // MARK: - Helpers

    private func post(_ event: CGEvent?) { event?.post(tap: .cghidEventTap) }
    private func num(_ m: [String: Any], _ k: String) -> Double { (m[k] as? NSNumber)?.doubleValue ?? 0 }
    private func int(_ m: [String: Any], _ k: String, _ fallback: Int = 0) -> Int { (m[k] as? NSNumber)?.intValue ?? fallback }
}
