// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "ChargeLimit",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SMCKit", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "charge-limit-helper", dependencies: ["SMCKit"]),
        .executableTarget(name: "ChargeLimit", dependencies: [])
    ]
)
