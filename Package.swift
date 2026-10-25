// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DevNull",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DevNull",
            path: "Sources/DevNull",
            exclude: ["Resources"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DevNullTests",
            dependencies: ["DevNull"],
            path: "Tests/DevNullTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
