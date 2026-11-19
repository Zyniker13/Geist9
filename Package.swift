// swift-tools-version: 6.0
// Bristlecone Email Archiver. Core packages build and test on macOS and Linux; see docs/DESIGN.md section 12.
// The macOS-only targets (App, LoginItem, MCPHelper, OnePasswordHelper) live in the XcodeGen project, not here.
import PackageDescription

// M0 spikes are throwaway tools, not product targets. The IMAP spike builds
// everywhere; the FTS5 spike needs NaturalLanguage and the Darwin SDK's
// SQLite3 module, so it exists only where those do.
#if os(macOS)
let spikeTargets: [Target] = [
    .executableTarget(
        name: "IMAPSpike",
        dependencies: [
            .product(name: "IMAPCommands", package: "swift-nio-imap"),
            .product(name: "NIOIMAP", package: "swift-nio-imap"),
            .product(name: "NIOCore", package: "swift-nio"),
        ],
        path: "Spikes/IMAPSpike"
    ),
    .executableTarget(name: "FTS5Spike", path: "Spikes/FTS5Spike"),
]
#else
let spikeTargets: [Target] = [
    .executableTarget(
        name: "IMAPSpike",
        dependencies: [
            .product(name: "IMAPCommands", package: "swift-nio-imap"),
            .product(name: "NIOIMAP", package: "swift-nio-imap"),
            .product(name: "NIOCore", package: "swift-nio"),
        ],
        path: "Spikes/IMAPSpike"
    ),
]
#endif

let viewerProducts: [Product]
let viewerTargets: [Target]
#if os(macOS)
// Message viewer: sanitizer assembly, WKWebView lockdown, attachment scheme (DESIGN 8)
viewerProducts = [.library(name: "ViewerKit", targets: ["ViewerKit"])]
viewerTargets = [
    .target(name: "ViewerKit", dependencies: ["MailMIME"]),
    .testTarget(name: "ViewerKitTests", dependencies: ["ViewerKit"]),
]
#else
viewerProducts = []
viewerTargets = []
#endif

let products: [Product] = [
    .library(name: "ArchiveCore", targets: ["ArchiveCore"]),
    .library(name: "MailMIME", targets: ["MailMIME"]),
    .library(name: "MailSync", targets: ["MailSync"]),
    .library(name: "ArchiveSearch", targets: ["ArchiveSearch"]),
    .library(name: "ArchiveExtract", targets: ["ArchiveExtract"]),
    .library(name: "ArchiveCrypto", targets: ["ArchiveCrypto"]),
    .library(name: "ArchiveMCP", targets: ["ArchiveMCP"]),
    .library(name: "Credentials", targets: ["Credentials"]),
    .executable(name: "bench-search", targets: ["Benchmarks"]),
] + viewerProducts

let dependencies: [Package.Dependency] = [
    // IMAP protocol layer, chosen in docs/decisions/0002 and confirmed by the M0 spike.
    .package(url: "https://github.com/apple/swift-nio-imap.git", exact: "0.5.0"),
    .package(url: "https://github.com/apple/swift-nio.git", exact: "2.105.0"),
    // Transitive pins for security advisories: extras <1.34.1 (decompressor
    // ratio bypass, GHSA-6ph5-fww6-vfwv) and ssl <2.37.6 (SAN buffer OOB
    // read, CVE-2026-43820) are affected; pinning forces resolution past them.
    .package(url: "https://github.com/apple/swift-nio-extras.git", exact: "1.35.2"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.6"),
    // SQLite index layer (DESIGN 6), decision 0013: GRDB over SQLite in WAL mode.
    .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0"),
    // SHA-256 for content addressing (DESIGN 6); decision 0014. Same Crypto API on Linux and macOS.
    .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.1.1"),
]

let coreTargets: [Target] = [
    // models, archive format, index, migrations, import/export (DESIGN 6, DESIGN 9);
    // import parsing goes through MailMIME, never its own parser.
    .target(name: "ArchiveCore", dependencies: [
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "Crypto", package: "swift-crypto"),
        "MailMIME",
        "ArchiveSearch",
        "ArchiveExtract",
    ]),
    // parser, charsets, threading (DESIGN 7)
    .target(name: "MailMIME"),
    // IMAP, JMAP, provider database (DESIGN 5)
    .target(name: "MailSync"),
    // vendored Snowball stemmers, BSD-3 (Sources/CStemmer/PROVENANCE.md,
    // decision 0026)
    .target(name: "CStemmer"),
    // system zlib: inflate for ZIP-based attachments (.docx/.xlsx/.pptx,
    // OpenDocument, iWork, .zip names) and CRC32 verification (decision
    // 0036). Present on macOS by default; Ubuntu needs zlib1g-dev, which
    // the Linux CI leg installs.
    .systemLibrary(name: "CZlib", providers: [.apt(["zlib1g-dev"])]),
    // tokenizers, FTS, ranking, facets, query language (DESIGN 6A);
    // stems through the vendored Snowball C (decision 0026)
    .target(name: "ArchiveSearch", dependencies: ["CStemmer"]),
    // attachment text, OCR, entities, embeddings (DESIGN 6A)
    .target(name: "ArchiveExtract", dependencies: ["CZlib"]),
    // envelope, SQLCipher glue (DESIGN 10)
    .target(name: "ArchiveCrypto"),
    // MCP server: tools, resources, access policy (DESIGN 9A)
    .target(name: "ArchiveMCP"),
    // CredentialStore, Keychain and 1Password backends (DESIGN 4)
    .target(name: "Credentials"),
    // scale benchmark harness (ROADMAP M1 "Done when", docs/TESTING.md)
    .executableTarget(name: "Benchmarks", dependencies: ["ArchiveCore"]),
]

let evalTargets: [Target] = [
    // Judged relevance set (DESIGN 6A, decision 0028): deterministic
    // topical corpus, metrics, and the runner the CI gate test drives.
    .target(
        name: "SearchEval",
        dependencies: ["ArchiveCore", "ArchiveSearch", "MailMIME"],
        resources: [.copy("qrels.json")]
    ),
    .testTarget(name: "SearchEvalTests", dependencies: ["SearchEval", "ArchiveCore"]),
]

let testTargets: [Target] = [
    .testTarget(name: "ArchiveCoreTests", dependencies: ["ArchiveCore"]),
    .testTarget(name: "ArchiveSearchTests", dependencies: ["ArchiveSearch"]),
    .testTarget(name: "ArchiveExtractTests", dependencies: ["ArchiveExtract"]),
    .testTarget(name: "MailMIMETests", dependencies: ["MailMIME"]),
    .testTarget(name: "CredentialsTests", dependencies: ["Credentials"]),
]

let targets: [Target] = coreTargets + spikeTargets + viewerTargets + testTargets + evalTargets

let package = Package(
    name: "EmailArchiver",
    platforms: [.macOS(.v15)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
