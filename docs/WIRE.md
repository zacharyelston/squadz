# The squad wire format, core version 7

What crosses between a squad's devices. SquadKit (`swift/Sources/SquadKit`) is the reference implementation; any other implementation (Android, a browser, a relay that needs to route) follows this document and must read and write every message in [`testdata/wire/messages.json`](../testdata/wire/messages.json) exactly.

Version 7 is the first version defined here. Versions up to 6 were BackyardBallistics' GroupKit, where golf messages and core messages shared one list.

## 1. Frames

A stream of frames. Each frame is a 4-byte big-endian length, then that many bytes of UTF-8 JSON: one message.

- A frame longer than 1,048,576 bytes is refused and the link is closed.
- A frame that isn't valid JSON, has an unknown `type`, or lacks a required field is refused and the link is closed.
- Unknown fields are ignored.

The transport under the frames (local TLS today, a relay later) is not part of this document.

## 2. The envelope

```json
{"v": 7, "seq": 4, "type": "position", "body": { ... }}
```

| Field | Meaning |
| --- | --- |
| `v` | The core's version. A leader answers any message carrying another value with `refused` and does nothing else with it |
| `seq` | A count per sender per link, starting at 1 |
| `type` | One of the types in §4 |
| `body` | That type's body. `bye` has none |

**Who sent a message is the link it arrived on.** No field in a message says who it is from; where a body has one (`position.member`, `note.author`), the leader overwrites it.

## 3. Values

| Kind | On the wire |
| --- | --- |
| IDs (squad, member, device, order, note, file) | UUID strings. Swift writes them uppercase; accept any case and compare without regard to case |
| Times | Milliseconds since 1970-01-01 UTC, as a number |
| Bytes (`photo`, `data`, `payload`) | Standard base64 with padding |
| Places | `{"latitude": 42.36, "longitude": -71.06}`, degrees, WGS 84 |
| Distances, accuracy | Metres |
| Headings | Degrees clockwise from true north |
| Optional fields | Left out when absent, never `null` |

SquadKit writes keys in sorted order so the same message is always the same bytes. Readers must not depend on key order.

## 4. Messages

### Member → leader

| `type` | Body | Notes |
| --- | --- | --- |
| `hello` | `name`, `device`, `joinCode`, `role`? | First message on a link. `role` is `member` (the default), `observer` or `contributor`. A squad refuses a contributor |
| `bye` | none | Leaving. The member stays on the roster |
| `position` | `at`, `accuracy`, `time`, `heading`?, `member`? | `member` is ignored from a phone |
| `orderAck` | `order`, `response` | `seen`, `done` or `cannot`. Counted only from someone the order was for |
| `checkFire` | `id`, `by` | Anyone may call it. A repeated `id` is ignored |
| `note` | `id`, `author`, `time`, `text`, `field`?, `at`?, `accuracy`?, `photo`? | Text up to 500 characters; an inline photo up to 300,000 bytes |
| `fileOffer` | `id`, `kind`, `group`, `name`, `size`, `sha256`, `field`? | `kind` is `capture` or `notePhoto`. A squad's leader ignores files; they are for hosts that store them |
| `fileChunk` | `file`, `index`, `data` | Chunks of 262,144 bytes |
| `fileDone` | `file` | |

### Leader → member or observer

| `type` | Body | Notes |
| --- | --- | --- |
| `welcome` | `member`, `squad` | The answer to a member's `hello`. Rejoining with the same `device` gives the same `member` |
| `observing` | a squad | The answer to an observer's `hello` |
| `refused` | `reason` | Wrong version, wrong code, or not a role this host takes. The client stops trying |
| `status` | `revision`, `squad`, `holds`, `missions` | Sent to everyone whenever the squad changes |
| `order` | `id`, `kind`, `text`, `time`, `at`?, `to`? | No `to` means the whole squad. Text up to 140 characters |
| `receipt` | `id`, `status`, `detail` | What happened to a note or file: `received`, `stored` or `refused` |
| `positions` | `squad`, `positions` | To observers only |

### Either way

| `type` | Body | Notes |
| --- | --- | --- |
| `mission` | `id`, `version`, `payload` | A mission's own message (§6) |

### Shared shapes

- **Squad:** `id`, `name`, `members`.
- **Member:** `id`, `name`, `device`, `role`. The core's only role is `member`; a mission may define others. Show an unknown role as a plain member.
- **Hold:** `source`, `kind`, `text`, `member`?. `source` is `core` or a mission's ID. The core's only hold is `kind` `checkFire`. `text` is for people; show it for holds you don't recognise.
- **Order kinds:** the core's are `moveTo`, `holdPosition`, `capture` and `note`. A mission may add its own; show an unknown kind by its `text`.

## 5. What a leader does

- **Before `hello`:** everything from the link is ignored.
- **`hello`:** checks `v`, then the role, then `joinCode`. A member is added to the roster, or matched to an existing member by `device`. The leader answers `welcome`, then any orders for that member that are neither `done` nor `cannot` (the latest ten), then `status` to everyone.
- **An observer** gets `observing`, the mission's welcome payloads, a `status`, and the positions already known. After that it gets every `status`, `positions`, `order` and `note`. Nothing an observer sends has any effect, except `bye`.
- **Check fire** raises the core's hold. Only the leader's own device lifts it; no message does.
- **Holds** in a `status` are the core's and the mission's together. Nothing a mission or a message does removes a core hold.
- A message a member is not allowed to send (`welcome`, `status`, `order`, and so on) is ignored.

## 6. Missions

A mission has an ID (like `golf.firemission`) and its own version. Its messages travel as `mission` with an opaque `payload`, and its part of the squad's state travels in `status.missions` as `{id, version, payload}`.

- A leader hands a `mission` message to its mission only when **both** `id` and `version` match. Otherwise the message is ignored, and the sender is **not** refused: it is still a full member for everything in the core.
- A device ignores `mission` messages and status sections whose `id` it doesn't know or whose `version` it doesn't speak.
- So changing a mission bumps that mission's version and nobody else's. `v` changes only when §1 to §5 change.

A squad with no mission sends no mission sections and ignores every `mission` message.

## 7. The local link

Not part of the wire format, but what SquadLink does under it today:

- The leader advertises a Bonjour service (`_squadz._tcp` for Squadz; each app has its own type) under the squad's name, with a TXT key `v` holding the core version. A client that sees another `v` stops and says to update.
- TCP with TLS 1.2 pre-shared key, cipher suite `TLS_PSK_WITH_AES_128_GCM_SHA256`. The key is `HMAC-SHA256(key: join code, message: "<app> group link")`, where the code is uppercased with spaces and hyphens removed and `<app>` is the app's name (`Squadz`). The PSK identity is the app's name.
- A wrong code makes the handshake fail, or on some networks hang. A client that has not connected within 8 seconds gives up; if it had never been connected, it tells the user to check the code and stops.
- After a drop, a client that had been connected retries with a delay that doubles from 1 second to 8.

Join by QR and per-member credentials (issue #2, V2b) will replace the join code as the key. Until then a six-character code is all that protects a squad on its network.
