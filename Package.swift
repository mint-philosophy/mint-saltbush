// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Folio",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "FolioCore"),
        .executableTarget(name: "Folio", dependencies: ["FolioCore"]),
        .executableTarget(name: "folio-selftest", dependencies: ["FolioCore"]),
    ]
)
