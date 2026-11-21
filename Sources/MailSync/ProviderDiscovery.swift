// The discovery chain (PROVIDERS, "What Generic IMAP Gets From This"). Given an
// email address, find the provider settings to connect with, in this order:
//
//   1. the bundled provider database, keyed by domain (and its aliases);
//   2. Mozilla's ISPDB autoconfig;
//   3. autoconfig.<domain> and /.well-known/autoconfig;
//   4. RFC 6186 SRV records (_imaps._tcp);
//   5. MX lookup to spot hosted Google and Microsoft domains;
//   6. manual entry.
//
// This file implements link 1 (the database) and link 5 (the MX heuristic)
// fully, and defines the protocol the network sources (2, 3, 4) plug into.
// The network sources are exercised in tests with fakes; the real DNS/HTTP
// fetchers are added when onboarding wires them up. Nothing here touches the
// network or a real account.

import Foundation

/// The outcome of a discovery step. A step either produces a candidate (and
/// the chain stops) or says "not me, try the next one".
public enum DiscoveryCandidate: Sendable, Equatable {
    /// A known provider from the database.
    case provider(ProviderProfile)
    /// A provider found by a network source (ISPDB / autoconfig / SRV). The
    /// engine connects with these settings and the conservative politeness
    /// defaults, then learns from the server.
    case discovered(DiscoveredServer)
    /// The MX lookup shows the domain is hosted by Google or Microsoft; use
    /// that provider's settings (OAuth in M5).
    case hostedBy(ProviderProfile)
    /// Nothing found; the person enters the settings by hand.
    case manual
}

/// A server a network source found. No politeness or quirk assumptions — the
/// engine starts conservative and learns from the server's capabilities.
public struct DiscoveredServer: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var useTLS: Bool
    public var credential: CredentialKind
    /// Which source found it, for the onboarding UI ("found via autoconfig").
    public var source: String

    public init(host: String, port: Int, useTLS: Bool, credential: CredentialKind, source: String) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.credential = credential
        self.source = source
    }
}

/// A network source in the chain: ISPDB, autoconfig, SRV, or MX. A source
/// returns a candidate or nil (not me). Tests use fakes; the real fetchers
/// implement the same protocol.
public protocol ProviderDiscoverySource: Sendable {
    /// The human-readable name of this source, for the onboarding UI.
    var name: String { get }
    /// Find a candidate for the domain, or nil if this source has nothing.
    func find(domain: String) -> DiscoveryCandidate?
}

/// The MX→hosted-provider heuristic (link 5). A domain whose MX records point
/// at Google's or Microsoft's mail servers is hosted by that provider, even
/// though the domain itself is not gmail.com / outlook.com. The MX lookup is
/// injected so this is testable without DNS.
public struct MXHeuristicSource: ProviderDiscoverySource {
    public let name = "MX lookup"

    /// The MX lookup: domain -> the mail-exchange hostnames, in priority order.
    /// The real implementation does a DNS MX query; tests inject a fake.
    public let lookup: @Sendable (String) -> [String]

    /// MX hostnames that identify a hosted-Google mailbox.
    private static let googleMX = [
        "googlemail-l-in", "googlemail-l-out", "googlemail-l",
        "aspmx.l.google.com", "alt1.aspmx.l.google.com", "alt2.aspmx.l.google.com",
        "aspmx2.googlemail.com", "aspmx3.googlemail.com", "aspmx4.googlemail.com",
    ]
    /// MX hostnames that identify a hosted-Microsoft mailbox.
    private static let microsoftMX = [
        "mx10.outlook.com", "mx20.outlook.com", "mx30.outlook.com",
        "mx10.mail.protection.outlook.com", "mx20.mail.protection.outlook.com",
        "mx30.mail.protection.outlook.com", "smtp.protection.outlook.com",
    ]

    public init(lookup: @escaping @Sendable (String) -> [String]) {
        self.lookup = lookup
    }

    public func find(domain: String) -> DiscoveryCandidate? {
        let mxs = lookup(domain).map { $0.lowercased() }
        if mxs.contains(where: { Self.googleMX.contains($0) }) {
            return .hostedBy(ProviderDatabase.gmail)
        }
        if mxs.contains(where: { Self.microsoftMX.contains($0) }) {
            return .hostedBy(ProviderDatabase.outlook)
        }
        return nil
    }
}

/// The full discovery chain. Sources are tried in order; the first non-nil
/// candidate wins. The bundled database is always first; manual entry is the
/// guaranteed last resort.
public struct ProviderDiscovery: Sendable {
    /// The sources in order, after the database and before manual entry.
    public let sources: [any ProviderDiscoverySource]

    public init(sources: [any ProviderDiscoverySource] = []) {
        self.sources = sources
    }

    /// Find the provider settings for an email address.
    public func resolve(_ address: String) -> DiscoveryCandidate {
        guard let domain = Self.domain(from: address) else {
            return .manual
        }
        // Link 1: the bundled database, keyed by domain and its aliases.
        if let known = ProviderDatabase.profile(forDomain: domain) {
            return .provider(known)
        }
        // Links 2-4 (and 5): the network sources, in order.
        for source in sources {
            if let candidate = source.find(domain: domain) {
                return candidate
            }
        }
        // Link 6: manual entry.
        return .manual
    }

    /// The domain part of an email address, lower-cased, without a leading
    /// dot. Returns nil for an address with no domain.
    public static func domain(from address: String) -> String? {
        guard let at = address.lastIndex(of: "@") else { return nil }
        let domain = address[address.index(after: at)...].lowercased()
        guard !domain.isEmpty, domain.first != "." else { return nil }
        return String(domain)
    }
}

public extension ProviderDatabase {
    /// The provider whose domains include the given domain, or nil. The
    /// database is small (twenty rows), so a linear scan is fine and keeps the
    /// lookup allocation-free.
    static func profile(forDomain domain: String) -> ProviderProfile? {
        let domain = domain.lowercased()
        for profile in all where !profile.domains.isEmpty {
            if profile.domains.contains(domain) {
                return profile
            }
        }
        return nil
    }
}
