// swift-tools-version: 6.0

import PackageDescription

// Programs that use Zebkit. From this directory:
//
//     swift run zebkit-engine install     # once: downloads the engine
//     swift run title https://example.com/
//     swift run window https://example.com/
let package = Package(
    name: "zebkit-swift-examples",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "zebkit-swift", path: "..")],
    targets: [
        .executableTarget(name: "title", dependencies: [.product(name: "Zebkit", package: "zebkit-swift")]),
        .executableTarget(name: "window", dependencies: [.product(name: "Zebkit", package: "zebkit-swift")]),
    ]
)
