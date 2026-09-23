// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DeviceShots",
    platforms: [.macOS("27.0")],
    targets: [
        // All app code lives in the library so Xcode can preview its SwiftUI
        // views; the executable is only the @main entry point.
        .target(name: "DeviceShotsKit", path: "Sources/DeviceShotsKit"),
        .executableTarget(name: "DeviceShots", dependencies: ["DeviceShotsKit"], path: "Sources/DeviceShots"),
        .testTarget(name: "DeviceShotsTests", dependencies: ["DeviceShotsKit"])
    ]
)
