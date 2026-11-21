// Provider settings and the discovery chain (PROVIDERS, "What Generic IMAP
// Gets From This"; DESIGN 5). The bundled provider database is the first link
// in the chain; network sources (ISPDB, autoconfig, SRV, MX) plug in behind
// the same protocol. Everything here is pure data and pure logic: no network,
// no secrets. The sync engine reads a ProviderProfile to know where to connect,
// how to authenticate, how politely to behave, and which quirks to expect.

import Foundation

/// How the connection is secured. Plaintext is never offered: a provider that
/// only allows plaintext is not supported (PROVIDERS: "never plaintext").
public enum TLSPolicy: Sendable, Equatable, Codable {
    /// Implicit TLS on the dedicated port (993). The default for every M4
    /// provider.
    case implicit(port: Int)
    /// STARTTLS on the shared port (143), only when the server requires it.
    case starttls(port: Int)
}

/// What the person hands the app to authenticate, and therefore what the
/// credential store holds. M4 providers all authenticate on the wire with the
/// stored secret (AUTHENTICATE PLAIN / LOGIN); OAuth (M5) holds a token.
public enum CredentialKind: Sendable, Equatable, Codable {
    /// The account password. Rare for M4 (most providers require an app
    /// password or authorization code once two-factor is on).
    case accountPassword
    /// A provider-issued app password (iCloud, Yahoo, Comcast, Orange, ...).
    case appPassword
    /// A client authorization code (QQ, 163/126, Mail.ru).
    case authorizationCode
    /// The Proton Mail Bridge's local IMAP password.
    case bridgePassword
    /// An OAuth token (M5).
    case oauthToken
}

/// A single server-side quirk the engine must handle. Kept as an enum (not a
/// free-form string) so the engine can switch on it and a test can assert an
/// exact set.
public enum ProviderQuirk: Sendable, Equatable, Codable, CaseIterable {
    /// Refuses SELECT until the client sends an RFC 2971 ID command first
    /// (NetEase 163/126: "Unsafe Login").
    case requiresIDBeforeSelect
    /// Folder names come back localized; match by SPECIAL-USE, not by name.
    case localizedFolders
    /// Aggressive connection limits and silent disconnects on long sessions;
    /// keep sessions short and re-SELECT (Yahoo, AOL, AT&T).
    case shortSessions
    /// Labels appear as folders; sync the All-Mail folder once and record
    /// labels from X-GM-LABELS instead of downloading each label folder.
    case gmailLabels
    /// A self-signed certificate on localhost (Proton Bridge); trust only after
    /// the person confirms the fingerprint.
    case selfSignedLocalhost
    /// Repeated re-prompts on auth; surface failures clearly instead of
    /// retrying (Comcast/Xfinity).
    case flakyAuth
}

/// Politeness limits for one provider (DESIGN 5 "Politeness and Limits").
/// Defaults are conservative; a provider overrides only where documented.
public struct PolitenessProfile: Sendable, Equatable, Codable {
    /// Maximum concurrent IMAP connections. Start at 2 for most, 4 for
    /// Fastmail and self-hosted.
    public var maxConnections: Int
    /// Daily download byte budget. Gmail/Workspace stay under ~2,000 MB to
    /// leave the person's own clients headroom; nil means "no documented cap,
    /// pace by connection count only".
    public var dailyByteBudget: Int?
    /// Pause between fetch batches, in seconds.
    public var batchPauseSeconds: Double

    public init(maxConnections: Int = 2, dailyByteBudget: Int? = nil, batchPauseSeconds: Double = 1.0) {
        self.maxConnections = maxConnections
        self.dailyByteBudget = dailyByteBudget
        self.batchPauseSeconds = batchPauseSeconds
    }

    /// The conservative default for an unknown provider.
    public static let `default` = PolitenessProfile()
}

/// One provider's settings: where to connect, how to authenticate, what the
/// person must set up first, how politely to behave, and which quirks to
/// expect. Built from PROVIDERS.md; the M0 spikes confirm each against a live
/// account before the sync engine depends on it.
public struct ProviderProfile: Sendable, Equatable {
    /// Stable id, e.g. "gmail", "icloud", "fastmail". Lower-case, no spaces.
    public var id: String
    /// Display name shown in the provider picker.
    public var displayName: String
    /// IMAP host.
    public var host: String
    public var tls: TLSPolicy
    /// What the person provides to authenticate.
    public var credential: CredentialKind
    /// Whether the provider also supports OAuth (M5). Informational for
    /// onboarding ("you can also sign in with OAuth later").
    public var supportsOAuth: Bool
    /// Human-readable setup steps, in order, with links. Shown verbatim in
    /// onboarding.
    public var setupSteps: [String]
    /// A help link for this provider's mail settings.
    public var helpURL: URL?
    public var politeness: PolitenessProfile
    public var quirks: Set<ProviderQuirk>
    /// The primary domain plus every alias domain that resolves to this
    /// provider (e.g. AT&T's legacy domains, GMX's .com, Orange's wanadoo).
    /// All lower-case, no leading dot.
    public var domains: [String]

    public init(
        id: String,
        displayName: String,
        host: String,
        tls: TLSPolicy,
        credential: CredentialKind,
        supportsOAuth: Bool = false,
        setupSteps: [String] = [],
        helpURL: URL? = nil,
        politeness: PolitenessProfile = .default,
        quirks: Set<ProviderQuirk> = [],
        domains: [String]
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.tls = tls
        self.credential = credential
        self.supportsOAuth = supportsOAuth
        self.setupSteps = setupSteps
        self.helpURL = helpURL
        self.politeness = politeness
        self.quirks = quirks
        self.domains = domains
    }
}

/// A provider the person types in by hand when discovery finds nothing: the
/// last link in the chain. No politeness or quirk assumptions — the engine
/// starts from the conservative defaults and learns from the server.
public struct ManualProvider: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var useTLS: Bool
    public var credential: CredentialKind

    public init(host: String, port: Int, useTLS: Bool, credential: CredentialKind) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.credential = credential
    }

    /// The conservative profile a manual entry connects with.
    public var profile: ProviderProfile {
        ProviderProfile(
            id: "manual-\(host)",
            displayName: host,
            host: host,
            tls: useTLS ? .implicit(port: port) : .starttls(port: port),
            credential: credential,
            politeness: .default,
            domains: []
        )
    }
}
