# Squadz mobile client contract

What every Squadz app must do. The iPhone app (`ios/Squadz`) is the reference implementation; the Android app implements this document, not the Swift code.

Pairing, the pinned connection, the device key and sessions are **PairKit**'s contract, in `SPEC.md` of the PairKit repository. This document covers only what Squadz adds. Section numbers like "PairKit §6" point there.

"Must" is a requirement. "Should" is the default.

## 1. The shape of it

- App ID: `squadz`. Connections are always **direct** (PairKit §3): the server is usually an OpenMANET mesh node reached by IP address, with no internet.
- A phone holds **one** pairing at a time. A pairing is one person on one server, in at most one squad.
- There is no web client. The old `mobile.html` could not pin the server or hold a device key.

## 2. Getting in

Every way in is a PairKit pairing code (PairKit §2). There are two kinds, and the app can't tell them apart until it redeems one:

| Code from | Result |
| --- | --- |
| The server's own page, `http://<server>:8090/`, or its log | Paired with the server, in no squad. The person can start one |
| A member's **Invite** screen | Paired and already in that member's squad |

The app must offer three ways to hand it a code:

1. **Scan** the QR (iOS: VisionKit `DataScannerViewController`).
2. **Paste** the code's text from the clipboard.
3. **Open an invite link**: `squadz://pair?c=<base64url of the code's text, no padding>`. If the app doesn't know the person's name yet, it keeps the code until they have typed one.

Before pairing, the app must have a display name: 1 to 40 characters after trimming and collapsing spaces. It is sent as `name` in the redeem request and is what the squad sees.

The redeem answer (PairKit §5) adds:

```json
{"name": "Ana", "squad": null}
```

`squad` is the squad object (§3) when the invite was for one.

Squadz's own refusals at redemption; none of them spends the invite:

| Status, `code` | Show |
| --- | --- |
| 400 `bad_name` | The name must be 1 to 40 characters |
| 409 `name_taken` | Someone in that squad already uses that name |
| 409 `squad_full` | That squad is full |
| 410 `squad_gone` | That squad no longer exists |

Pairing while already paired: pair with the new code first, and only when that succeeds sign out of the old pairing (PairKit §6) and delete it.

## 3. Routes

All over the pinned connection, all with the bearer token except health. Errors are `{"error", "code"}`.

| Route | Body | Answer |
| --- | --- | --- |
| `GET /api/v1/health` | | `{"status": "ok", "app": "squadz"}`. No token |
| `GET /api/v1/me` | | Me (below) |
| `POST /api/v1/squads` | `{"name"}` | 201, the new squad. 409 `in_squad` if already in one |
| `POST /api/v1/squad/invites` | | 201 `{"qr_payload": "<code text>", "expires_in": 600}`. 409 `no_squad` |
| `POST /api/v1/squad/leave` | | 204 |
| `PUT /api/v1/location` | Position (below) | 204. 409 `no_squad`, 400 `bad_position` |
| `GET /api/v1/squad/locations` | | `{"squad": {...}, "locations": [...]}`. 409 `no_squad` |
| `GET /tiles/{z}/{x}/{y}.png` | | A map tile, when the server has them |

Me:

```json
{"device_id": "Y5o_MFRmgk80", "name": "Ana",
 "squad": {"id": "zh4pe_qU1fPj", "name": "Alpha", "leader_id": "Y5o_MFRmgk80",
           "members": [{"id": "Y5o_MFRmgk80", "name": "Ana"}]},
 "poll_seconds": 10, "stale_seconds": 300,
 "tiles": {"path": "tiles/{z}/{x}/{y}.png", "attribution": "© OpenStreetMap", "max_zoom": 14}}
```

`squad` is `null` outside a squad. `tiles` is absent when the server has none; `max_zoom` may be absent. A member's `id` is their device ID. Members are listed oldest first.

Position, as sent:

```json
{"latitude": 47.6205, "longitude": -122.3493, "altitude": 52.1, "accuracy": 8, "heading": 271, "speed": 1.4}
```

Only `latitude` and `longitude` are required. Leave out what the phone doesn't know rather than sending a placeholder (Core Location's `-1`, for instance). Round to what is useful (whole metres of accuracy, whole degrees of heading): the link is slow. Units are metres, degrees from true north, metres per second.

A location, as received:

```json
{"member_id": "…", "name": "Ben", "latitude": 47.6235, "longitude": -122.344, "accuracy": 8, "age": 4, "stale": true}
```

`age` is whole seconds since that member last reported, by the server's clock. Phones on a mesh may not agree on the time of day, so there are no timestamps. `stale` is present only when true. Members who have never reported are in `squad.members` but not in `locations`.

## 4. The loop

While the app is on screen, once every `poll_seconds`:

1. If the person is in no squad, `GET /api/v1/me` and stop. (This is how the app notices it has been put in a squad, or that its squad is gone.)
2. If the phone has a position and it either changed since the last one sent or the last one was sent at least `heartbeat` seconds ago, `PUT /api/v1/location`.
   `heartbeat = min(60, max(poll_seconds, stale_seconds / 3))`, so someone sitting still never looks stale.
3. `GET /api/v1/squad/locations`. Draw from it. If its `squad` differs from the one in hand, `GET /api/v1/me`.

A 409 `no_squad` in steps 2 or 3 means the squad is gone: drop it and go back to step 1.

Stop the loop and stop listening for positions when the app goes to the background. Background reporting is not specified yet.

The server keeps positions in memory only. After it restarts, each phone's next heartbeat puts it back on the map.

## 5. What the screens show

- **Map:** one marker per location, with the member's name. The person's own marker is visibly different. Stale markers are dimmed (the iPhone app uses 45% opacity).
- **Member list:** every member of the squad, the leader marked. Beside each: "Now" under a minute, then "N min ago", then "N h ago"; "No position yet" for members with no location. Stale members and members with no location are dimmed.
- **Invite:** `POST /api/v1/squad/invites`, then show `qr_payload` as a QR code, black on white with a quiet zone, with how long it has left. Say that it works for one phone. When the member count goes up while this screen is open, the code has been used: fetch a new one. Also offer the code as an invite link (§2).
- **Leave:** confirm first. `POST /api/v1/squad/leave` keeps the pairing; the person can start or join another squad. If the leader leaves, the longest-standing member becomes leader; an empty squad is deleted.
- **Forget this server:** PairKit sign-out. The server removes the person from their squad.

## 6. Map tiles

If Me has `tiles`, the app must draw the map from the server's tiles instead of an online map: replace `{z}`, `{x}`, `{y}` in `tiles.path` and fetch it relative to the server, over the pinned connection with the bearer token. Don't request zoom levels past `max_zoom`; scale the deepest level up instead. Show `attribution`.

Tiles should be cached on the phone, per pairing, and served from the cache first: they don't change, and the link may be down when the map is next opened. Delete the cache with the pairing.

Without `tiles`, use the platform's map. It will be blank off-grid.

## 7. Connection states

As PairKit §7, shown like this:

| State | App shows |
| --- | --- |
| Signed out | An alert, then the first-run screen. The pairing is deleted |
| Pin mismatch, unreachable, clock | A banner over the map with the reason. The last known map stays up and the loop keeps going |
| Refused | An alert with the server's text |

## 8. Permissions

- **Location, while in use.** Ask when the person first lands in a squad, not at launch.
- **Camera.** Asked by the scanner. Pasting must work without it.
- **Local network** (iOS). The system asks on first connection to a mesh address.

## 9. Not built yet

- Background position reporting.
- More than one pairing on a phone.
- Removing someone else from a squad.
- The Android app.
