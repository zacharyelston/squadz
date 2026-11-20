# The squad wire format, core version 7

What crosses between a squad's devices. SquadKit (`swift/Sources/SquadKit`) is the reference implementation; any other implementation (Android, a browser, a relay that needs to route) follows this document, must read and write every message in [`testdata/wire/messages.json`](../testdata/wire/messages.json) exactly, and must derive every value in [`testdata/join/vectors.json`](../testdata/join/vectors.json).

Version 7 is the first version defined here. Versions up to 6 were BackyardBallistics' GroupKit, where golf messages and core messages shared one list and a shared join code was the only key. Nothing has shipped on version 7 yet, so joining by invite and credential (§7) was added to it without a new number.

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
| Bytes (`photo`, `data`, `payload`, keys, nonces, signatures) | Standard base64 with padding |
| Public keys | P-256, X9.63 uncompressed: 65 bytes starting `04` |
| Signatures | ECDSA P-256 with SHA-256, as 64 bytes: `r` then `s` |
| Places | `{"latitude": 42.36, "longitude": -71.06}`, degrees, WGS 84 |
| Distances, accuracy | Metres |
| Headings | Degrees clockwise from true north |
| Optional fields | Left out when absent, never `null` |

SquadKit writes keys in sorted order so the same message is always the same bytes. Readers must not depend on key order.

## 4. Messages

### Member → leader

| `type` | Body | Notes |
| --- | --- | --- |
| `link` | `id`, `proof` | The first frame on a link, for the transport: which key the device holds (§8). The squad's logic never sees it |
| `hello` | `name`, `device`, `nonce`, `role`?, `key`? | The first message after `link`. `nonce` is 16 fresh random bytes. `key` is the device's one-time public key, sent on an invite link only. `role` is `member` (the default), `observer` or `contributor`; a squad refuses a contributor, and on a credential link the credential's role is what counts |
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
| `enrolled` | `squad`, `name`, `role`, `credential`, `leader`, `signature`, `member`? | The answer to `hello` on an invite link (§7). The leader closes the link after it |
| `leaderKey` | `squad`, `key`, `time`, `signature` | The leader's device has a new identity key, signed by the old one (§7) |
| `welcome` | `member`, `squad` | The answer to `hello` on a member's credential link. The same credential is always the same `member` |
| `observing` | a squad | The answer to `hello` on an observer's credential link |
| `refused` | `reason` | Wrong version, an invite that is closed, a credential that was revoked, or not a role this host takes. The leader closes the link and the client stops trying |
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
- **`hello` on an invite link** (§7): checks `v`, the role, and that the invite is still open. The leader adds a new member (or notes a new observer), answers `enrolled` and closes the link. Every join is a new member whatever `device` says: a device ID proves nothing.
- **`hello` on a credential link:** the member and the role come from the credential, not from the `hello`. The leader sends any `leaderKey` changes, then `welcome`, then any orders for that member that are neither `done` nor `cannot` (the latest ten), then `status` to everyone.
- **A link that proved no key**, or a credential that was revoked, gets `refused`.
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

## 7. Joining

An invite lets a new device in once. The leader's device answers with a **credential** only that device can read, and from then on the device connects with the credential. The typed code and the invite stop mattering once a device is in, so they can be short-lived.

### What the leader's device keeps

- A **root key**: 32 random bytes, in its Keychain. It never leaves the device.
- An **identity key**: a P-256 signing key, in its Keychain. Its **fingerprint** is SHA-256 of the public key's 65 bytes.
- A **roster of credentials**: for each, its 16-byte ID, the member, the role, the epoch and whether it was revoked. No secrets, so it can be saved in a file.

A credential's secret is derived, not stored:

```
secret = HKDF-SHA256(key: root, salt: squad ID (16 bytes), info: "member" + credential ID (16 bytes) + epoch (4 bytes, big-endian), 32 bytes)
```

A squad ID as bytes is the UUID's 16 bytes in the order its text shows them.

### The invite

While joining is open the leader's device shows a QR code holding a link. The scheme is the app's (`squadz` for Squadz):

```
squadz://join?v=1&squad=<UUID>&name=<squad name>&enrol=<secret>&cmd=<fingerprint>&tag=<tag>&exp=<seconds>&by=<device name>
```

| Field | What it is |
| --- | --- |
| `v` | The invite's version, 1. Another value is refused |
| `squad` | The squad's ID |
| `name` | The squad's name, for display only |
| `enrol` | 16 random bytes, base64url without padding. The invite's secret |
| `cmd` | The fingerprint of the leader's identity key, 32 bytes, base64url without padding |
| `tag` | The first 4 bytes of SHA-256 of the squad ID's bytes, as 8 hex characters. Must match `squad` |
| `exp` | When it stops working, in seconds since 1970. The leader's default is 15 minutes |
| `by` | Optional. The leader's device name, for display only |

- **Scan, then confirm.** The app shows "Join *name* led by *by*?" and joins only on a tap. It never joins on a scan alone and never reads the clipboard.
- **No long-term key is in the link.** `enrol` opens an invite link and nothing else.
- An invite is for everyone while it is open, or for one person: the first device to join with a one-person invite uses it up.
- The joining device refuses an expired invite itself, and the leader's device refuses it whatever the joining device's clock says.

The **typed code** (six characters) can be opened alongside for local Wi-Fi. It is about 30 bits, and a device that joins with it has no fingerprint to check the leader against, so it trusts whichever device holds the code and answers. A relay must not accept it.

### Joining, message by message

1. The device opens a link keyed by the invite (§8) and sends `hello` with a fresh `nonce` and `key`, the public half of a P-256 key it has just made for this join.
2. The leader's device makes a credential ID (16 random bytes), derives its secret, and seals the secret to the device:
   ```
   one-time = a new P-256 key
   shared   = ECDH(one-time, hello.key)            (the 32-byte x coordinate)
   k        = HKDF-SHA256(key: shared, salt: squad ID, info: "squad credential v1" + one-time public key + hello.key, 32 bytes)
   sealed   = AES-256-GCM(k, the secret, additional data: credential ID), as nonce (12) + ciphertext (32) + tag (16)
   ```
3. It answers `enrolled`: `squad`, `name`, `member` (absent for an observer), `role`, `credential` = `{id, epoch, issued, key: one-time public key, sealed}`, `leader` (its identity public key) and `signature`, by the identity key, over these bytes in order:
   ```
   "squad enrolled v1" + squad ID (16) + member ID (16; zeros for an observer) + role (1 byte: 0 member, 1 observer)
     + hello.nonce (16) + hello.key (65) + credential ID (16) + epoch (4, big-endian) + issued in milliseconds (8, big-endian)
     + one-time public key (65) + sealed (60)
   ```
   Then it closes the link.
4. The device checks, in this order, and joins only if all hold: the squad is the invite's; SHA-256 of `leader` is the invite's `cmd`; the signature is good (it covers this device's own nonce and key, so an answer given to anyone else fails); the credential opens. With a typed code there is no `cmd`, and the device pins the `leader` it was given.
5. The device keeps the credential in its Keychain (not synced, not in a backup that restores elsewhere) with the leader's public key, and opens a new link keyed by the credential.

Why the credential is sealed: the link's cipher has no forward secrecy, so anyone who has the invite and records the join could otherwise read the credential. Sealed, they can't. Someone with the invite can still join as themselves, which is what an invite is; the leader sees every device that joins and can remove it.

### After joining

- **Remove a member:** the credential is marked revoked. The leader sends `refused`, closes the link, and no longer holds that key, so the device can't connect again.
- **Reset the squad:** a new root key and the next epoch. Every credential stops working and the roster is emptied; everyone joins again. The identity key stays.
- **A new identity key:** the leader sends `leaderKey` to every device, and to each device that was away when it next connects, before `welcome`. The signature is by the key being replaced, over `"squad leader key v1" + squad ID (16) + new public key (65) + time in milliseconds (8, big-endian)`. A device follows only if its pinned key signed the change; anything else is ignored. Open invites are closed, because they name the old key.

## 8. The local link

Not part of the message format, but what SquadLink does under it, and what another implementation on the local network must match.

- The leader advertises a Bonjour service (`_squadz._tcp` for Squadz; each app has its own type) under the squad's name. TXT keys: `v`, the core version (a client that sees another `v` stops and says to update), and `tag`, the squad's tag (§7), which finds the squad again if it is renamed.
- TCP with TLS 1.2 pre-shared keys, cipher suite `TLS_PSK_WITH_AES_128_GCM_SHA256`.

Every link has a **link key** and a name for it, which is the TLS pre-shared key identity:

| Link | Identity | Link key |
| --- | --- | --- |
| A member's or observer's credential | `m:` + the credential ID in hex | `HKDF-SHA256(key: secret, salt: squad ID, info: "squad member link", 32 bytes)` |
| An invite | `e:` + the first 8 bytes of SHA-256 of `enrol`, in hex | `HKDF-SHA256(key: enrol, salt: squad ID, info: "squad enrol link", 32 bytes)` |
| The typed code | `code` | `HMAC-SHA256(key: the code, uppercased, without spaces or hyphens, message: "squad code link")` |

- The TLS pre-shared key is `HMAC-SHA256(key: link key, message: "<app> squad link")`, where `<app>` is the app's name (`Squadz`), so two apps never share a key.
- The leader's listener holds a key for every credential that isn't revoked, every invite that is open, and the typed code while it is open. A device whose key isn't there fails the TLS handshake.
- **The `link` frame.** The leader's TLS library picks the key by the identity but doesn't say which it picked, so the device's first frame says: `id` is the identity and `proof` is `HMAC-SHA256(key: link key, message: "squad link proof v1" + exporter)`, where `exporter` is 32 bytes of TLS exported keying material (RFC 5705) with the label `squad link v1` and no context. The leader checks the proof with the key it holds under that name and drops the link if it fails. A member can't name another member's credential, because it can't make that proof.
- A listener's keys are fixed when it starts. When the keys change (a device joined, a member was removed, joining opened or closed) the leader starts a new listener on the same port; links that are up stay up. A device that connects in that moment is refused and tries again.
- A device that has not connected within 8 seconds gives up that attempt. After a drop it retries with a delay that doubles from 1 second to 8. If the leader's device turns its credential down three times running without ever linking, it stops and says to ask for a new invite.

What this does not protect against: someone who holds a member's device, or the leader's. And the six-character code is only as strong as six characters; use the QR code.
