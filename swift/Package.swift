// swift-tools-version: 5.9
import PackageDescription

// The squad core every app can use (docs/WIRE.md, and SQUAD_CORE.md in BackyardBallistics).
//
// Dependency order (each module may use only the ones above it):
//   CoreGeo   – GPS points, local east/north offsets, polygons
//   SquadKit  – the squad protocol and the leader's state: join, roster, positions, orders,
//               notes, files, check fire, holds, and missions as add-ons. No golf, no network.
//   SquadLink – SquadKit over the local network (Bonjour, TLS keyed per link) and through a relay
let package = Package(
    name: "SquadKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SquadKit", targets: ["SquadKit"]),
        .library(name: "SquadLink", targets: ["SquadLink"]),
    ],
    dependencies: [.package(path: "../../BackyardBallistics/Packages/GeoZones")],
    targets: [
        .target(name: "SquadKit", dependencies: [.product(name: "CoreGeo", package: "GeoZones"), .product(name: "ZoneKit", package: "GeoZones")]),
        .target(name: "SquadLink", dependencies: ["SquadKit"]),
        .testTarget(name: "SquadKitTests", dependencies: ["SquadKit", .product(name: "CoreGeo", package: "GeoZones")]),
        .testTarget(name: "SquadLinkTests", dependencies: ["SquadLink", "SquadKit", .product(name: "CoreGeo", package: "GeoZones")]),
    ]
)
