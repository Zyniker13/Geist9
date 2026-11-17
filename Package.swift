// swift-tools-version: 6.0
// Bristlecone Email Archiver. Core packages build and test on macOS and Linux; see docs/DESIGN.md section 12.
import PackageDescription

let package = Package(
    name: "EmailArchiver",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ArchiveCore", targets: ["ArchiveCore"]),
    ],
    targets: [
        .target(name: "ArchiveCore"),
        .testTarget(name: "ArchiveCoreTests", dependencies: ["ArchiveCore"]),
    ]
)
