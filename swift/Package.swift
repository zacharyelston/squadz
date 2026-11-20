// swift-tools-version: 5.9
import PackageDescription

// The squad core every app can use (docs/WIRE.md).
//
// Dependency order (each module may use only the ones above it):
//   CoreGeo    – GPS points, local east/north offsets, polygons
//   ZoneKit    – circle and polygon zones, and telling when someone crosses one. No squad, no network.
//   ZoneMapKit – drawing zones on a map (SwiftUI and MapKit)
//   SquadKit   – the squad protocol and the leader's state: join, roster, positions, orders,
//                notes, files, check fire, holds, zones, and missions as add-ons. No golf, no network.
//   SquadLink  – SquadKit over the local network (Bonjour, TLS keyed per link) and through a relay
//
// Everything is in this repository. Another app (SpudGunGolf, say) that wants the geometry or
// the zones depends on this package and takes the products it needs.
let package = Package(
    name: "SquadKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CoreGeo", targets: ["CoreGeo"]),
        .library(name: "ZoneKit", targets: ["ZoneKit"]),
        .library(name: "ZoneMapKit", targets: ["ZoneMapKit"]),
        .library(name: "SquadKit", targets: ["SquadKit"]),
        .library(name: "SquadLink", targets: ["SquadLink"]),
    ],
    targets: [
        .target(name: "CoreGeo"),
        .target(name: "ZoneKit", dependencies: ["CoreGeo"]),
        .target(name: "ZoneMapKit", dependencies: ["CoreGeo", "ZoneKit"]),
        .target(name: "SquadKit", dependencies: ["CoreGeo", "ZoneKit"]),
        .target(name: "SquadLink", dependencies: ["SquadKit"]),
        .testTarget(name: "ZoneKitTests", dependencies: ["CoreGeo", "ZoneKit"]),
        .testTarget(name: "SquadKitTests", dependencies: ["SquadKit", "CoreGeo"]),
        .testTarget(name: "SquadLinkTests", dependencies: ["SquadLink", "SquadKit", "CoreGeo"]),
    ]
)
