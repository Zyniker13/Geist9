// swift-tools-version:6.0
// Spike 002: C top-k posting walk over FTS5 prefix shapes at M=1M.
// Standalone package, not part of the main build.
import PackageDescription

let package = Package(
    name: "PrefixWalkSpike",
    targets: [
        .target(
            name: "PrefixWalkSpikeC",
            path: "PrefixWalkSpikeC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedLibrary("pthread"),
                .linkedLibrary("dl"),
                .linkedLibrary("m"),
            ]
        ),
        .executableTarget(
            name: "PrefixWalkSpike",
            dependencies: ["PrefixWalkSpikeC"]
        ),
    ]
)
