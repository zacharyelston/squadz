# Squadz Theater

A Mac watches squads as an **observer** and serves read-only browser views on the local network. Each browser window has its own squad and view URL, so a map, orders and notes can live on different monitors. No browser joins the squad directly.

Requires macOS 14+, Xcode command-line tools, and a leader running the observer updates in this change. No npm install, external Swift packages, cloud account or internet connection is needed.

```sh
swift run --package-path theater squadz-theater
```

Open <http://127.0.0.1:8765/> on the host Mac. Ask the leader to open joining, paste its invite link, and select **Join as observer**. Allow local-network access for the terminal if macOS asks. The leader's Team panel lists the host under **Observers · read only**, with its connection state and a Remove button. Invites use the existing enrollment policy; there is no extra leader approval prompt. Treat an invite as permission to observe the squad.

The host discovers leaders with Bonjour and uses SquadLink's authenticated, encrypted local connection. It always requests an observer credential, never a member credential. Relay details in invites and saved credentials are ignored. Other SquadKit apps can use `TheaterController` with their own `SquadService`; the supplied executable uses the Squadz service.

## Views

| Route after `/squads/{squad UUID}/` | Contents |
| --- | --- |
| `map` | Positions, heading arrows, order flags, labeled circle and polygon zones; pan, zoom and fit |
| `team` | Roster, connection state, position age and accuracy, coordinates, observers |
| `orders` | Orders, recipients, answers and cancellations |
| `notes` | Read-only field notes |
| `zones` | Definitions and confirmed goal arrivals / allowed-area departures |
| `video` | Stream metadata and an explicit leader-only notice; no camera frames |
| `dashboard` | Map with orders and latest notes |

Open the links in separate windows. Reloading keeps the selected squad and view. Existing `/wall` links also open Dashboard. Several squads can be watched at once (up to 16); each keeps its own link and state. Browser updates use SSE, with reconnects and a visible disconnected state. Last known positions remain visible when a link drops and fade when stale. Rejoining replays the leader's current state, latest 100 orders and latest 50 notes; it is not a mission-log archive.

The host exposes no API for orders, answers, notes, position reports, zone edits or video commands. Pairing and forgetting a watched squad are host-local administrative actions.

## Try it without phones

```sh
swift run --package-path theater squadz-theater --demo
```

This creates two labeled, ephemeral sample squads over real encrypted loopback links. Positions move every two seconds. It does not use saved credentials, write to Keychain, or start a camera. The same observer enrollment and browser transport are used as with a phone.

To inspect just the protocol state, with no HTTP listener:

```sh
swift run --package-path theater squadz-theater --invite-stdin --no-http
```

Paste an invite at the prompt and press Return. Do not put invite links in shell history. JSON snapshots print as updates arrive. `--endpoint 127.0.0.1:PORT` can target a local test leader without Bonjour; only explicit loopback/private IPv4 endpoints are supported.

## Local-network browser access

Loopback is the default. To let other devices on a trusted local network view the desk, bind the Mac's actual private IPv4 address:

```sh
swift run --package-path theater squadz-theater --bind 192.168.1.20 --port 8765
```

The process prints the LAN URL and a fresh view passcode. LAN browsers must enter it; sessions last eight hours and disappear when the process restarts. Invite pairing and forgetting are available **only** at the host's `127.0.0.1` page, never through the LAN listener. Wildcard and public bind addresses are refused.

LAN pages use HTTP: the passcode gates access but does not encrypt browser traffic. Use loopback unless the local network is trusted. This does not provide remote internet access, TLS termination, proxy deployment, or an observer relay. The Mac firewall may need local incoming access. No router forwarding is needed.

Observer credentials stay in macOS Keychain under `org.squadz.theater.observers`. The nonsecret squad index and device ID live under `~/Library/Application Support/SquadzTheater` (`--data-dir` overrides it). Restarting reconnects with those credentials. **Stop watching on this host** forgets the local credential; the leader can revoke the issued observer permanently with Remove. Never commit credentials or invite links.

## Offline maps

No map provider has been chosen. With no tiles configured, the map explicitly shows a coordinate grid; squad markers and zones still work. It never falls back to internet tiles, geocoding or a CDN.

Supply a directory of Web Mercator **XYZ PNG** tiles (`z/x/y.png`, 256 px) that you are entitled to use:

```sh
swift run --package-path theater squadz-theater \
  --tiles /absolute/path/to/tiles \
  --tile-attribution 'Your tile source and required credit' \
  --tile-max-zoom 18
```

TMS tile stores must be converted to XYZ first. Attribution stays on the map. Missing tiles leave the grid visible. The server restricts requests to the configured directory, zoom range and tile coordinates, and rejects files outside it (including escaping symlinks). Tile preparation/provider selection remains an explicit deployment choice.

## Validation and remaining scope

```sh
swift test --package-path swift
swift test --package-path theater
cd ios && xcodegen generate
xcodebuild -project Squadz.xcodeproj -scheme Squadz \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test
```

Tests cover observer enrollment and read-only enforcement, order history/answers, notes, positions, presence, leader revocation, independent squads, local shutdown, HTTP pages and SSE, request limits, host/origin checks, and LAN passcode expiry/rate limits. The iOS tests exercise visible observer state and removal through the native app model on simulator sockets. A standalone `--demo` run and browser views are also checked manually.

This implements issue #16's T1–T4. T5 remains a policy decision: VideoMission currently sends frames only to the leader, and Theater preserves that rule. No observer video sharing or recording is implemented. Real phone-to-Mac and second-device LAN acceptance remain to be checked on hardware; the automated transport checks run on one Mac and the iOS simulator.
