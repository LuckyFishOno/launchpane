// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OpenLaunchpad",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(name: "DisplayCore", targets: ["DisplayCore"]),
        .library(name: "LayoutCore", targets: ["LayoutCore"]),
        .executable(name: "OpenLaunchpad", targets: ["OpenLaunchpad"]),
    ],
    targets: [
        .target(name: "AppCore"),
        .target(name: "DisplayCore"),
        .target(name: "LayoutCore", dependencies: ["DisplayCore"]),
        .executableTarget(
            name: "OpenLaunchpad",
            dependencies: ["AppCore", "DisplayCore", "LayoutCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore"]),
        .testTarget(name: "DisplayCoreTests", dependencies: ["DisplayCore"]),
        .testTarget(
            name: "LayoutCoreTests",
            dependencies: ["DisplayCore", "LayoutCore"]
        ),
    ]
)
