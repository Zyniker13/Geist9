// swift-tools-version: 6.0
// Bristlecone Email Archiver. Core packages build and test on macOS and Linux; see docs/DESIGN.md section 12.
// The macOS-only targets (App, LoginItem, MCPHelper, OnePasswordHelper) live in the XcodeGen project, not here.
import PackageDescription

let package = Package(
    name: "EmailArchiver",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ArchiveCore", targets: ["ArchiveCore"]),
        .library(name: "MailMIME", targets: ["MailMIME"]),
        .library(name: "MailSync", targets: ["MailSync"]),
        .library(name: "ArchiveSearch", targets: ["ArchiveSearch"]),
        .library(name: "ArchiveExtract", targets: ["ArchiveExtract"]),
        .library(name: "ArchiveCrypto", targets: ["ArchiveCrypto"]),
        .library(name: "ArchiveMCP", targets: ["ArchiveMCP"]),
        .library(name: "Credentials", targets: ["Credentials"]),
    ],
    targets: [
        // models, archive format, index, migrations (DESIGN 6)
        .target(name: "ArchiveCore"),
        // parser, charsets, threading (DESIGN 7)
        .target(name: "MailMIME"),
        // IMAP, JMAP, provider database (DESIGN 5)
        .target(name: "MailSync"),
        // tokenizers, FTS, ranking, facets, query language (DESIGN 6A)
        .target(name: "ArchiveSearch"),
        // attachment text, OCR, entities, embeddings (DESIGN 6A)
        .target(name: "ArchiveExtract"),
        // envelope, SQLCipher glue (DESIGN 10)
        .target(name: "ArchiveCrypto"),
        // MCP server: tools, resources, access policy (DESIGN 9A)
        .target(name: "ArchiveMCP"),
        // CredentialStore, Keychain and 1Password backends (DESIGN 4)
        .target(name: "Credentials"),
        .testTarget(name: "ArchiveCoreTests", dependencies: ["ArchiveCore"]),
        .testTarget(name: "CredentialsTests", dependencies: ["Credentials"]),
    ]
)
