// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Screenshotter",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Screenshotter", path: "Sources/Screenshotter")
    ]
)
