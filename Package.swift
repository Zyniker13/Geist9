// swift-tools-version: 6.1
// Bristlecone Email Archiver. Core packages build and test on macOS and Linux; see docs/DESIGN.md section 12.
// The macOS-only app targets (App, LoginItem, OnePasswordHelper) live in the XcodeGen project; the
// stdio MCP helper (MCPHelper) is a package target here and the project copies it into the bundle.
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

// Apple-framework extractors (DESIGN 6A): PDFKit for PDF text, later Vision
// for OCR. These are Darwin frameworks, so the target exists only on macOS;
// ArchiveCore calls into it under #if canImport and the Linux build simply
// never sees it (decision 0039).
let appleExtractProducts: [Product]
let appleExtractTargets: [Target]
#if os(macOS)
appleExtractProducts = [.library(name: "ArchiveExtractApple", targets: ["ArchiveExtractApple"])]
appleExtractTargets = [
    .target(name: "ArchiveExtractApple"),
    .testTarget(name: "ArchiveExtractAppleTests", dependencies: ["ArchiveExtractApple", "ArchiveCore"]),
]
#else
appleExtractProducts = []
appleExtractTargets = []
#endif

// On-device semantic embeddings (DESIGN 6A, decisions 0009 and 0045):
// the Core ML adapter and its BERT WordPiece tokenizer. Apple-only
// because Core ML is; ArchiveCore's EmbeddingModel protocol stays
// cross-platform and the app injects this implementation at startup.
let appleEmbedProducts: [Product]
let appleEmbedTargets: [Target]
#if os(macOS)
appleEmbedProducts = [.library(name: "ArchiveEmbedApple", targets: ["ArchiveEmbedApple"])]
appleEmbedTargets = [
    .target(name: "ArchiveEmbedApple", dependencies: ["ArchiveCore"]),
    .testTarget(
        name: "ArchiveEmbedAppleTests",
        dependencies: ["ArchiveEmbedApple", "ArchiveCore"],
        resources: [.copy("toy_vocab.txt"), .copy("toy_embedding.mlmodel")]
    ),
]
#else
appleEmbedProducts = []
appleEmbedTargets = []
#endif

// macOS-only target references in dependency lists must be branched here,
// not with .when(platforms:) conditions: SwiftPM on Linux still validates
// names that never exist there and fails the whole manifest with a
// misleading "sources should be located under Sources/<name>" error.
let benchDeps: [Target.Dependency]
let searchEvalTestDeps: [Target.Dependency]
#if os(macOS)
// decision 0046 real-text recall links ArchiveEmbedApple; decision 0047
// runs the judged-relevance phase from bench-search relevance.
benchDeps = ["ArchiveCore", .product(name: "GRDB", package: "GRDB.swift"), .target(name: "ArchiveEmbedApple"), .target(name: "SearchEval")]
// SemanticSliceTests loads the toy CoreML embedding model.
searchEvalTestDeps = ["SearchEval", "ArchiveCore", .target(name: "ArchiveEmbedApple"), "ArchiveSearch"]
#else
benchDeps = ["ArchiveCore", .product(name: "GRDB", package: "GRDB.swift")]
searchEvalTestDeps = ["SearchEval", "ArchiveCore", "ArchiveSearch"]
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
    .executable(name: "email-archiver-mcp", targets: ["MCPHelper"]),
    .executable(name: "bench-search", targets: ["Benchmarks"]),
] + viewerProducts + appleExtractProducts + appleEmbedProducts

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
    // MCP protocol + transports (DESIGN 9A); decision 0051. Exact pin, never
    // `from:`: a bump that changes a tool schema must break tests, not agents.
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
]

var archiveCoreDependencies: [Target.Dependency] = [
    .product(name: "GRDB", package: "GRDB.swift"),
    .product(name: "Crypto", package: "swift-crypto"),
    "MailMIME",
    "ArchiveSearch",
    "ArchiveExtract",
]
#if os(macOS)
archiveCoreDependencies.append("ArchiveExtractApple")
#endif

let coreTargets: [Target] = [
    // models, archive format, index, migrations, import/export (DESIGN 6, DESIGN 9);
    // import parsing goes through MailMIME, never its own parser.
    .target(
        name: "ArchiveCore",
        dependencies: archiveCoreDependencies
    ),
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
    // MCP server: tools, resources, access policy (DESIGN 9A); reads the
    // archive through ArchiveCore (openReadOnly, queries) over the protocol
    // and transport layers of the official swift-sdk (decision 0051).
    .target(
        name: "ArchiveMCP",
        dependencies: ["ArchiveCore", .product(name: "MCP", package: "swift-sdk")]
    ),
    // stdio MCP executable (DESIGN 9A): cross-platform sources here so the
    // Linux end-to-end contract test can launch the same helper; the app
    // bundle copies it via the XcodeGen project.
    .executableTarget(
        name: "MCPHelper",
        dependencies: ["ArchiveMCP", .product(name: "MCP", package: "swift-sdk")]
    ),
    // CredentialStore, Keychain and 1Password backends (DESIGN 4)
    .target(name: "Credentials"),
    // scale benchmark harness (ROADMAP M1 "Done when", docs/TESTING.md;
    // decision 0045 scale-measurement slice adds the semantic phases;
    // decision 0046 real-text recall links ArchiveEmbedApple on macOS only.
    // The macOS-only references must be #if-gated, not .when-conditioned:
    // SwiftPM on Linux still validates target names that never exist there
    // and fails the whole manifest with a misleading missing-sources error.)
    .executableTarget(name: "Benchmarks", dependencies: benchDeps),
]

let evalTargets: [Target] = [
    // Judged relevance set (DESIGN 6A, decision 0028): deterministic
    // topical corpus, metrics, and the runner the CI gate test drives.
    .target(
        name: "SearchEval",
        dependencies: ["ArchiveCore", "ArchiveSearch", "MailMIME"],
        resources: [.copy("qrels.json")]
    ),
    // SemanticSliceTests loads the toy CoreML embedding model, so the
    // ArchiveEmbedApple reference is macOS-only (see note above).
    .testTarget(name: "SearchEvalTests", dependencies: searchEvalTestDeps, resources: [.copy("toy_vocab.txt"), .copy("toy_embedding.mlmodel")]),
]

let testTargets: [Target] = [
    .testTarget(name: "ArchiveCoreTests", dependencies: ["ArchiveCore"]),
    .testTarget(name: "ArchiveSearchTests", dependencies: ["ArchiveSearch"]),
    .testTarget(name: "ArchiveExtractTests", dependencies: ["ArchiveExtract"]),
    .testTarget(name: "MailMIMETests", dependencies: ["MailMIME"]),
    .testTarget(name: "CredentialsTests", dependencies: ["Credentials"]),
]

let targets: [Target] =
    coreTargets + spikeTargets + viewerTargets + appleExtractTargets + appleEmbedTargets
    + testTargets + evalTargets

let package = Package(
    name: "EmailArchiver",
    platforms: [.macOS(.v15)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
