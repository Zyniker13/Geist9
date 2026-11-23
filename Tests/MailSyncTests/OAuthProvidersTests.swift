// The OAuth provider configurations' shape and rules: one entry per
// OAuth-capable provider, distinct endpoints, scopes that are read-only
// where the provider offers one, client IDs read from the environment
// and never committed. Endpoints are exercised end-to-end only against
// the local OAuth test server (never a live provider).

import Foundation
import Testing

@testable import MailSync

@Suite("OAuthProviders")
struct OAuthProvidersTests {
    @Test func everyOAuthProviderHasAConfig() {
        for id in ["outlook", "gmail", "yahoo", "aol", "yandex", "zoho", "fastmail"] {
            #expect(OAuthProviders.config(for: id) != nil, "missing OAuth config for \(id)")
        }
        // M4-only providers have no OAuth path.
        #expect(OAuthProviders.config(for: "icloud") == nil)
        #expect(OAuthProviders.config(for: "qq") == nil)
        #expect(OAuthProviders.config(for: "netease") == nil)
    }

    @Test func endpointsAreDistinctAndHTTPS() {
        for config in OAuthProviders.all {
            #expect(config.authorizeEndpoint.scheme == "https", "\(config.id) authorize must be https")
            #expect(config.tokenEndpoint.scheme == "https", "\(config.id) token must be https")
            #expect(config.authorizeEndpoint != config.tokenEndpoint, "\(config.id) endpoints must differ")
            if let revoke = config.revocationEndpoint {
                #expect(revoke.scheme == "https", "\(config.id) revoke must be https")
            }
        }
    }

    @Test func idsMatchProviderProfiles() {
        // Every OAuth config names a real provider profile.
        for config in OAuthProviders.all {
            let profile = ProviderDatabase.all.first { $0.id == config.id }
            #expect(profile != nil, "OAuth config for unknown provider \(config.id)")
            #expect(profile?.supportsOAuth == true, "\(config.id) profile must support OAuth")
        }
    }

    @Test func scopesAreReadOnlyWhereTheProviderOffersOne() {
        // Providers with a read-only scope use it (DESIGN 4).
        #expect(OAuthProviders.yahoo.scope == "mail-r")
        #expect(OAuthProviders.aol.scope == "mail-r")
        #expect(OAuthProviders.zoho.scope.contains("READ"))
        #expect(OAuthProviders.yandex.scope.contains("imap_login"))
        // Google and Microsoft have no read-only IMAP scope; the
        // privacy policy must explain those two.
        #expect(OAuthProviders.google.scope == "https://mail.google.com/")
        #expect(OAuthProviders.microsoft.scope.contains("IMAP.AccessAsUser.All"))
        // Microsoft must request offline_access or no refresh token is
        // issued and the whole refresh contract is dead.
        #expect(OAuthProviders.microsoft.scope.contains("offline_access"))
    }

    @Test func clientIDComesFromTheEnvironmentNotTheBinary() {
        let key = OAuthProviders.microsoft.clientIDEnvironmentKey
        #expect(key == "BRISTLECONE_MICROSOFT_CLIENT_ID")
        // Absent: OAuth is off for the provider.
        #expect(OAuthProviders.microsoft.clientID(environment: [:]) == nil)
        // Whitespace-only: still off.
        #expect(OAuthProviders.microsoft.clientID(environment: [key: "   "]) == nil)
        // Present: handed through verbatim.
        #expect(OAuthProviders.microsoft.clientID(environment: [key: "test-client-id"]) == "test-client-id")
    }

    @Test func everyEnvironmentKeyIsNamespaced() {
        // The key names the provider company, which for two entries
        // differs from the profile id (Outlook → Microsoft, Gmail →
        // Google); the mapping is pinned here so a rename cannot drift.
        let expected = [
            "outlook": "BRISTLECONE_MICROSOFT_CLIENT_ID",
            "gmail": "BRISTLECONE_GOOGLE_CLIENT_ID",
            "yahoo": "BRISTLECONE_YAHOO_CLIENT_ID",
            "aol": "BRISTLECONE_AOL_CLIENT_ID",
            "yandex": "BRISTLECONE_YANDEX_CLIENT_ID",
            "zoho": "BRISTLECONE_ZOHO_CLIENT_ID",
            "fastmail": "BRISTLECONE_FASTMAIL_CLIENT_ID",
        ]
        for config in OAuthProviders.all {
            #expect(config.clientIDEnvironmentKey.hasPrefix("BRISTLECONE_"), "\(config.id) key must be namespaced")
            #expect(config.clientIDEnvironmentKey == expected[config.id], "\(config.id) key drifted")
        }
    }
}
