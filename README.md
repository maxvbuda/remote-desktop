# Remote Desktop

Browser-based remote desktop on Cloudflare Workers.

- **Video:** peer-to-peer WebRTC screen share (`getDisplayMedia`). Video never passes through the Worker.
- **Signaling:** a Durable Object for each 9-digit computer ID (`src/index.js`).
- **Control:** browsers can't inject OS input, so a small helper app (`helper/remote_helper.py`) runs on the shared computer. It replays mouse and keyboard events from viewers the host approved, and only while the host has control switched on.

## Deploy

```sh
npm install
npx wrangler login
npm run deploy
```

Local dev: `npm run dev`.

### TURN (recommended)

STUN alone fails on some corporate and mobile networks. Create a TURN key under Cloudflare dashboard → Realtime → TURN, then:

```sh
npx wrangler secret put TURN_KEY_ID
npx wrangler secret put TURN_KEY_API_TOKEN
```

Note: `/api/ice` is public, so anyone can request TURN credentials that bill to your account.

## Use

1. On the computer you want to share, open the site and click **Start sharing**. Pick **Entire screen**.
2. For remote control, click **Download** on the share page, then **Copy helper code**, then open the helper app. It reads the code from the clipboard and connects. It also remembers the code for next time.
3. On the other device, enter the ID and PIN. The host clicks **Accept**, then turns on **Allow viewers to control**.

## Helper app builds

`.github/workflows/helper.yml` builds the helper with PyInstaller for Windows, macOS (Apple Silicon and Intel) and Linux. It runs on every push to `main` that changes `helper/`, and attaches the builds to the latest GitHub release. The share page links to `releases/latest/download/...` (`HELPER_RELEASES` in `public/app.js`), so **the repo must be public** for people to download them. Alternatively, point `HELPER_RELEASES` somewhere else.

The builds are unsigned, so Windows SmartScreen and macOS Gatekeeper show a warning the first time. The share page tells people how to get past it. Signing the builds (an Apple Developer ID, or a Windows code-signing certificate) removes the warning.

Without the app: `pip3 install -r helper/requirements.txt && python3 helper/remote_helper.py <helper code>`.

## Security

- The host approves every viewer and can see their IP address and approximate location.
- After 10 wrong PINs the ID is locked until the host clicks **New ID & PIN**.
- Input is forwarded only from approved viewers, and only while control is on.
- When the host tab closes, all viewers and agents are disconnected.

## Limitations

- Control maps to the main display. If you share another monitor, use `--region X,Y,W,H`.
- The browser keeps some shortcuts for itself (for example ⌘Tab). Fullscreen in Chrome captures more of them.
- No file transfer or clipboard sync. The **Send text** button types text on the remote computer.
