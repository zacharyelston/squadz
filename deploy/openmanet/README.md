# The Squadz relay on an OpenMANET node

One small program on one mesh node gives every phone on the mesh a fixed address for their squad. No internet is involved.

Status: the Linux build was run on a Linux machine and a squad was linked through it (see [Tested](#tested-and-not)). It has **not** been run on a Raspberry Pi or on an OpenMANET node yet.

## When you need it

- **Phones on one node's Wi-Fi, or a mesh that passes Bonjour (mDNS) between nodes:** you don't. Phones find the leader's device by themselves and link straight to it.
- **A mesh where a phone on one node can't find a leader on another:** this is what the relay is for. Phones reach it by address, and it passes their links to the leader's device.

The relay never runs a squad and can't read one: links through it are sealed between the two devices ([`docs/RELAY.md`](../../docs/RELAY.md)). The leader's device still has to be on and reachable; the relay keeps nothing for later.

## How it fits

- OpenMANET nodes form one flat network in `10.41.0.0/16`. Phones join a node's Wi-Fi access point and can reach any address on the mesh.
- Run the relay on one Raspberry Pi 4 or CM4 node. Give that node an address that doesn't change (`10.41.253.0/24` and `10.41.254.0/24` are outside the range openmanetd hands out by itself).
- The relay listens on 8443. Ports 8080 and 8081 on a node are the openmanetd web UI's.
- On its first start the relay makes a certificate for itself and keeps it. The squad's leader gives the app the relay's address and that certificate's fingerprint; invites then carry both, so members type nothing.

## Build

For a Pi 4, CM4, Pi 3 or Zero 2 W (all 64-bit ARM). OpenWrt uses musl, so build a static musl binary. With [Zig](https://ziglang.org) and [cargo-zigbuild](https://github.com/rust-cross/cargo-zigbuild):

```bash
rustup target add aarch64-unknown-linux-musl
```

```bash
cd relay && cargo zigbuild --release --target aarch64-unknown-linux-musl
```

The result is `relay/target/aarch64-unknown-linux-musl/release/squadz-relay`, about 5 MB, with nothing else to install beside it.

The MIPS boards (HaLowLink2, Heltec HT-HD01) are not a sensible host: little storage, and the build for them hasn't been tried.

## Install

```bash
NODE=root@10.41.253.10
```

```bash
scp -O relay/target/aarch64-unknown-linux-musl/release/squadz-relay $NODE:/usr/bin/
```

```bash
scp -O deploy/openmanet/squadz-relay.init $NODE:/etc/init.d/squadz-relay
```

```bash
ssh $NODE 'chmod +x /usr/bin/squadz-relay /etc/init.d/squadz-relay && /etc/init.d/squadz-relay enable && /etc/init.d/squadz-relay start'
```

Then read the fingerprint off the node:

```bash
ssh $NODE 'squadz-relay pin /etc/squadz-relay/cert.pem'
```

Settings are optional; to change one, copy `relay.env.example` to `/etc/squadz-relay/relay.env` on the node, edit it and restart the service.

## In the app

On the leader's device, before starting the squad, fill in **Relay (optional)** on the home screen:

- the address, like `10.41.253.10:8443`;
- the fingerprint the node printed.

Start the squad and open **Invite**. Anyone who scans the code gets the relay's address and fingerprint with it. A phone looks for the leader on its own network for three seconds, then goes through the relay.

## Checking it

```bash
ssh $NODE 'logread -e squadz-relay | tail -5'
```

should show `listening on 0.0.0.0:8443 with TLS` and the `relay_pin`. From a laptop on the mesh, this prints the same fingerprint the node did:

```bash
echo | openssl s_client -connect 10.41.253.10:8443 2>/dev/null | openssl x509 -outform DER | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '='
```

If phones on another node's access point can't reach it, check the node's firewall zone for the `br-ahwlan` bridge.

## What lives on the node

Everything is in `/etc/squadz-relay`:

| File | What it is |
| --- | --- |
| `cert.pem`, `key.pem` | The relay's certificate and key, made once. **Keep them.** The fingerprint is of this exact certificate, so a new one means a new fingerprint in the app and new invites for every squad |
| `relay.db` | Which squads have a room, and hashes of what opens one. No names, positions or messages |
| `relay.env` | Your settings, if any |

To move the relay to another node, copy the folder.

## Another Linux machine

The same binary runs on any 64-bit ARM Linux, Raspberry Pi OS included; build for `x86_64-unknown-linux-musl` for an Intel or AMD machine. Without OpenWrt, start it however that machine starts services, with the same three settings the init script gives it:

```bash
RELAY_LISTEN=0.0.0.0:8443 RELAY_DB=/var/lib/squadz-relay/relay.db RELAY_TLS_DIR=/var/lib/squadz-relay squadz-relay
```

## Tested, and not

- `cd relay && cargo test`: the relay's tests, including that the certificate is made once, kept, and readable only by its owner.
- A squad between two devices through a relay that made its own certificate.
- The static Linux build, run on a Linux machine with a squad linked through it over the network.
- **Not tested:** a Raspberry Pi, an OpenMANET node, the init script under procd, the firewall on a node, and phones on two different nodes. Those need a node.

## Known limits

- One relay on one node: if that node leaves the mesh, links through it drop until it is back. Phones reconnect by themselves.
- The relay is for when devices can't find each other. It does not extend radio range, and it holds nothing while the leader's device is away.
- Offline map tiles are not served from the node. The app's map is Apple's and needs the internet for places the phone hasn't looked at before; pins, orders and notes don't.
