// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Saltbush",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SaltbushCore"),
        .executableTarget(name: "Saltbush", dependencies: ["SaltbushCore"]),
        .executableTarget(name: "saltbush-selftest", dependencies: ["SaltbushCore"]),
    ]
)
