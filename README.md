# Squadz

The home of any squad: a core that every app can use, with missions as add-ons.

A squad is a leader's device and its members' phones. Members share positions, get orders, send notes and can call check fire; the leader's device runs the squad and decides everything. What the squad is out doing (a round of golf, a search, a ski tour) is a **mission**, added on top without changing the core.

The plan is [issue #2](https://github.com/zacharyelston/squadz/issues/2). This is steps V1, V2 and V2b of it. The original Squadz (a Rust server and a web page) is the tag `v1`.

| Part | Where | Status |
| --- | --- | --- |
| **SquadKit**: the squad protocol and the leader's state. Join, roster, positions, orders, notes, files, check fire, holds, missions. No network code | [`swift/Sources/SquadKit`](swift/Sources/SquadKit) | Built and tested |
| **SquadLink**: SquadKit over the local network (Bonjour, TLS keyed per member) | [`swift/Sources/SquadLink`](swift/Sources/SquadLink) | Built; tested on one Mac's loopback only |
| **CoreGeo**: GPS points and small-area geometry | [`swift/Sources/CoreGeo`](swift/Sources/CoreGeo) | Built |
| The wire format, for implementations in other languages | [`docs/WIRE.md`](docs/WIRE.md), [`testdata/wire`](testdata/wire) | Written, with vectors |
| Join by QR, member credentials, the leader's identity key | SquadKit (`Credentials.swift`, `Invite.swift`), SquadLink, [`testdata/join`](testdata/join) | Built and tested on one Mac's loopback. No app scans or shows a QR code yet |
| A Squadz phone app | | Not started |
| Relay for squads over the internet | | Not started (V3) |

SquadKit and SquadLink come from GroupKit and GroupLink in [BackyardBallistics](https://github.com/zacharyelston/BackyardBallistics), with golf taken out. BackyardBallistics does not use this package yet; [`docs/BACKYARDBALLISTICS.md`](docs/BACKYARDBALLISTICS.md) lists what it has to change to do so.

## Using it

```swift
import SquadKit
import SquadLink

// The leader's device. Its keys come from the Keychain, the rest from where the app saves it.
let keychain = SquadKeychain(service: "com.example.squadz.squads")
var squad = SquadCore(squad: Squad(name: "Red"), mission: NoMission())
try keychain.save(squad.keys, for: squad.squadID)
let host = try SquadLinkHost(name: "Red", keys: [], txt: [SquadService.Key.tag: squad.squadID.tag])
func send(_ out: [Outgoing]) {
    host.send(out)
    host.setKeys(squad.linkKeys(now: Date()))   // who may connect may have changed
}
host.onOpened = { peer, identity in squad.linkOpened(peer, identity: identity) }
host.onMessage = { message, peer in send(squad.handle(message, from: peer, now: Date())) }
host.onPeerClosed = { squad.peerClosed($0) }
host.start()

// Open joining and show this as a QR code.
let link = squad.openJoining(now: Date(), by: "Leader's iPad").url(scheme: SquadService.squadz.scheme)
host.setKeys(squad.linkKeys(now: Date()))

// A member's phone: scan, show "Join Red led by Leader's iPad?", and only on a tap:
let invite = try SquadInvite(url: scanned, scheme: SquadService.squadz.scheme)
let enroller = SquadEnroller(invite: invite, name: "Ana", device: deviceID)
enroller.onDone = { result in
    guard case let .success(credential) = result else { return /* say why */ }
    try? keychain.save(credential)
    let client = SquadLinkClient(credential: credential, name: "Ana", device: deviceID)
    client.onMessage = { message in /* .welcome, .status, .order, ... */ }
    client.start()
}
enroller.start()
client.send(.position(MemberPosition(at: here, accuracy: 5, time: Date())))
```

A mission is a type that conforms to `Mission`; see [`Mission.swift`](swift/Sources/SquadKit/Mission.swift) and the `RallyMission` in the tests.

## Rules that don't change

- The leader's device is the authority. Nothing else runs a squad or decides anything.
- Holds only add. The core unions its holds with the mission's; nothing a mission or a message does can lift a core hold. A fuzz test pins it.
- A message's sender is the link it arrived on, never a field in the message.
- No secrets, hostnames, team IDs or account details in the source.

## Tests

```bash
cd swift && swift test
```
