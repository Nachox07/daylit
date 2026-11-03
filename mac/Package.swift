// swift-tools-version:5.9
// Daylit for macOS. `swift test` runs the core tests; mac/build.sh builds and assembles Daylit.app.
import PackageDescription

let package = Package(
    name: "Daylit",
    platforms: [.macOS(.v14)],
    targets: [
        // Decisions with no AppKit: config, sun, brightness target, hand-set hold, light/dark, HA template.
        .target(name: "DaylitCore"),
        // The menu-bar app: displays, keys, Home Assistant calls, UI.
        .executableTarget(name: "Daylit", dependencies: ["DaylitCore"]),
        .testTarget(name: "DaylitCoreTests", dependencies: ["DaylitCore"]),
    ]
)
