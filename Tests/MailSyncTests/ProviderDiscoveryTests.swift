// Tests for the provider database and discovery chain (PROVIDERS, "What
// Generic IMAP Gets From This"). These assert the documented facts from
// PROVIDERS.md: the twenty providers plus Fastmail and Tuta, their hosts,
// credential kinds, the alias domains the doc names, and the discovery order
// (database, then network sources, then manual). The network sources are
// exercised with fakes; nothing here touches the network or a real account.

import XCTest
@testable import MailSync

final class ProviderDatabaseTests: XCTestCase {
    // The twenty providers plus Fastmail and Tuta, in PROVIDERS.md order.
    private let expectedIDs: [String] = [
        "gmail", "google-workspace", "icloud", "outlook", "microsoft-365",
        "yahoo", "qq", "netease", "aol", "proton", "yandex", "mail-ru",
        "gmx", "web-de", "zoho", "naver", "comcast", "att", "t-online",
        "orange", "fastmail", "tuta",
    ]

    func testAllTwentyPlusTwoArePresent() {
        XCTAssertEqual(ProviderDatabase.all.count, 22)
        XCTAssertEqual(ProviderDatabase.all.map(\.id), expectedIDs)
    }

    func testIDsAreUnique() {
        let ids = ProviderDatabase.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testEveryProviderHasAHostExceptTuta() {
        for profile in ProviderDatabase.all where profile.id != "tuta" {
            XCTAssertFalse(profile.host.isEmpty, "\(profile.id) has no host")
        }
    }

    func testEveryProviderHasDomainsExceptTheTwoTenantProviders() {
        for profile in ProviderDatabase.all where profile.id != "google-workspace" && profile.id != "microsoft-365" {
            XCTAssertFalse(profile.domains.isEmpty, "\(profile.id) has no domains")
        }
    }

    func testCredentialKindsMatchTheDoc() {
        func credential(_ id: String) -> CredentialKind? {
            ProviderDatabase.all.first { $0.id == id }?.credential
        }
        XCTAssertEqual(credential("gmail"), .appPassword)
        XCTAssertEqual(credential("icloud"), .appPassword)
        XCTAssertEqual(credential("outlook"), .oauthToken)
        XCTAssertEqual(credential("microsoft-365"), .oauthToken)
        XCTAssertEqual(credential("qq"), .authorizationCode)
        XCTAssertEqual(credential("netease"), .authorizationCode)
        XCTAssertEqual(credential("proton"), .bridgePassword)
        XCTAssertEqual(credential("att"), .appPassword)
        XCTAssertEqual(credential("tuta"), .accountPassword)
    }

    func testQuirksMatchTheDoc() {
        func quirks(_ id: String) -> Set<ProviderQuirk> {
            ProviderDatabase.all.first { $0.id == id }?.quirks ?? []
        }
        XCTAssertTrue(quirks("gmail").contains(.gmailLabels))
        XCTAssertTrue(quirks("gmail").contains(.localizedFolders))
        XCTAssertTrue(quirks("netease").contains(.requiresIDBeforeSelect))
        XCTAssertTrue(quirks("yahoo").contains(.shortSessions))
        XCTAssertTrue(quirks("proton").contains(.selfSignedLocalhost))
        XCTAssertTrue(quirks("comcast").contains(.flakyAuth))
        XCTAssertTrue(quirks("outlook").contains(.localizedFolders))
    }

    func testGmailDailyBudgetIsTheDocumentedCap() {
        // 2,500 MB/day IMAP download (PROVIDERS.md, Google bandwidth limits).
        let gmail = ProviderDatabase.all.first { $0.id == "gmail" }
        XCTAssertEqual(gmail?.politeness.dailyByteBudget, 2_500_000_000)
    }

    func testHostsMatchTheDoc() {
        func host(_ id: String) -> String? {
            ProviderDatabase.all.first { $0.id == id }?.host
        }
        XCTAssertEqual(host("gmail"), "imap.gmail.com")
        XCTAssertEqual(host("icloud"), "imap.mail.me.com")
        XCTAssertEqual(host("outlook"), "outlook.office365.com")
        XCTAssertEqual(host("yahoo"), "imap.mail.yahoo.com")
        XCTAssertEqual(host("qq"), "imap.qq.com")
        XCTAssertEqual(host("netease"), "imap.163.com")
        XCTAssertEqual(host("aol"), "imap.aol.com")
        XCTAssertEqual(host("proton"), "127.0.0.1")
        XCTAssertEqual(host("yandex"), "imap.yandex.com")
        XCTAssertEqual(host("mail-ru"), "imap.mail.ru")
        XCTAssertEqual(host("gmx"), "imap.gmx.net")
        XCTAssertEqual(host("web-de"), "imap.web.de")
        XCTAssertEqual(host("zoho"), "imap.zoho.com")
        XCTAssertEqual(host("naver"), "imap.naver.com")
        XCTAssertEqual(host("comcast"), "imap.comcast.net")
        XCTAssertEqual(host("att"), "imap.mail.att.net")
        XCTAssertEqual(host("t-online"), "secureimap.t-online.de")
        XCTAssertEqual(host("orange"), "imap.orange.fr")
        XCTAssertEqual(host("fastmail"), "imap.fastmail.com")
    }
}

final class DomainResolutionTests: XCTestCase {
    func testPrimaryDomainsResolve() {
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "gmail.com")?.id, "gmail")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "icloud.com")?.id, "icloud")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "outlook.com")?.id, "outlook")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "yahoo.com")?.id, "yahoo")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "qq.com")?.id, "qq")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "163.com")?.id, "netease")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "aol.com")?.id, "aol")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "proton.me")?.id, "proton")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "yandex.com")?.id, "yandex")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "mail.ru")?.id, "mail-ru")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "gmx.net")?.id, "gmx")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "web.de")?.id, "web-de")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "zoho.com")?.id, "zoho")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "naver.com")?.id, "naver")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "comcast.net")?.id, "comcast")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "att.net")?.id, "att")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "t-online.de")?.id, "t-online")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "orange.fr")?.id, "orange")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "fastmail.com")?.id, "fastmail")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "tuta.com")?.id, "tuta")
    }

    func testAliasDomainsResolve() {
        // Aliases the doc names explicitly.
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "googlemail.com")?.id, "gmail")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "me.com")?.id, "icloud")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "mac.com")?.id, "icloud")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "126.com")?.id, "netease")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "yeah.net")?.id, "netease")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "verizon.net")?.id, "aol")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "sbcglobal.net")?.id, "att")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "wanadoo.fr")?.id, "orange")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "gmx.com")?.id, "gmx")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "protonmail.com")?.id, "proton")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "hotmail.com")?.id, "outlook")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "live.com")?.id, "outlook")
    }

    func testUnknownDomainResolvesToNil() {
        XCTAssertNil(ProviderDatabase.profile(forDomain: "example.com"))
        XCTAssertNil(ProviderDatabase.profile(forDomain: "mail.example.org"))
    }

    func testResolutionIsCaseInsensitive() {
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "GMAIL.com")?.id, "gmail")
        XCTAssertEqual(ProviderDatabase.profile(forDomain: "Me.COM")?.id, "icloud")
    }
}

final class MXHeuristicTests: XCTestCase {
    func testGoogleMXResolvesToGmail() {
        let source = MXHeuristicSource { domain in
            domain == "hosted.example.com" ? ["aspmx.l.google.com"] : []
        }
        XCTAssertEqual(source.find(domain: "hosted.example.com"), .hostedBy(ProviderDatabase.gmail))
    }

    func testMicrosoftMXResolvesToOutlook() {
        let source = MXHeuristicSource { domain in
            domain == "hosted.example.com" ? ["mx10.outlook.com"] : []
        }
        XCTAssertEqual(source.find(domain: "hosted.example.com"), .hostedBy(ProviderDatabase.outlook))
    }

    func testOtherMXResolvesToNil() {
        let source = MXHeuristicSource { _ in ["mail.example.com"] }
        XCTAssertNil(source.find(domain: "example.com"))
    }

    func testEmptyMXResolvesToNil() {
        let source = MXHeuristicSource { _ in [] }
        XCTAssertNil(source.find(domain: "example.com"))
    }
}

/// A fake network source for the discovery-chain tests: returns a fixed
/// candidate for a fixed domain, nil otherwise.
private struct FakeSource: ProviderDiscoverySource {
    let name: String
    let domain: String
    let candidate: DiscoveryCandidate
    func find(domain: String) -> DiscoveryCandidate? {
        domain == self.domain ? candidate : nil
    }
}

final class ProviderDiscoveryTests: XCTestCase {
    func testKnownDomainResolvesFromTheDatabase() {
        let discovery = ProviderDiscovery()
        XCTAssertEqual(discovery.resolve("alice@gmail.com"), .provider(ProviderDatabase.gmail))
        XCTAssertEqual(discovery.resolve("bob@me.com"), .provider(ProviderDatabase.icloud))
    }

    func testUnknownDomainWithNoSourcesFallsToManual() {
        let discovery = ProviderDiscovery()
        XCTAssertEqual(discovery.resolve("alice@example.com"), .manual)
    }

    func testAddressWithoutADomainFallsToManual() {
        let discovery = ProviderDiscovery()
        XCTAssertEqual(discovery.resolve("no-at-sign"), .manual)
        XCTAssertEqual(discovery.resolve("alice@"), .manual)
    }

    func testUnknownDomainWithASourceUsesTheSource() {
        let source = FakeSource(
            name: "autoconfig",
            domain: "example.com",
            candidate: .discovered(DiscoveredServer(
                host: "imap.example.com", port: 993, useTLS: true,
                credential: .accountPassword, source: "autoconfig"
            ))
        )
        let discovery = ProviderDiscovery(sources: [source])
        XCTAssertEqual(
            discovery.resolve("alice@example.com"),
            .discovered(DiscoveredServer(
                host: "imap.example.com", port: 993, useTLS: true,
                credential: .accountPassword, source: "autoconfig"
            ))
        )
    }

    func testDatabaseWinsOverSources() {
        // Even if a source would answer, the database (link 1) wins.
        let source = FakeSource(
            name: "autoconfig",
            domain: "gmail.com",
            candidate: .discovered(DiscoveredServer(
                host: "wrong.example.com", port: 993, useTLS: true,
                credential: .accountPassword, source: "autoconfig"
            ))
        )
        let discovery = ProviderDiscovery(sources: [source])
        XCTAssertEqual(discovery.resolve("alice@gmail.com"), .provider(ProviderDatabase.gmail))
    }

    func testMXSourceInTheChainResolvesHostedDomains() {
        let mx = MXHeuristicSource { domain in
            domain == "hosted.example.com" ? ["aspmx.l.google.com"] : []
        }
        let discovery = ProviderDiscovery(sources: [mx])
        XCTAssertEqual(discovery.resolve("alice@hosted.example.com"), .hostedBy(ProviderDatabase.gmail))
    }

    func testAddressParsing() {
        XCTAssertEqual(ProviderDiscovery.domain(from: "Alice@GMAIL.com"), "gmail.com")
        XCTAssertEqual(ProviderDiscovery.domain(from: "bob@me.com"), "me.com")
        XCTAssertNil(ProviderDiscovery.domain(from: "no-at-sign"))
        XCTAssertNil(ProviderDiscovery.domain(from: "alice@"))
        XCTAssertNil(ProviderDiscovery.domain(from: "alice@.com"))
    }
}

final class ManualProviderTests: XCTestCase {
    func testManualProfileIsConservative() {
        let manual = ManualProvider(host: "mail.example.com", port: 993, useTLS: true, credential: .accountPassword)
        let profile = manual.profile
        XCTAssertEqual(profile.host, "mail.example.com")
        XCTAssertEqual(profile.tls, .implicit(port: 993))
        XCTAssertEqual(profile.politeness, .default)
        XCTAssertTrue(profile.quirks.isEmpty)
    }
}
