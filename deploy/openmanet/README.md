# Running Squadz on an OpenMANET node

`squadz-server` carries the mobile web app and Leaflet inside the binary, so one
file on one mesh node is enough for phones to share positions with no internet.

Status: the server and mobile page have been exercised locally on macOS. The
cross-compile and on-node steps below have **not** been run against real
hardware yet.

## How it fits

- OpenMANET nodes form one flat network in `10.41.0.0/16`. Phones join a node's
  Wi-Fi access point and can reach any address on the mesh.
- Run Squadz on one Raspberry Pi 4 / CM4 node. Give that node a predictable
  address (`10.41.253.0/24` and `10.41.254.0/24` are outside the range
  openmanetd auto-assigns) or use its `hostname.local` name.
- Phones open `https://<node>:8443/mobile.html`. HTTPS is required: browsers
  only allow GPS access on pages loaded over HTTPS.
- Ports 8080 and 8081 on a node are taken by the openmanetd web UI, so Squadz
  uses 8090 (HTTP: dashboard, health) and 8443 (HTTPS: mobile app and API).

## Build (Pi 4 / CM4 / Pi 3 / Zero 2 W - all 64-bit ARM)

OpenWrt uses musl, so build a static musl binary. With
[cargo-zigbuild](https://github.com/rust-cross/cargo-zigbuild):

```bash
rustup target add aarch64-unknown-linux-musl
cargo zigbuild --release --target aarch64-unknown-linux-musl --bin squadz-server
```

The result is `target/aarch64-unknown-linux-musl/release/squadz-server`.
[`cross`](https://github.com/cross-rs/cross) works the same way if you prefer
Docker. The MIPS boards (HaLowLink2, Heltec HT-HD01) would need
`mipsel-unknown-linux-musl` and have very little storage; they are not a
sensible host.

## Install

```bash
NODE=root@10.41.253.10
scp -O target/aarch64-unknown-linux-musl/release/squadz-server $NODE:/usr/bin/
scp -O deploy/openmanet/squadz.init $NODE:/etc/init.d/squadz
ssh $NODE 'mkdir -p /etc/squadz'
scp -O deploy/openmanet/squadz.env.example $NODE:/etc/squadz/squadz.env
ssh $NODE 'vi /etc/squadz/squadz.env'      # set TLS_HOSTS and DASHBOARD_PASSWORD
ssh $NODE '/etc/init.d/squadz enable && /etc/init.d/squadz start && logread -e squadz | tail'
```

Phones on another node's access point reach the server across the mesh bridge.
If they cannot, check the node's firewall zone for the `br-ahwlan` bridge.

## The certificate warning

On first start the server writes a self-signed certificate to
`/etc/squadz/cert.pem` covering the names in `TLS_HOSTS`. Each phone shows a
warning once and has to choose "proceed"/"visit this website". The certificate
is valid for 820 days and is replaced automatically when it gets within 30 days
of expiry. To use your own, put the PEM files at `TLS_CERT` / `TLS_KEY`.

## Offline map tiles

With `TILE_URL=none` the map has no background. For a real basemap, copy a tile
pyramid for your area to the node and point `TILES_DIR` at it:

```
/etc/squadz/tiles/{z}/{x}/{y}.png
```

Set `TILE_MAX_NATIVE_ZOOM` to the deepest zoom level you copied so closer zooms
scale it up instead of going blank. Respect the tile source's usage policy when
downloading; openstreetmap.org's own tile servers do not permit bulk download.

## Settings

| Variable | Default | Meaning |
|----------|---------|---------|
| `PORT` | `8080` | HTTP port |
| `TLS_PORT` | unset | HTTPS port; unset means HTTP only |
| `TLS_CERT`, `TLS_KEY` | `tls/cert.pem`, `tls/key.pem` | PEM files, generated if missing |
| `TLS_HOSTS` | `localhost,127.0.0.1` | Names/IPs for the generated certificate |
| `TILES_DIR` | unset | Folder of `{z}/{x}/{y}.png` tiles served at `/tiles` |
| `TILE_URL` | unset | Tile URL template; `none` for no basemap |
| `TILE_MAX_NATIVE_ZOOM` | unset | Deepest zoom level available |
| `TILE_ATTRIBUTION` | `© OpenStreetMap` | Attribution shown on the map |

## Known limits

- All state is in memory: restarting the service drops every squad.
- One server: if its node leaves the mesh, the squad loses updates.
- Each phone polls every 10 s, which adds up on a low-rate HaLow link.
- Only `mobile.html` is offline-capable. The Next.js frontend still loads map
  tiles from the internet.
