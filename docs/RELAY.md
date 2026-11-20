# The relay

A relay carries a squad's links over the internet, for when its devices aren't on one network. It is step V3 of [issue #2](https://github.com/zacharyelston/squadz/issues/2). The code is in [`relay/`](../relay) (Rust, Axum, Tokio, SQLite); the Swift side is `RelayLinkHost` and the relay paths of `SquadEnroller` and `SquadLinkClient` in [SquadLink](../swift/Sources/SquadLink/RelayLink.swift).

The relay is a pipe. The leader's device is still the squad: it holds the roster, decides who is in, and checks every link's key itself. The relay never runs a squad and decides nothing about one.

## What the relay can and can't do

| | |
| --- | --- |
| **Stores** | For each squad: its ID, the hash of the leader's token, the hash of each device's token, the hash of each open invite's relay key and when it expires, and two timestamps. Nothing else |
| **Doesn't store** | Names, rosters, positions, orders, notes, or any secret a device presents |
| **Can't do** | Let a device into a squad. A ticket from the relay only opens a link to the leader's device, which asks for the member's credential as it does on the local network |
| **Can't do** | Read what it carries. Every frame on a link is sealed between the device and the leader's device ([WIRE.md](WIRE.md) §9), a request to join and its answer included. It can't change, drop, reorder, repeat or add a frame without the link ending |
| **Can't do** | Join a squad in place of a device that is joining through it. It never has the invite's secret, only a value derived from it one way |
| **Sees** | Which squads have a room and when their devices are connected, from which addresses; which key a device names on each link (a credential's ID, which is not secret); and the size and timing of every frame |
| **Can do** | Refuse to carry a squad, or drop its links. A squad on one network doesn't need it |

## For a squad's leader

A relay is optional and chosen when the squad is started. In the app: the relay's address on the home screen, and its certificate fingerprint if it uses a certificate of its own making. The leader's device then keeps a connection to the relay open, and every invite names the relay.

A member's device looks for the squad on its own network first, for three seconds, and goes through the relay if it isn't there. A device that joins on the local network also asks the relay for a ticket while the invite is open, so it can reach the squad from elsewhere later.

## Running one

```bash
cd relay && cargo build --release
RELAY_LISTEN=0.0.0.0:8443 RELAY_DB=/var/lib/squadz/relay.db ./target/release/squadz-relay
```

| Setting | |
| --- | --- |
| `RELAY_LISTEN` | Address to listen on. Default `0.0.0.0:8443` |
| `RELAY_DB` | The SQLite file. Default `relay.db` |
| `RELAY_TLS_CERT`, `RELAY_TLS_KEY` | A certificate chain and its key, PEM. With both, the relay serves TLS itself and prints the `relay_pin` for that certificate |
| `RELAY_WEB_ORIGIN` | The one web page that may connect from a browser, like `https://app.example`. Unset, every browser is refused. Native apps are not affected |
| `RELAY_TRUST_PROXY` | `1` when a proxy in front sets `X-Forwarded-For`, so rate limits count the device's address and not the proxy's |

Phones connect only over TLS (`wss://`). Either:

- **Behind a host that adds TLS** with a certificate phones already trust. Run the relay without a certificate, set `RELAY_TRUST_PROXY=1`, and give the app just the address.
- **With its own certificate.** A certificate nobody signed is fine: the app accepts exactly the certificate whose fingerprint (`relay_pin`) is in the invite, and nothing else.

  ```bash
  openssl ecparam -genkey -name prime256v1 -noout -out key.pem
  openssl req -x509 -new -key key.pem -days 825 -subj /CN=relay -addext "subjectAltName=DNS:relay" -out cert.pem
  RELAY_TLS_CERT=cert.pem RELAY_TLS_KEY=key.pem ./target/release/squadz-relay
  ```

  The pin is of the whole certificate, so it changes when the certificate does. Members joined with the old pin need a new invite.

[`relay/Dockerfile`](../relay/Dockerfile) builds a container. It has not been built or run yet.

Limits, all in `Config` in [`relay/src/lib.rs`](../relay/src/lib.rs): 10 wrong secrets from one address in 10 minutes and that address is turned away until the 10 minutes pass; 20 new rooms an hour from one address; 10,000 squads; 256 devices and 64 open links a squad; 1 MiB a message. A room whose leader hasn't connected for 30 days is forgotten. Anyone who can reach the relay can open a room on it: there is no key for that yet.

## The protocol

One WebSocket endpoint: `GET /v1/link`. A request with an `Origin` header is refused with 403 unless it is exactly `RELAY_WEB_ORIGIN`. (`GET /healthz` answers `ok`. There is nothing else: no listing of squads, and no way to ask whether one exists.)

Text messages are the relay's own, JSON with a type in `t`. Binary messages are a squad's. Secrets are base64url without padding. A squad's ID is its UUID.

A socket's first message, within 10 seconds, says what it is. Anything else closes it.

| First message | From | Answer |
| --- | --- | --- |
| `{"t":"create","squad":ID}` | A leader's device, for a squad the relay hasn't seen | `{"t":"created","token":T}`: the 32-byte token that leads this room, shown once. The socket is then the leader's |
| `{"t":"lead","squad":ID,"token":T}` | A leader's device coming back | `{"t":"ok"}`. An earlier leader socket for the squad is closed, with its links |
| `{"t":"join","squad":ID,"key":K}` | A device holding an open invite | `{"t":"joined","device":D,"token":T}`: a ticket of its own. The socket then closes |
| `{"t":"member","squad":ID,"token":T}` | A device with a ticket | `{"t":"open","nonce":N}` once it has a link to the leader's device, or `{"t":"away"}` and a close if the leader's device isn't connected |

Any of them can be answered `{"t":"refused"}` and a close. The answer is the same whatever was wrong: no such squad, a wrong secret, an invite that has expired or been closed. `{"t":"refused","why":"slow"}` means the address has been turned away for now; `"why":"full"` that the squad has as many devices as it may.

**The relay key.** `K` is not the invite's secret. It is

```
K = HMAC-SHA256(key: enrol (16 bytes), message: "squad relay join v1")
```

and the leader's device gives the relay only SHA-256 of it. So the relay can recognise a device that holds the invite, and can't use what it knows to enrol. For `enrol` = bytes 0 to 15, `K` is `7352fbf0b3fa6adb421747a0ebd76357698a2f76d1342aecf86f1c98afd191d6`. The typed code never works at a relay.

### The leader's socket

| Message | Direction | |
| --- | --- | --- |
| `{"t":"invites","list":[{"hash":hex,"exp":seconds}]}` | To the relay | The open invites: SHA-256 of each relay key, and when it expires. Replaces the list; an empty list closes joining at the relay |
| `{"t":"open","conn":n,"device":D,"nonce":N}` | From the relay | A device with a ticket opened link `n` |
| binary: 4 bytes of `n`, big-endian, then bytes | Both | Bytes from or for link `n`. Bytes for a link that isn't open are dropped |
| `{"t":"closed","conn":n}` | From the relay | The device's end of link `n` went away |
| `{"t":"close","conn":n}` | To the relay | Close link `n`. With `"refused":true` the device is told `{"t":"refused"}` first: the leader's device did not accept its key |
| `{"t":"revoke","device":D}` | To the relay | Forget this device's ticket and close its links. SquadLink does not send it yet: a removed member's device learns it was removed from the leader's refusal, which it couldn't hear if the relay turned it away first |
| `{"t":"end"}` | To the relay | Forget the squad: its room, its invites and every ticket |

When the leader's socket goes, every link into the room is closed. Members' devices try again on their own.

### A link

The bytes on a link are SquadKit frames ([WIRE.md](WIRE.md) §1), sealed between the two devices ([WIRE.md](WIRE.md) §9). Each end's first frame is a `seal` frame in the clear, carrying a nonce; every frame after it is ciphertext under keys made from the link key, the two nonces and `N`: 32 random bytes the relay makes for each link and gives to both ends. The relay never has the link key.

The leader's device accepts the same keys it accepts locally, an invite's or a member credential's, and refuses the link if the device's first sealed frame doesn't open. Through a relay a device counts itself connected only once the leader's device has answered.

The relay pings every 20 seconds and closes a socket that says nothing, not even an answer to a ping, for 60.

## Tested, and not

- `cd relay && cargo test`: 12 tests against real sockets on one machine. Rooms, tickets, invites and their expiry, the rate limit, a leader replaced, a device revoked, a squad ended, a restart on the same file, and the browser `Origin` rule.
- `cd swift && swift test` starts the built relay with TLS and a certificate made for the run, and joins, links, removes and restarts through it with a pinned certificate. One more test runs a relay behind a tap that keeps every byte in and out of it, joins, sends a position, a note and an order, and checks that none of the names, places or words are in what the tap kept. Without the relay binary those 10 tests are skipped.
- Five more Swift tests need no relay: they play a hostile carrier that swaps a joining device's request for its own, changes a frame, and plays a recorded link back.
- By hand: the app in a simulator and a Mac stand-in for the second phone, each leading in turn, through a relay on the same Mac.
- **Not tested:** a relay on another machine or on the internet, a phone on cellular (the "done when" of V3), a relay behind a proxy, the container, many squads at once, and any browser client (there isn't one yet).
