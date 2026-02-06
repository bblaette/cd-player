// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CDPlayer",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "CDPlayer",
            path: "Sources",
            exclude: ["Info.plist", "AppIcon.icns"]
        )
    ]
)
