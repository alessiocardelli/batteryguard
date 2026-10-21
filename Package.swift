// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "BatteryGuard",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SMCKit", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "batteryguard-helper", dependencies: ["SMCKit"]),
        .executableTarget(name: "BatteryGuard", dependencies: ["SMCKit"])
    ]
)
