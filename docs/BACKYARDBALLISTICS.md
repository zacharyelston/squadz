# Moving BackyardBallistics onto SquadKit

What BackyardBallistics has to change to depend on this package (issue #2, V1, V2 and V2b). Nothing in BackyardBallistics has been changed yet; this is the list for that PR.

Written against BackyardBallistics `origin/main` at `d6afe77`.

## The package

- Add this repository as a package dependency, pinned to a tag, and depend on `SquadKit`, `SquadLink` and `CoreGeo`.
- Delete `Sources/CoreGeo` from SpudCore: `Geo.swift` here is the same file. Targets that import CoreGeo take it from this package.
- GroupKit keeps the golf: `GolfMission.swift`, `GroupGate.swift`, the golf message types, and `CourseFingerprint` (it was in `Wire.swift`). It deletes `Mission.swift`, `SquadCore.swift`, `Loopback.swift`, and the core parts of `Messages.swift`, `Wire.swift` and `FieldNotes.swift`.
- GroupLink goes away. Pass `SquadService(type: "_spudgolf._tcp", app: "SpudGunGolf", scheme: "spudgolf")` to SquadLink's types: that keeps the Bonjour type, and makes invites `spudgolf://join?…` links. The TLS keys are new (see "Joining" below), so a v6 app and a v7 app can't link; they couldn't anyway, since v7 refuses v6.

## Names

| GroupKit / GroupLink | SquadKit / SquadLink |
| --- | --- |
| `GroupProtocol.version` (6) | `SquadProtocol.version` (7), the core only |
| `GroupMessage`, `GroupMessage.Body` | `SquadMessage`, `SquadMessage.Body` |
| `GroupWire` | `SquadWire` |
| `.squadStatus`, `.fieldNote` | `.status`, `.note` |
| `.positions(squad:, [...])` | `.positions(PositionsReport)` |
| `FieldNote.courseID`, `FileOffer.courseID` | `field` |
| `GroupConnection`, `GroupHost`, `GroupClient`, `GroupBrowser` | `SquadConnection`, `SquadLinkHost`, `SquadLinkClient`, `SquadBrowser` |
| `GroupService.type` | `SquadService.type`, per app |
| `CoreView.player` | `squad.name` |

## Golf becomes a mission on the wire

These bodies leave the core and become golf's own payloads inside `.mission(id: "golf.firemission", version:, payload:)`: `lock`, `spot`, `fired`, `fieldSubmission`, `course`, `spotRequest`, `lockReceipt`. Golf defines one Codable enum for them and encodes it as the payload.

`GolfMission` then conforms to the new `Mission`:

| Was | Now |
| --- | --- |
| `handle(_ body: GroupMessage.Body, ...) -> MissionStep?` | `handle(_ payload: Data, ...) -> MissionStep`. Decode the golf enum; return `.none` for one that doesn't apply |
| `observerWelcome(core:) -> [GroupMessage.Body]` (the course) | `-> [Data]`: golf payloads |
| `fill(_ status: inout SquadStatus, ...)` | `status(core:now:) -> Data?`: golf's own status struct (`hole`, `phase`, `walkingOut`, `missions`, `rounds`, `roundInFlight`, `total`, `toPar`). Phones read it with `status.mission("golf.firemission", version:)` |
| Sending a golf body: `Outgoing(to:, .spotRequest(...))` | `Outgoing.mission(GolfMission.self, to:, payload)` |
| `SquadCore.run` was internal | It is public |
| `core.mission` was `internal(set)` | It is settable. A mission still can't lift a core hold |

## Types that changed shape

- **`Hold`** is a struct (`source`, `kind`, `member`, `text`), not an enum. `.checkFire(by:)` is still there as a static function. Golf builds its own: `Hold(source: GolfMission.id, kind: "walkingOut", text: ...)`, and likewise `memberInFan` and `positionUnknown` with `member` set. `GroupGate` keeps working on `Set<Hold>`; it sorts by `description`, which is the hold's text.
- **`MemberRole`** is an open type. Golf adds `static let gunner = MemberRole(rawValue: "gunner")` in an extension.
- **`Order.Kind`** is an open type. The core keeps `moveTo`, `holdPosition`, `capture`, `note`. Golf adds `rangeFrom`, `spot` and `returnToFiringPoint` in an extension, lists them in `GolfMission.orderKinds`, and supplies their titles (`coreTitle` is nil for them).
- **`SquadStatus`** has `revision`, `squad`, `holds`, `missions`. The golf fields moved into golf's section.
- **`SquadID`, `MemberID`** travel as bare UUID strings instead of `{"raw": ...}`. `PeerID` is no longer Codable; it never crossed the wire.
- **The envelope** is `{"v", "seq", "type", "body"}` instead of Swift's synthesized enum coding. Anything that stored `GroupMessage`s on disk needs a migration or a clean start.

## Tests

Issue #2 asks that every GroupKit, GroupLink and safety test passes "unchanged". With V2's wire change that can't be literal. What should hold:

- Every test's **assertions** stay as they are. Only construction changes: golf bodies wrapped as mission payloads, `Hold` values built with the new initialiser, the renames above.
- `SquadCoreTests` and the GroupLink tests move here (they are already here, adapted) and leave BackyardBallistics.
- `SafetyPropertyTests` stays in BackyardBallistics in full. Its `samples()` should cover every golf payload as well as every core body, so "no message carries firing data" and the unlock fuzz still scan the whole protocol. This repo's fuzz covers only the core: no message lifts a hold.
- `TheaterKit` uses the core's notes, files, receipts and `Hello.Role.contributor`. Those are all still in the core; it needs only the renames.

## Not decided here

- Whether `SquadCore` should run several missions at once. It runs one, as in BackyardBallistics today; `status.missions` is already a list.
- `Hello.Role.contributor` and the file messages exist for the Theater host, which is not a squad. They may belong in a Theater mission or their own small protocol later.

## Joining (V2b)

The shared join code is gone as a key. [`WIRE.md`](WIRE.md) §7 and §8 are the rules; in code:

- **The leader's iPad** keeps `LeaderKeys` in the Keychain (`SquadKeychain.save(_:for:)`) and saves `SquadCore.credentials`, `epoch` and `keyChanges` with the round (no secrets in them). `SquadCommand.Saved` drops the join code.
- **Wiring the host:** `host.onOpened` → `core.linkOpened`, and after every core call `host.setKeys(core.linkKeys(now:))`. `Outgoing.thenClose` is handled by `SquadLinkHost.send`.
- **"Open joining"** replaces showing the code: `core.openJoining(now:typedCode:by:)` returns the invite to draw as a QR code; `core.joinCode` is the typed code while it is open. `closeJoining()`, `inviteOne(now:)`.
- **A phone or the Theater** scans, confirms on a tap, runs `SquadEnroller`, saves the `MemberCredential` in the Keychain, and then runs `SquadLinkClient(credential:)`. Remembering codes locally goes away. The app needs the camera permission and must register the `spudgolf` scheme only if it wants links to open it; a scan needs neither a registered scheme nor the clipboard.
- **`Hello`** has no `joinCode`. `GroupClient`'s "check the code" stop becomes `SquadLinkClient.notAccepted` (ask for a new invite).
- **Remove member** now revokes: `removeMember` closes the link and the device can't come back. **Reset squad** is `resetSquad(now:)`.
- **The Theater door** (contributor credentials) is not in this package: it is a different host, and it can use `LeaderKeys`, `SealedCredential` and `LinkKey` the same way.
- Not done here: the LoRa epoch key and its re-key on removal (SQUAD_COMMS Part 2).

## Added since, in the core

Things the Squadz app needed that BackyardBallistics will find in the package when it moves over. Each is in [`WIRE.md`](WIRE.md).

- **`leave`** and **`notice`:** a member leaving for good is taken off the roster and everyone is told. `bye` still means the app is closing. `SquadLinkClient.stop(forGood:)` sends one or the other.
- **`orderCancel`:** `core.cancelOrder(_:now:)` takes an order back.
- **Shared notes:** `SquadCore.sharesNotes` passes each note to the other members, as `sharesPositions` does for positions. It is off unless asked for, so golf's notes still go to the leader and the Theater only.
- **`status.reportEvery`:** `core.setReportEvery(_:now:)` sets how often devices send positions. Golf's 15-second "no recent position" hold should stay above whatever rate it sets.
- **Sealed links:** a link through a relay is sealed between the two devices ([`WIRE.md`](WIRE.md) §9). Nothing to do in an app; SquadLink does it.
