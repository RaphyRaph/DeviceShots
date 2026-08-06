// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DeviceShots",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "DeviceShots", path: "Sources/DeviceShots"),
        .testTarget(name: "DeviceShotsTests", dependencies: ["DeviceShots"])
    ]
)
