// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DeviceShots",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(name: "DeviceShots", path: "Sources/DeviceShots"),
        .testTarget(name: "DeviceShotsTests", dependencies: ["DeviceShots"])
    ]
)
