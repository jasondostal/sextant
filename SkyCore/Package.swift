// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SkyCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "SkyCore", targets: ["SkyCore"])],
    targets: [
        // Astronomy Engine (Don Cross, MIT), vendored as the single-file C build.
        .target(name: "CAstronomy", cSettings: [.unsafeFlags(["-w", "-O2"])]),
        .target(name: "SkyCore", dependencies: ["CAstronomy"], resources: [.copy("Resources")]),
        .testTarget(name: "SkyCoreTests", dependencies: ["SkyCore"], resources: [.copy("Fixtures")]),
    ]
)
