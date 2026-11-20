// swift-tools-version: 5.9
import PackageDescription

// The squad core every app can use (docs/WIRE.md, and SQUAD_CORE.md in BackyardBallistics).
//
// Dependency order (each module may use only the ones above it):
//   CoreGeo   – GPS points, local east/north offsets, polygons
//   SquadKit  – the squad protocol and the leader's state: join, roster, positions, orders,
//               notes, files, check fire, holds, and missions as add-ons. No golf, no network.
//   SquadLink – SquadKit over the local network: Bonjour, TLS keyed from the join code
let package = Package(
    name: "SquadKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CoreGeo", targets: ["CoreGeo"]),
        .library(name: "SquadKit", targets: ["SquadKit"]),
        .library(name: "SquadLink", targets: ["SquadLink"]),
    ],
    targets: [
        .target(name: "CoreGeo"),
        .target(name: "SquadKit", dependencies: ["CoreGeo"]),
        .target(name: "SquadLink", dependencies: ["SquadKit"]),
        .testTarget(name: "SquadKitTests", dependencies: ["SquadKit", "CoreGeo"]),
        .testTarget(name: "SquadLinkTests", dependencies: ["SquadLink", "SquadKit", "CoreGeo"]),
    ]
)
