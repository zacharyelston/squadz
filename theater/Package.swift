// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SquadzTheater",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "squadz-theater", targets: ["SquadzTheater"])],
    dependencies: [.package(path: "../swift")],
    targets: [
        .target(name: "TheaterKit", dependencies: [
            .product(name: "SquadKit", package: "swift"),
            .product(name: "SquadLink", package: "swift"),
            .product(name: "CoreGeo", package: "swift"),
            .product(name: "ZoneKit", package: "swift")
        ], resources: [.copy("Resources/Web")]),
        .executableTarget(name: "SquadzTheater", dependencies: ["TheaterKit"]),
        .testTarget(name: "TheaterKitTests", dependencies: ["TheaterKit", .product(name: "SquadKit", package: "swift"), .product(name: "SquadLink", package: "swift"), .product(name: "CoreGeo", package: "swift")])
    ]
)
