// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XFinder",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "XFinder",
            path: "Sources/XFinder",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
