// swift-tools-version:6.0
// Spike 001: reach fts5_api from a SwiftPM C target and register an FTS5
// auxiliary function. Standalone package, not part of the main build.
import PackageDescription

let package = Package(
    name: "FTS5ApiSpike",
    targets: [
        .target(
            name: "FTS5ApiSpikeC",
            path: "FTS5ApiSpikeC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedLibrary("pthread"),
                .linkedLibrary("dl"),
                .linkedLibrary("m"),
            ]
        ),
        .executableTarget(
            name: "FTS5ApiSpike",
            dependencies: ["FTS5ApiSpikeC"]
        ),
    ]
)
