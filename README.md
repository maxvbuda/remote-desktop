# Remote Desktop

Browser-based remote desktop on Cloudflare Workers.

- **Video:** peer-to-peer WebRTC screen share (`getDisplayMedia`). Video never passes through the Worker.
- **Signaling:** a Durable Object for each 9-digit computer ID (`src/index.js`).
- **Control:** browsers can't inject OS input, so `public/agent.py` runs on the shared computer. It replays mouse and keyboard events from viewers the host approved, and only while the host has control switched on.

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
2. For remote control, download `agent.py` from the host page and run the command it shows:
   `pip3 install websockets pynput && python3 agent.py https://<your-worker> <ID> <PIN>`
   On macOS, grant your terminal Accessibility permission.
3. On the other device, enter the ID and PIN. The host clicks **Accept**, then turns on **Allow viewers to control**.

## Security

- The host approves every viewer and can see their IP address and approximate location.
- After 10 wrong PINs the ID is locked until the host clicks **New ID & PIN**.
- Input is forwarded only from approved viewers, and only while control is on.
- When the host tab closes, all viewers and agents are disconnected.

## Limitations

- Control maps to the main display. If you share another monitor, use `--region X,Y,W,H`.
- The browser keeps some shortcuts for itself (for example ⌘Tab). Fullscreen in Chrome captures more of them.
- No file transfer or clipboard sync. The **Send text** button types text on the remote computer.
