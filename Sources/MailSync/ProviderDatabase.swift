// The bundled provider database (PROVIDERS.md, "Provider Matrix"). One row per
// provider: host, port, TLS, credential kind, setup steps, help link,
// politeness, quirks, and the domains that resolve to it. This is the first
// link in the discovery chain; the network sources (ISPDB, autoconfig, SRV,
// MX) come after it.
//
// Every value here is taken from PROVIDERS.md (researched November 2026).
// Where the doc names only a primary domain, only that domain is listed —
// alias domains are added only when the doc names them (iCloud @me.com/
// @mac.com, AT&T legacy domains, Orange wanadoo, GMX gmx.com, NetEase
// 126/yeah.net, AOL verizon.net). The M0 spikes confirm each row against a
// live account before the sync engine depends on it.

import Foundation

public enum ProviderDatabase {
    /// Every bundled provider, in the order PROVIDERS.md lists them.
    public static let all: [ProviderProfile] = [
        gmail,
        googleWorkspace,
        icloud,
        outlook,
        microsoft365,
        yahoo,
        qq,
        netease,
        aol,
        proton,
        yandex,
        mailRu,
        gmx,
        webDe,
        zoho,
        naver,
        comcast,
        att,
        tOnline,
        orange,
        fastmail,
        tuta,
    ]

    // MARK: The twenty (PROVIDERS.md order)

    static let gmail = ProviderProfile(
        id: "gmail",
        displayName: "Gmail",
        host: "imap.gmail.com",
        tls: .implicit(port: 993),
        credential: .appPassword,
        supportsOAuth: true,
        setupSteps: [
            "For an app password: turn on 2-Step Verification, then create an app password.",
            "IMAP is always on since 2025; nothing else to enable.",
            "For OAuth (later): nothing — the app signs you in.",
        ],
        helpURL: URL(string: "https://support.google.com/accounts/answer/185833"),
        politeness: PolitenessProfile(maxConnections: 2, dailyByteBudget: 2_500_000_000, batchPauseSeconds: 1.0),
        quirks: [.gmailLabels, .localizedFolders],
        domains: ["gmail.com", "googlemail.com"]
    )

    static let googleWorkspace = ProviderProfile(
        id: "google-workspace",
        displayName: "Google Workspace",
        host: "imap.gmail.com",
        tls: .implicit(port: 993),
        credential: .appPassword,
        supportsOAuth: true,
        setupSteps: [
            "Same as Gmail. An admin may need to allowlist the app or app passwords.",
        ],
        helpURL: URL(string: "https://support.google.com/a/answer/1722430"),
        politeness: PolitenessProfile(maxConnections: 2, dailyByteBudget: 2_500_000_000, batchPauseSeconds: 1.0),
        quirks: [.gmailLabels, .localizedFolders],
        domains: [] // tenant-specific; discovered by the MX heuristic
    )

    static let icloud = ProviderProfile(
        id: "icloud",
        displayName: "iCloud Mail",
        host: "imap.mail.me.com",
        tls: .implicit(port: 993),
        credential: .appPassword,
        supportsOAuth: false,
        setupSteps: [
            "Turn on two-factor authentication for your Apple ID.",
            "Create an app-specific password at account.apple.com.",
        ],
        helpURL: URL(string: "https://support.apple.com/en-us/102525"),
        politeness: PolitenessProfile(maxConnections: 2, dailyByteBudget: nil, batchPauseSeconds: 1.0),
        quirks: [],
        domains: ["icloud.com", "me.com", "mac.com"]
    )

    static let outlook = ProviderProfile(
        id: "outlook",
        displayName: "Outlook.com / Hotmail / Live",
        host: "outlook.office365.com",
        tls: .implicit(port: 993),
        credential: .oauthToken,
        supportsOAuth: true,
        setupSteps: [
            "Personal Outlook accounts no longer accept a password for IMAP (2024).",
            "Sign in with OAuth (the app does this); no setup needed.",
        ],
        helpURL: URL(string: "https://support.microsoft.com/office/outlook-and-other-apps-are-unable-to-connect-to-outlook-com-f4202ebf-89c6-4a8a-bec3-3d60cf7deaef"),
        politeness: PolitenessProfile(maxConnections: 2, dailyByteBudget: nil, batchPauseSeconds: 1.0),
        quirks: [.localizedFolders, .shortSessions],
        domains: ["outlook.com", "hotmail.com", "live.com"]
    )

    static let microsoft365 = ProviderProfile(
        id: "microsoft-365",
        displayName: "Microsoft 365 / Exchange Online",
        host: "outlook.office365.com",
        tls: .implicit(port: 993),
        credential: .oauthToken,
        supportsOAuth: true,
        setupSteps: [
            "Work or school accounts sign in with OAuth; an admin may need to consent.",
            "If IMAP is disabled per mailbox, the app falls back to Microsoft Graph (1.x).",
        ],
        helpURL: URL(string: "https://learn.microsoft.com/office365/enterprise/imap-in-exchange-online"),
        politeness: PolitenessProfile(maxConnections: 2, dailyByteBudget: nil, batchPauseSeconds: 1.0),
        quirks: [.localizedFolders, .shortSessions],
        domains: [] // tenant-specific; discovered by the MX heuristic
    )

    static let yahoo = ProviderProfile(
        id: "yahoo",
        displayName: "Yahoo Mail",
        host: "imap.mail.yahoo.com",
        tls: .implicit(port: 993),
        credential: .appPassword,
        supportsOAuth: true,
        setupSteps: [
            "Generate an app password under Account security.",
            "Yahoo is ending basic-auth IMAP; an app password is the dependable path.",
        ],
        helpURL: URL(string: "https://help.yahoo.com/kb/SLN36636.html"),
        politeness: PolitenessProfile(maxConnections: 2, dailyByteBudget: nil, batchPauseSeconds: 1.0),
        quirks: [.shortSessions],
        domains: ["yahoo.com"]
    )

    static let qq = ProviderProfile(
        id: "qq",
        displayName: "QQ Mail",
        host: "imap.qq.com",
        tls: .implicit(port: 993),
        credential: .authorizationCode,
        supportsOAuth: false,
        setupSteps: [
            "Turn on IMAP/SMTP in webmail settings, then generate the authorization code (shown once).",
            "Changing the QQ password revokes every code.",
        ],
        helpURL: URL(string: "https://help.mail.qq.com/"),
        politeness: PolitenessProfile(maxConnections: 2, dailyByteBudget: nil, batchPauseSeconds: 2.0),
        quirks: [],
        domains: ["qq.com"]
    )

    static let netease = ProviderProfile(
        id: "netease",
        displayName: "NetEase 163 / 126",
        host: "imap.163.com",
        tls: .implicit(port: 993),
        credential: .authorizationCode,
        supportsOAuth: false,
        setupSteps: [
            "Enable IMAP, then generate the client authorization code.",
            "The server refuses SELECT until the client sends an ID command first; the app does this automatically.",
        ],
        helpURL: URL(string: "https://help.mail.163.com/"),
        politeness: PolitenessProfile(maxConnections: 2, dailyByteBudget: nil, batchPauseSeconds: 2.0),
        quirks: [.requiresIDBeforeSelect],
        domains: ["163.com", "126.com", "yeah.net"]
    )

    static let aol = ProviderProfile(
        id: "aol",
        displayName: "AOL Mail",
        host: "imap.aol.com",
        tls: .implicit(port: 993),
        credential: .appPassword,
        supportsOAuth: true,
        setupSteps: [
            "Generate an app password (AOL runs on Yahoo infrastructure).",
        ],
        helpURL: URL(string: "https://help.aol.com/articles/"),
        politeness: PolitenessProfile(maxConnections: 2, dailyByteBudget: nil, batchPauseSeconds: 1.0),
        quirks: [.shortSessions],
        domains: ["aol.com", "verizon.net"]
    )

    static let proton = ProviderProfile(
        id: "proton",
        displayName: "Proton Mail (Bridge)",
        host: "127.0.0.1",
        tls: .implicit(port: 1143),
        credential: .bridgePassword,
        supportsOAuth: false,
        setupSteps: [
            "Install and sign in to Proton Mail Bridge (paid plans).",
            "Copy Bridge's IMAP password; confirm its certificate fingerprint.",
            "Free accounts: import from Proton's export tool instead.",
        ],
        helpURL: URL(string: "https://proton.me/support/imap-smtp-and-pop3-setup"),
        politeness: PolitenessProfile(maxConnections: 1, dailyByteBudget: nil, batchPauseSeconds: 1.0),
        quirks: [.selfSignedLocalhost],
        domains: ["proton.me", "protonmail.com"]
    )

    static let yandex = ProviderProfile(
        id: "yandex",
        displayName: "Yandex Mail",
        host: "imap.yandex.com",
        tls: .implicit(port: 993),
        credential: .appPassword,
        supportsOAuth: true,
        setupSteps: [
            "Turn on IMAP and the \"app passwords and OAuth tokens\" switch, then create an app password.",
        ],
        helpURL: URL(string: "https://www.yandex.com/support/mail/mail-clients/others.html"),
        politeness: PolitenessProfile(maxConnections: 2, dailyByteBudget: nil, batchPauseSeconds: 1.0),
        quirks: [],
        domains: ["yandex.com", "yandex.ru", "yandex.net", "ya.ru"]
    )

    static let mailRu = ProviderProfile(
        id: "mail-ru",
        displayName: "Mail.ru",
        host: "imap.mail.ru",
        tls: .implicit(port: 993),
        credential: .appPassword,
        supportsOAuth: true,
        setupSteps: [
            "Create the external-app password at id.mail.ru.",
        ],
        helpURL: URL(string: "https://my.mail.ru/"),
        politeness: PolitenessProfile(maxConnections: 2, dailyByteBudget: nil, batchPauseSeconds: 1.0),
        quirks: [],
        domains: ["mail.ru"]
    )

    static let gmx = ProviderProfile(
        id: "gmx",
        displayName: "GMX",
        host: "imap.gmx.net",
        tls: .implicit(port: 993),
        credential: .appPassword,
        supportsOAuth: true,
        setupSteps: [
            "Turn on POP3/IMAP access in settings (off by default).",
        ],
        helpURL: URL(string: "https://www.gmx.net/"),
        politeness: PolitenessProfile(maxConnections: 2, dailyByteBudget: nil, batchPauseSeconds: 1.0),
        quirks: [],
        domains: ["gmx.net", "gmx.com"]
    )

    static let webDe = ProviderProfile(
        id: "web-de",
        displayName: "WEB.DE",
        host: "imap.web.de",
        tls: .implicit(port: 993),
        credential: .appPassword,
        supportsOAuth: true,
        setupSteps: [
            "Turn on IMAP access in settings (same platform as GMX).",
        ],
        helpURL: URL(string: "https://www.web.de/"),
        politeness: PolitenessProfile(maxConnections: 2, dailyByteBudget: nil, batchPauseSeconds: 1.0),
        quirks: [],
        domains: ["web.de"]
    )

    static let zoho = ProviderProfile(
        id: "zoho",
        displayName: "Zoho Mail",
        host: "imap.zoho.com",
        tls: .implicit(port: 993),
        credential: .appPassword,
        supportsOAuth: true,
        setupSteps: [
            "Enable IMAP in settings (paid plans).",
            "The data-center region decides the host; the app detects it from the address.",
        ],
        helpURL: URL(string: "https://www.zoho.com/mail/help/"),
        politeness: PolitenessProfile(maxConnections: 2, dailyByteBudget: nil, batchPauseSeconds: 1.0),
        quirks: [],
        domains: ["zoho.com"]
    )

    static let naver = ProviderProfile(
        id: "naver",
        displayName: "Naver Mail",
        host: "imap.naver.com",
        tls: .implicit(port: 993),
        credential: .appPassword,
        supportsOAuth: false,
        setupSteps: [
            "Turn on IMAP in Naver Mail settings.",
        ],
        helpURL: URL(string: "https://help.naver.com/"),
        politeness: PolitenessProfile(maxConnections: 2, dailyByteBudget: nil, batchPauseSeconds: 2.0),
        quirks: [],
        domains: ["naver.com"]
    )

    static let comcast = ProviderProfile(
        id: "comcast",
        displayName: "Comcast / Xfinity",
        host: "imap.comcast.net",
        tls: .implicit(port: 993),
        credential: .appPassword,
        supportsOAuth: false,
        setupSteps: [
            "Turn on \"Third Party Access Security\" in Xfinity's settings.",
        ],
        helpURL: URL(string: "https://forums.xfinity.com/conversations/email/imap-password-on-3rd-party-apps/69e395f58d70f67d063153ec"),
        politeness: PolitenessProfile(maxConnections: 2, dailyByteBudget: nil, batchPauseSeconds: 1.0),
        quirks: [.flakyAuth],
        domains: ["comcast.net", "xfinity.com"]
    )

    static let att = ProviderProfile(
        id: "att",
        displayName: "AT&T Mail",
        host: "imap.mail.att.net",
        tls: .implicit(port: 993),
        credential: .appPassword,
        supportsOAuth: false,
        setupSteps: [
            "Create a secure mail key in AT&T's profile.",
        ],
        helpURL: URL(string: "https://www.att.com/"),
        politeness: PolitenessProfile(maxConnections: 2, dailyByteBudget: nil, batchPauseSeconds: 1.0),
        quirks: [.shortSessions],
        domains: ["att.net", "sbcglobal.net"]
    )

    static let tOnline = ProviderProfile(
        id: "t-online",
        displayName: "T-Online",
        host: "secureimap.t-online.de",
        tls: .implicit(port: 993),
        credential: .appPassword,
        supportsOAuth: false,
        setupSteps: [
            "Set the separate \"password for email programs\" in the E-Mail Center.",
        ],
        helpURL: URL(string: "https://www.t-online.de/"),
        politeness: PolitenessProfile(maxConnections: 2, dailyByteBudget: nil, batchPauseSeconds: 1.0),
        quirks: [],
        domains: ["t-online.de"]
    )

    static let orange = ProviderProfile(
        id: "orange",
        displayName: "Orange",
        host: "imap.orange.fr",
        tls: .implicit(port: 993),
        credential: .appPassword,
        supportsOAuth: false,
        setupSteps: [
            "Turn on IMAP in webmail settings, then create an application password.",
        ],
        helpURL: URL(string: "https://www.orange.fr/"),
        politeness: PolitenessProfile(maxConnections: 2, dailyByteBudget: nil, batchPauseSeconds: 1.0),
        quirks: [],
        domains: ["orange.fr", "wanadoo.fr"]
    )

    static let fastmail = ProviderProfile(
        id: "fastmail",
        displayName: "Fastmail",
        host: "imap.fastmail.com",
        tls: .implicit(port: 993),
        credential: .appPassword,
        supportsOAuth: true,
        setupSteps: [
            "Create a read-only API token (for JMAP, M6) or an app password (for IMAP).",
        ],
        helpURL: URL(string: "https://fastmail.com/dev/"),
        politeness: PolitenessProfile(maxConnections: 4, dailyByteBudget: nil, batchPauseSeconds: 0.5),
        quirks: [],
        domains: ["fastmail.com"]
    )

    static let tuta = ProviderProfile(
        id: "tuta",
        displayName: "Tuta",
        host: "",
        tls: .implicit(port: 993),
        credential: .accountPassword,
        supportsOAuth: false,
        setupSteps: [
            "Tuta has no IMAP. Export from the Tuta desktop app and import the .eml/mbox files.",
        ],
        helpURL: URL(string: "https://tuta.com/"),
        politeness: PolitenessProfile(),
        quirks: [],
        domains: ["tuta.com"]
    )
}
