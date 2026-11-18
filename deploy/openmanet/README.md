# Running Squadz on an OpenMANET node

`squadz-server` is one static binary. One file on one mesh node is enough for phones with the Squadz app to share positions with no internet.

Status: the server and the iPhone app have been exercised on a Mac and in the iOS simulator. The binary cross-compiles for the boards below, but nothing here has been run on real hardware or a real mesh yet.

## How it fits

- OpenMANET nodes form one flat network in `10.41.0.0/16`. Phones join a node's Wi-Fi access point and can reach any address on the mesh.
- Run Squadz on one node. Give it a predictable address (`10.41.253.0/24` and `10.41.254.0/24` are outside the range openmanetd auto-assigns) or use its `hostname.local` name.
- Ports 8080 and 8081 on a node belong to the openmanetd web UI, so Squadz uses 8090 (plain HTTP: the operator's page) and 8443 (pinned TLS: the app).

## Build

Go cross-compiles with no extra toolchain. From `server/`, with PairKit checked out next to this repository:

```bash
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -ldflags="-s -w" -o squadz-server .
```

That covers the 64-bit ARM boards (Pi 4, CM4, Pi 3, Zero 2 W). For the MIPS boards (HaLowLink2, Heltec HT-HD01) use `GOARCH=mipsle GOMIPS=softfloat`; the binary is about 9 MB, which may not fit their storage.

## Install

```bash
NODE=root@10.41.253.10
scp -O server/squadz-server $NODE:/usr/bin/
scp -O deploy/openmanet/squadz.init $NODE:/etc/init.d/squadz
ssh $NODE 'mkdir -p /etc/squadz'
scp -O deploy/openmanet/squadz.env.example $NODE:/etc/squadz/squadz.env
ssh $NODE 'vi /etc/squadz/squadz.env'      # set TLS_HOSTS and DASHBOARD_PASSWORD
ssh $NODE '/etc/init.d/squadz enable && /etc/init.d/squadz start && logread -e squadz | tail -40'
```

Phones on another node's access point reach the server across the mesh bridge. If they cannot, check the node's firewall zone for the `br-ahwlan` bridge.

## Pairing phones

1. **The first phone.** Open `http://<node>:8090/` on any device on the mesh and scan the code it shows with the Squadz app. The code works once, for 10 minutes; reload the page for another. The code carries the address you opened the page with, so open it by an address phones can reach. The server also prints one code in its log at startup.
2. **Everyone else.** A member taps **Invite** and shows their screen. Each invite is good for one phone.

The operator's page hands out pairing codes over plain HTTP. Set `DASHBOARD_PASSWORD` unless everyone on the mesh is welcome.

## The server's key

On first start the server creates `/etc/squadz/data/tls-key.pem`. Every pairing code carries a pin of that key, and phones refuse any server that doesn't match it. There is no certificate to install or accept.

- **Back the key up.** If it is lost or replaced, every phone refuses the server and has to be paired again.
- Changing `TLS_HOSTS` or moving the node to a new address does not unpair anyone. Phones remember the address they paired with, though, so a phone paired at an old address has to be paired again at the new one.

## Offline map tiles

Copy a tile pyramid for your area to the node and point `TILES_DIR` at it:

```
/etc/squadz/tiles/{z}/{x}/{y}.png
```

Set `TILE_MAX_ZOOM` to the deepest level you copied; the app scales it up when zoomed in further. Phones fetch tiles as they look at the map and keep them, so each tile crosses the mesh once per phone. Respect the tile source's usage policy when downloading; openstreetmap.org's own tile servers do not permit bulk download.

Without `TILES_DIR` the app falls back to the phone's own maps, which are blank without internet.

## Known limits

- One server: if its node leaves the mesh, the squad stops updating.
- Each phone polls every 10 seconds, which adds up on a low-rate HaLow link.
- Positions are only reported while the app is open.
- Settings are listed in the top-level [README](../../README.md#settings).
