# Remote Desktop

Native remote desktop for macOS, with an iPhone/iPad viewer. Written in Swift.

- **Mac app** (`apple/macOS`, `apple/Shared`): shares a display with ScreenCaptureKit, streams it over WebRTC, and replays the viewer's mouse and keyboard with CGEvents. It's also a viewer for other Macs.
- **iOS app** (`apple/iOS`, `apple/Shared`): views and controls a Mac by touch.
- **Server** (`src/index.js`): a Cloudflare Worker with a Durable Object for each 9-digit computer ID. It only relays connection setup between devices. Video and input go directly between them. It also serves the download page in `public/`.

## Deploy the server

```sh
npm install
npx wrangler login
npx wrangler deploy
```

Then make the apps use it by default:

```sh
gh variable set RD_SERVER_URL --body "https://remote-desktop.<you>.workers.dev"
```

and re-run the **Build apps** workflow. Users can also set the address themselves: Settings (⌘,) on Mac, or the gear icon on iOS.

### TURN (recommended)

STUN alone fails on some corporate and mobile networks. Create a TURN key in the Cloudflare dashboard (Realtime → TURN), then:

```sh
npx wrangler secret put TURN_KEY_ID
npx wrangler secret put TURN_KEY_API_TOKEN
```

## Build the apps

```sh
brew install xcodegen
cd apple && xcodegen generate && open RemoteDesktop.xcodeproj
```

To test locally, run `npm run dev` and set the server to `http://localhost:8787` in the app's Settings.

`.github/workflows/apps.yml` builds a universal Mac app on every push to `main` that changes `apple/`, and publishes it as `RemoteDesktop-mac.zip` on the latest release. The download page links there.

The Mac build is ad-hoc signed, not notarized, so the first launch needs **Open Anyway** in System Settings → Privacy & Security. macOS also asks for Screen Recording and Accessibility again after each update. An Apple Developer ID and notarization fix both.

The iOS app is compiled in CI but not distributed. Installing it on a device needs an Apple Developer account (Xcode, TestFlight or the App Store).

## Security

- The host approves every viewer and can see their IP address and approximate location.
- After 10 wrong PINs the ID is locked until the host clicks **New ID & PIN**.
- Input is accepted only from accepted viewers, over their own encrypted WebRTC connection, and only while **Allow control** is on.

## Limitations

- Only Macs can be shared. Viewers can be a Mac, iPhone or iPad.
- No audio, file transfer or clipboard sync. **Send text** types text on the remote Mac.
- macOS keeps a few shortcuts for itself on the viewing Mac (⌘Tab, ⌘Space).
