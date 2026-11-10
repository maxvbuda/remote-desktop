#!/usr/bin/env python3
"""
Remote Desktop control agent.

Runs on the computer being shared. It connects to your Worker and replays the
mouse and keyboard events sent by viewers you approved, but only while
"Allow viewers to control this computer" is switched on in the host tab.

    pip3 install websockets pynput
    python3 agent.py https://your-worker.workers.dev 123456789 ABC234

Use --region X,Y,WIDTH,HEIGHT if you shared a screen other than the main one.
"""
import argparse
import asyncio
import json
import platform
import sys
import time
import urllib.parse

SYSTEM = platform.system()


def enable_dpi_awareness():
    # Without this, Windows reports scaled sizes and clicks land in the wrong place.
    if SYSTEM != "Windows":
        return
    import ctypes
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(2)
    except Exception:
        try:
            ctypes.windll.user32.SetProcessDPIAware()
        except Exception:
            pass


def main_screen():
    """Main display bounds in the coordinate space pynput uses."""
    if SYSTEM == "Darwin":
        import Quartz
        b = Quartz.CGDisplayBounds(Quartz.CGMainDisplayID())
        return 0, 0, b.size.width, b.size.height
    if SYSTEM == "Windows":
        import ctypes
        u = ctypes.windll.user32
        return 0, 0, u.GetSystemMetrics(0), u.GetSystemMetrics(1)
    from Xlib import display
    s = display.Display().screen()
    return 0, 0, s.width_in_pixels, s.height_in_pixels


class Injector:
    DOUBLE_CLICK_SECONDS = 0.5

    def __init__(self, region):
        from pynput.keyboard import Controller as Keyboard, Key, KeyCode
        from pynput.mouse import Button, Controller as Mouse

        self.Key, self.KeyCode = Key, KeyCode
        self.mouse, self.kb = Mouse(), Keyboard()
        self.region = region
        self.buttons_map = {0: Button.left, 1: Button.middle, 2: Button.right}
        self.pressed_keys = {}
        self.pressed_buttons = set()
        self.last_click = (0.0, None, 0)

        names = {
            "Enter": "enter", "Backspace": "backspace", "Tab": "tab", "Escape": "esc", " ": "space",
            "ArrowUp": "up", "ArrowDown": "down", "ArrowLeft": "left", "ArrowRight": "right",
            "Shift": "shift", "Control": "ctrl", "Alt": "alt", "AltGraph": "alt_gr", "Meta": "cmd", "OS": "cmd",
            "CapsLock": "caps_lock", "Delete": "delete", "Home": "home", "End": "end",
            "PageUp": "page_up", "PageDown": "page_down", "Insert": "insert", "ContextMenu": "menu",
            "PrintScreen": "print_screen", "ScrollLock": "scroll_lock", "Pause": "pause", "NumLock": "num_lock",
            "AudioVolumeUp": "media_volume_up", "AudioVolumeDown": "media_volume_down",
            "AudioVolumeMute": "media_volume_mute", "MediaPlayPause": "media_play_pause",
            "MediaTrackNext": "media_next", "MediaTrackPrevious": "media_previous",
        }
        names.update({f"F{i}": f"f{i}" for i in range(1, 21)})
        self.named = {k: getattr(Key, v) for k, v in names.items() if hasattr(Key, v)}
        codes = {"ShiftRight": "shift_r", "ControlRight": "ctrl_r", "AltRight": "alt_r", "MetaRight": "cmd_r"}
        self.by_code = {k: getattr(Key, v) for k, v in codes.items() if hasattr(Key, v)}

    def point(self, ev):
        x0, y0, w, h = self.region
        x = min(1.0, max(0.0, float(ev.get("x", 0))))
        y = min(1.0, max(0.0, float(ev.get("y", 0))))
        return x0 + x * (w - 1), y0 + y * (h - 1)

    def resolve(self, ev):
        code, key = str(ev.get("code", "")), str(ev.get("key", ""))
        if code in self.by_code:
            return self.by_code[code]
        if key in self.named:
            return self.named[key]
        # With modifiers held, use the physical key so Ctrl/⌘/Alt shortcuts work
        # even when the viewer's layout turns e.g. Alt+C into "ç".
        if ev.get("ctrl") or ev.get("alt") or ev.get("meta"):
            if code.startswith("Key") and len(code) == 4:
                return self.KeyCode.from_char(code[3].lower())
            if code.startswith("Digit") and len(code) == 6:
                return self.KeyCode.from_char(code[5])
        if len(key) == 1:
            return self.KeyCode.from_char(key)
        return None

    def handle(self, ev):
        kind = ev.get("e")
        if kind == "move":
            self.mouse.position = self.point(ev)
        elif kind == "down":
            button = self.buttons_map.get(ev.get("b"))
            if not button:
                return
            if "x" in ev:
                self.mouse.position = self.point(ev)
            if SYSTEM == "Darwin":
                # macOS needs an explicit click count for double/triple clicks.
                now = time.monotonic()
                t, last_button, count = self.last_click
                count = count + 1 if button == last_button and now - t < self.DOUBLE_CLICK_SECONDS else 1
                self.last_click = (now, button, count)
                self.mouse._click = count - 1
            self.mouse.press(button)
            self.pressed_buttons.add(button)
        elif kind == "up":
            button = self.buttons_map.get(ev.get("b"))
            if button in self.pressed_buttons:
                if "x" in ev:
                    self.mouse.position = self.point(ev)
                self.mouse.release(button)
                self.pressed_buttons.discard(button)
        elif kind == "wheel":
            self.mouse.scroll(int(ev.get("dx", 0)), -int(ev.get("dy", 0)))
        elif kind == "kd":
            key = self.resolve(ev)
            if key is not None:
                self.kb.press(key)
                self.pressed_keys[ev.get("code") or ev.get("key")] = key
        elif kind == "ku":
            key = self.pressed_keys.pop(ev.get("code") or ev.get("key"), None)
            if key is not None:
                self.kb.release(key)
        elif kind == "text":
            self.kb.type(str(ev.get("text", ""))[:5000])
        elif kind == "reset":
            self.release_all()

    def release_all(self):
        for key in list(self.pressed_keys.values()):
            try:
                self.kb.release(key)
            except Exception:
                pass
        for button in list(self.pressed_buttons):
            try:
                self.mouse.release(button)
            except Exception:
                pass
        self.pressed_keys.clear()
        self.pressed_buttons.clear()


async def keepalive(ws):
    while True:
        await asyncio.sleep(20)
        await ws.send("ping")


async def run(url, injector):
    import websockets

    waiting_shown = False
    while True:
        try:
            async with websockets.connect(url, ping_interval=None, max_size=2**20) as ws:
                pinger = asyncio.create_task(keepalive(ws))
                try:
                    async for raw in ws:
                        if raw == "pong":
                            continue
                        try:
                            msg = json.loads(raw)
                        except ValueError:
                            continue
                        kind = msg.get("type")
                        if kind == "input":
                            try:
                                injector.handle(msg)
                            except Exception as err:
                                print(f"Input error: {err}", file=sys.stderr)
                        elif kind == "hello":
                            waiting_shown = False
                            print("Connected. Viewers can control this computer while the host allows it.")
                        elif kind == "host-left":
                            injector.release_all()
                            print("Host stopped sharing. Waiting for it to come back…")
                        elif kind == "error":
                            if msg.get("code") in ("bad-pin", "locked", "bad-request"):
                                sys.exit(f"Refused: {msg.get('message')}")
                            if not waiting_shown:
                                print("Waiting for the host tab to start sharing…")
                                waiting_shown = True
                finally:
                    pinger.cancel()
                    injector.release_all()
        except (OSError, asyncio.TimeoutError) as err:
            print(f"Connection failed ({err}); retrying…", file=sys.stderr)
        except Exception as err:
            if isinstance(err, SystemExit):
                raise
            print(f"Disconnected ({err}); retrying…", file=sys.stderr)
        await asyncio.sleep(3)


def main():
    parser = argparse.ArgumentParser(description="Remote Desktop control agent")
    parser.add_argument("server", help="Your Worker URL, e.g. https://remote-desktop.you.workers.dev")
    parser.add_argument("room", help="9-digit computer ID shown in the host tab")
    parser.add_argument("pin", help="PIN shown in the host tab")
    parser.add_argument("--region", help="Shared screen bounds X,Y,WIDTH,HEIGHT (default: main display)")
    args = parser.parse_args()

    enable_dpi_awareness()
    try:
        import pynput  # noqa: F401
        import websockets  # noqa: F401
    except ImportError:
        sys.exit("Missing dependencies. Run: pip3 install websockets pynput")

    region = tuple(float(v) for v in args.region.split(",")) if args.region else main_screen()
    if len(region) != 4:
        sys.exit("--region must be X,Y,WIDTH,HEIGHT")

    base = urllib.parse.urlparse(args.server if "://" in args.server else "https://" + args.server)
    scheme = "ws" if base.scheme in ("http", "ws") else "wss"
    room = "".join(c for c in args.room if c.isdigit())
    query = urllib.parse.urlencode({"role": "agent", "pin": args.pin.upper()})
    url = f"{scheme}://{base.netloc}/ws/{room}?{query}"

    print(f"Screen region: {region}")
    print(f"Connecting to {base.netloc}, computer {room}…")
    try:
        asyncio.run(run(url, Injector(region)))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
