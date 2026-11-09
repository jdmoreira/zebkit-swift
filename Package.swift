// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "zebkit-swift",
    // The engine's own minimum: Zebkit.framework is built for macOS 13.
    platforms: [.macOS(.v13)],
    products: [
        // The Swift interface. An application depends on this one.
        .library(name: "Zebkit", targets: ["Zebkit"]),
        // The C API as the engine's headers declare it, for what Zebkit does
        // not wrap.
        .library(name: "CZebkit", targets: ["CZebkit"]),
        // Downloads the engine, and puts it beside an executable to ship.
        .executable(name: "zebkit-engine", targets: ["zebkit-engine"]),
    ],
    targets: [
        .target(
            name: "CZebkit",
            // dlopen() and dlsym() are in libdl before glibc 2.34.
            linkerSettings: [.linkedLibrary("dl", .when(platforms: [.linux]))]
        ),
        .target(name: "Zebkit", dependencies: ["CZebkit"]),
        .executableTarget(name: "zebkit-engine", dependencies: ["CZebkit"]),
    ]
)
