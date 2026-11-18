# Squadz

See where your squad is, with no internet needed.

One small server and a phone app. The server is built to run on a node of an OpenMANET Wi-Fi HaLow mesh; phones join a node's Wi-Fi and share positions through it.

- A phone joins by scanning a QR code. No accounts, no passwords.
- After that the app only talks to the server whose key was in that code (pinned TLS 1.3), so there is no certificate to accept and nothing to impersonate.
- Invites work once and expire after 10 minutes.
- Map tiles can come from the server, and phones keep them, so the map works off-grid.

| Part | Where | Status |
| --- | --- | --- |
| Server (Go) | [`server/`](server) | Works; tested locally and over pinned TLS in tests |
| iPhone app (SwiftUI) | [`ios/`](ios) | Works in the simulator; not yet run on a real phone |
| Android app | | Not started. It will implement [`docs/MOBILE_CLIENT.md`](docs/MOBILE_CLIENT.md) |
| Running on a mesh node | [`deploy/openmanet/`](deploy/openmanet/README.md) | Written, cross-compiles; not yet run on real hardware |

Pairing, pinning, device keys and sessions come from **PairKit**, a kit shared with other apps. It has no published version yet, so check it out next to this repository:

```
code/
  pairkit/
  squadz/
```

## Run it

Server (Go 1.26+):

```bash
cd server && go run .
```

It listens on `:8090` (plain HTTP: the operator's page, which shows a pairing code) and `:8443` (pinned TLS: everything the phones use), and keeps its key and state in `server/data/`.

App (Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)):

```bash
cd ios && xcodegen generate && open Squadz.xcodeproj
```

Then, with the app running in the simulator:

1. Type a name.
2. Open `http://127.0.0.1:8090/` on the Mac. The simulator has no camera, so copy the text under the code. The server only accepts it once and for 10 minutes.
3. Hand the code to the app as an invite link (pasting also works, after iOS asks you to allow it):

   ```bash
   xcrun simctl openurl booted "squadz://pair?c=$(pbpaste | base64 | tr '+/' '-_' | tr -d '=\n')"
   ```

4. Start a squad. **Invite** shows the code for the next phone.

On a real phone, scan the code on the server's page instead, using the address the phone reaches the server by (not `127.0.0.1`).

## Settings

Environment variables for the server:

| Variable | Default | Meaning |
| --- | --- | --- |
| `PORT` | `8090` | Plain HTTP: operator's page and health |
| `TLS_PORT` | `8443` | Pinned TLS: the app's API and map tiles |
| `TLS_HOSTS` | `localhost,127.0.0.1` | Names and addresses for the certificate. The first is used for the pairing code printed at startup |
| `DATA_DIR` | `data` | TLS key, paired devices, squads. **Losing `tls-key.pem` unpairs every phone** |
| `DASHBOARD_PASSWORD` | unset | Password for the operator's page (any user name). Unset means anyone who can reach it can pair |
| `TILES_DIR` | unset | Folder of map tiles as `{z}/{x}/{y}.png` |
| `TILE_MAX_ZOOM` | unset | Deepest zoom level in `TILES_DIR`; apps scale it up beyond that |
| `TILE_ATTRIBUTION` | `© OpenStreetMap` | Credit shown on the map |
| `LOCATION_TTL_SECS` | `300` | Seconds without a report before a member is shown as stale |
| `MAX_SQUAD_SIZE` | `50` | Members per squad |

## Tests

```bash
cd server && go test ./...
```

```bash
cd ios && xcodebuild -project Squadz.xcodeproj -scheme Squadz -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test
```

## Known limits

- Positions are shared only while the app is open. Background reporting is the next milestone.
- One server. If its node leaves the mesh, the squad stops updating until it is back.
- Phones poll every 10 seconds; there is no push or streaming.
- Squads and pairings survive a server restart; positions do not, and come back within a minute.
- A phone holds one pairing at a time.
- `.replit`, `replit.md` and `BUILD_NOTES.md` describe the earlier Rust and Next.js version, which this replaces.
