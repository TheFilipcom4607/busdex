// swift-tools-version:6.0
// Platform-neutral core logic of the Tabor app, so it can be unit-tested on macOS
// without an iOS simulator. The app target compiles the same files directly.
import PackageDescription

let package = Package(
    name: "TaborCore",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [.library(name: "TaborCore", targets: ["TaborCore"])],
    targets: [
        .target(name: "TaborCore", path: "Tabor/Core"),
        .testTarget(
            name: "TaborCoreTests",
            dependencies: ["TaborCore"],
            path: "Tests/TaborCoreTests"
        ),
    ]
)
