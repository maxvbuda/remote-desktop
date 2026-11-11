#!/usr/bin/env python3
"""
Remote Desktop Helper.

Runs on the computer being shared and replays the mouse and keyboard events
sent by viewers the host approved, but only while "Allow viewers to control
this computer" is switched on in the host tab.

Double-click the packaged app (or run this file with no arguments) for the
window. Paste the helper code from the share page and click Connect.

Command-line use:
    python3 remote_helper.py <helper code>
    python3 remote_helper.py https://your-worker.workers.dev 123456789 ABC234
"""
import argparse
import asyncio
import json
import pathlib
import platform
import queue
import re
import subprocess
import sys
import threading
import time
import urllib.parse

SYSTEM = platform.system()
APP_NAME = "Remote Desktop Helper"
CONFIG_PATH = pathlib.Path.home() / ".remote-desktop-helper.json"

# A helper code looks like "remote-desktop.you.workers.dev/123456789/ABC234".
# Local dev servers keep their scheme: "http://localhost:8787/123456789/ABC234".
CODE_RE = re.compile(r"^\s*(?:(https?)://)?([\w.-]+(?::\d+)?)/(\d{9})/([A-Za-z0-9]{4,32})\s*/?$")


def parse_code(text):
    m = CODE_RE.match(text or "")
    if not m:
        return None
    scheme, host, room, pin = m.groups()
    ws = "ws" if scheme == "http" else "wss"
    query = urllib.parse.urlencode({"role": "agent", "pin": pin.upper()})
    return f"{ws}://{host}/ws/{room}?{query}"


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


def mac_accessibility_trusted(prompt=False):
    """macOS only lets apps with Accessibility permission control the mouse and keyboard."""
    if SYSTEM != "Darwin":
        return True
    try:
        from ApplicationServices import AXIsProcessTrustedWithOptions, kAXTrustedCheckOptionPrompt
        return bool(AXIsProcessTrustedWithOptions({kAXTrustedCheckOptionPrompt: prompt}))
    except Exception:
        return True


def open_mac_accessibility_settings():
    subprocess.run(["open", "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"])


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


async def run(url, injector, report):
    """Stay connected to the room, retrying until a fatal error or cancellation.

    report(state, message) is called with state in:
    connecting | waiting | connected | input | error (fatal; run returns).
    """
    import websockets

    while True:
        report("connecting", "Connecting…")
        try:
            async with websockets.connect(url, ping_interval=None, max_size=2**20, open_timeout=15) as ws:
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
                            report("input", "")
                        elif kind == "hello":
                            report("connected", "Connected")
                        elif kind == "host-left":
                            injector.release_all()
                            report("waiting", "The share page closed. Waiting for it to come back…")
                        elif kind == "error":
                            if msg.get("code") in ("bad-pin", "locked", "bad-request"):
                                report("error", msg.get("message") or "Connection refused.")
                                return
                            report("waiting", "Waiting for the share page to start sharing…")
                finally:
                    pinger.cancel()
                    injector.release_all()
        except asyncio.CancelledError:
            raise
        except Exception as err:
            report("waiting", f"Can't reach the server, retrying… ({err.__class__.__name__})")
        await asyncio.sleep(3)


class Connection:
    """Runs run() on a background thread so the window stays responsive."""

    def __init__(self, url, injector, report):
        self.loop = asyncio.new_event_loop()
        self.task = self.loop.create_task(run(url, injector, report))
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        asyncio.set_event_loop(self.loop)
        try:
            self.loop.run_until_complete(self.task)
        except asyncio.CancelledError:
            pass
        finally:
            self.loop.close()

    def stop(self):
        try:
            self.loop.call_soon_threadsafe(self.task.cancel)
        except RuntimeError:
            pass  # loop already finished


def load_config():
    try:
        return json.loads(CONFIG_PATH.read_text())
    except Exception:
        return {}


def save_config(cfg):
    try:
        CONFIG_PATH.write_text(json.dumps(cfg))
    except Exception:
        pass


def run_gui(region):
    import tkinter as tk
    from tkinter import ttk

    root = tk.Tk()
    root.title(APP_NAME)
    root.resizable(False, False)
    events = queue.Queue()
    state = {"conn": None, "status": "idle", "last_input": 0.0}
    injector = Injector(region)
    cfg = load_config()

    frame = ttk.Frame(root, padding=20)
    frame.grid()

    ttk.Label(frame, text=APP_NAME, font=("TkDefaultFont", 16, "bold")).grid(row=0, column=0, columnspan=3, sticky="w")
    ttk.Label(
        frame,
        text="Lets people you approve on the share page use your mouse and keyboard.",
        wraplength=380,
    ).grid(row=1, column=0, columnspan=3, sticky="w", pady=(4, 14))

    ttk.Label(frame, text="Helper code (from the share page):").grid(row=2, column=0, columnspan=3, sticky="w")
    code_var = tk.StringVar(value=cfg.get("code", ""))
    entry = ttk.Entry(frame, textvariable=code_var, width=44)
    entry.grid(row=3, column=0, columnspan=2, sticky="we", pady=(4, 0))

    def paste():
        try:
            code_var.set(root.clipboard_get().strip())
        except tk.TclError:
            pass

    ttk.Button(frame, text="Paste", command=paste).grid(row=3, column=2, padx=(6, 0), pady=(4, 0))

    status_canvas = tk.Canvas(frame, width=14, height=14, highlightthickness=0)
    status_canvas.grid(row=4, column=0, sticky="w", pady=(16, 0))
    dot = status_canvas.create_oval(2, 2, 12, 12, fill="#8b96a5", outline="")
    status_var = tk.StringVar(value="Not connected")
    ttk.Label(frame, textvariable=status_var, wraplength=340).grid(row=4, column=0, columnspan=3, sticky="w", padx=(20, 0), pady=(16, 0))

    connect_btn = ttk.Button(frame, text="Connect")
    connect_btn.grid(row=5, column=0, columnspan=3, sticky="we", pady=(14, 0))

    access_frame = ttk.Frame(frame)
    access_frame.grid(row=6, column=0, columnspan=3, sticky="we", pady=(14, 0))
    ttk.Label(
        access_frame,
        text="macOS needs your permission: in Accessibility settings, turn on “Remote Desktop Helper”. "
             "If it's already on, turn it off and on again.",
        wraplength=380,
        foreground="#b47e00",
    ).grid(row=0, column=0, sticky="w")
    ttk.Button(access_frame, text="Open Accessibility settings", command=open_mac_accessibility_settings).grid(
        row=1, column=0, sticky="w", pady=(6, 0))

    ttk.Label(frame, text="Closing this window turns remote control off.", foreground="#8b96a5").grid(
        row=7, column=0, columnspan=3, sticky="w", pady=(14, 0))

    colors = {"idle": "#8b96a5", "connecting": "#e5a50a", "waiting": "#e5a50a",
              "connected": "#34c77b", "active": "#4f7cff", "error": "#f05252"}

    def set_status(status, message):
        state["status"] = status
        status_var.set(message)
        status_canvas.itemconfigure(dot, fill=colors.get(status, "#8b96a5"))
        connect_btn.configure(text="Connect" if status in ("idle", "error") else "Disconnect")

    def report(status, message):
        events.put((status, message))

    def connect(auto=False):
        url = parse_code(code_var.get())
        if not url:
            if not auto:
                set_status("error", "That doesn't look like a helper code. Copy it from the share page and paste it here.")
            return
        cfg["code"] = code_var.get().strip()
        save_config(cfg)
        state["conn"] = Connection(url, injector, report)

    def disconnect():
        if state["conn"]:
            state["conn"].stop()
            state["conn"] = None
        injector.release_all()
        set_status("idle", "Not connected")

    def toggle():
        if state["conn"] and state["status"] not in ("idle", "error"):
            disconnect()
        else:
            connect()

    connect_btn.configure(command=toggle)
    entry.bind("<Return>", lambda _e: toggle())

    def pump():
        while True:
            try:
                status, message = events.get_nowait()
            except queue.Empty:
                break
            if status == "input":
                state["last_input"] = time.monotonic()
                if state["status"] != "active":
                    set_status("active", "Someone is controlling this computer right now.")
            else:
                if status == "connected":
                    message = "Connected. Viewers can control this computer while the share page allows it."
                if status == "error":
                    state["conn"] = None
                set_status(status, message)
        if state["status"] == "active" and time.monotonic() - state["last_input"] > 3:
            set_status("connected", "Connected. Viewers can control this computer while the share page allows it.")
        if SYSTEM == "Darwin":
            if mac_accessibility_trusted():
                access_frame.grid_remove()
            else:
                access_frame.grid()
        root.after(150, pump)

    def on_close():
        disconnect()
        root.destroy()

    root.protocol("WM_DELETE_WINDOW", on_close)

    if SYSTEM == "Darwin":
        mac_accessibility_trusted(prompt=True)
    else:
        access_frame.grid_remove()

    # If the share page's code is on the clipboard, use it; otherwise reuse the last one.
    try:
        clip = root.clipboard_get().strip()
        if parse_code(clip):
            code_var.set(clip)
    except tk.TclError:
        pass
    connect(auto=True)

    root.after(150, pump)
    root.lift()
    root.attributes("-topmost", True)
    root.after(500, lambda: root.attributes("-topmost", False))
    root.mainloop()


def run_cli(url, region):
    def report(status, message):
        if status == "input":
            return
        print(message)
        if status == "error":
            sys.exit(1)

    print(f"Screen region: {region}")
    try:
        asyncio.run(run(url, Injector(region), report))
    except KeyboardInterrupt:
        pass


def main():
    parser = argparse.ArgumentParser(description=APP_NAME)
    parser.add_argument("target", nargs="*", help="helper code, or: SERVER_URL ID PIN")
    parser.add_argument("--region", help="Shared screen bounds X,Y,WIDTH,HEIGHT (default: main display)")
    # macOS passes -psn_… when launching apps from Finder on older versions.
    args, _unknown = parser.parse_known_args()

    enable_dpi_awareness()
    try:
        import pynput  # noqa: F401
        import websockets  # noqa: F401
    except ImportError:
        sys.exit("Missing dependencies. Run: pip3 install websockets pynput")

    region = tuple(float(v) for v in args.region.split(",")) if args.region else main_screen()
    if len(region) != 4:
        sys.exit("--region must be X,Y,WIDTH,HEIGHT")

    if not args.target:
        return run_gui(region)
    if len(args.target) == 3:
        server, room, pin = args.target
        server = server if "://" in server else "https://" + server
        base = urllib.parse.urlparse(server)
        code = f"{'http://' if base.scheme == 'http' else ''}{base.netloc}/{''.join(c for c in room if c.isdigit())}/{pin}"
    else:
        code = args.target[0]
    url = parse_code(code)
    if not url:
        sys.exit("Invalid helper code.")
    run_cli(url, region)


if __name__ == "__main__":
    main()
