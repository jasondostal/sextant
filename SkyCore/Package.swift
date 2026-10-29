// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SkyCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "SkyCore", targets: ["SkyCore"])],
    dependencies: [
        // SGP4/SDP4 (Gavin Eadie, MIT)
        .package(url: "https://github.com/gavineadie/SatelliteKit.git", exact: "2.1.2"),
    ],
    targets: [
        // Astronomy Engine (Don Cross, MIT), vendored as the single-file C build.
        .target(name: "CAstronomy", cSettings: [.unsafeFlags(["-w", "-O2"])]),
        .target(name: "SkyCore", dependencies: ["CAstronomy", "SatelliteKit"], resources: [.copy("Resources")]),
        .testTarget(name: "SkyCoreTests", dependencies: ["SkyCore"], resources: [.copy("Fixtures")]),
    ]
)
