import Foundation

// The judged corpus assembly (DESIGN 6A, decision 0028): topical fixtures plus
// a deterministic seeded distractor set, rendered as RFC 822 for MailBridge.
// Everything here is invented and de-identified; the topical message text and
// the judgments in qrels.json move together.

let allTopicalMessages: [JudgedMessage] = birchlineMessages + alderfinchMessages
    + cedarrunMessages + northgateMessages + lakeviewMessages + norvairMessages
    + multilingualMessages + foldingMessages + namesMessages + datedMessages
    + phraseMessages + attachmentMessages + trigramMessages

// MARK: - Deterministic distractor corpus (n001-n260)

struct LCGRand {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    mutating func pick(_ options: [String]) -> String {
        options[Int(next() % UInt64(options.count))]
    }
}

let noiseVocabulary: [String] = [
    "project", "meeting", "notes", "agenda", "draft", "feedback", "launch",
    "roadmap", "team", "weekly", "update", "schedule", "plan", "discuss",
    "share", "summary", "design", "spec", "rollout", "demo", "standup",
    "retro", "deck", "portal", "sync", "checkin", "prep", "summary",
]

let noiseFillers: [String] = [
    "the", "about", "for", "with", "after", "before", "quick", "final",
    "please", "thanks", "today", "tomorrow", "next", "this", "round",
    "share", "send", "review", "check", "short", "long",
]

let noiseSenders: [String] = [
    "Noa Feld", "Rin Abe", "Paul Brandt", "Maike Horst", "Devin Cole",
    "Sara Lindt", "Owen Marsh", "Lea Novak", "Tariq Aziz", "Vera Bianchi",
    "Jonas Krebs", "Hana Vogel", "Iris Calder", "Marc Deleon", "Nina Fowler",
    "Piet Jansen", "Ruth Okafor", "Sven Aalto", "Talia Reiss", "Ulf Berger",
]

func noiseMessages(count: Int, seed: UInt64) -> [JudgedMessage] {
    var rand = LCGRand(seed: seed)
    var messages: [JudgedMessage] = []
    for index in 1...count {
        let id = String(format: "n%03d", index)
        let senderName = rand.pick(noiseSenders)
        let senderLocal = senderName.lowercased()
            .replacingOccurrences(of: " ", with: ".")
            + "\(index % 97)"
        let domain = rand.pick(["example.net", "example.org"])
        // Dates spread deterministically across 2019-2024.
        let year = 2019 + Int(rand.next() % 6)
        let month = 1 + Int(rand.next() % 12)
        let day = 1 + Int(rand.next() % 28)
        let hour = Int(rand.next() % 24)
        let minute = Int(rand.next() % 60)
        let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                          "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let date = String(
            format: "%@, %02d %@ %04d %02d:%02d:00 +0000",
            rand.pick(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]),
            day, monthNames[month - 1], year, hour, minute
        )
        let topicCount = 2 + Int(rand.next() % 3)
        var words: [String] = []
        for _ in 0..<topicCount {
            words.append(rand.pick(noiseVocabulary))
        }
        let subject = words.joined(separator: " ")
        var body = "Quick " + rand.pick(noiseFillers) + " " + rand.pick(noiseVocabulary)
            + " note" + rand.pick(noiseFillers) + " "
            + rand.pick(noiseVocabulary) + " team. "
            + rand.pick(noiseVocabulary) + " " + rand.pick(noiseFillers) + " "
            + rand.pick(noiseVocabulary) + " " + rand.pick(noiseFillers) + " "
            + rand.pick(noiseVocabulary) + "."
        if index % 5 == 0 {
            body += " The " + rand.pick(noiseVocabulary) + " review is scheduled for next week."
        }
        let mailbox = rand.pick(["INBOX", "Work", "Lists"])
        messages.append(JudgedMessage(
            id, date, "\(senderName) <\(senderLocal)@\(domain)>",
            "alice@example.com", subject, body, mailbox: mailbox
        ))
    }
    return messages
}

// MARK: - RFC 822 rendering

func makeBoundary(messageID: String) -> String {
    "JBOUND-" + messageID
}

// RFC 2047 B-encoding for header values with non-ASCII characters; plain
// ASCII passes through untouched. Bodies carry charset=utf-8 directly.
func encodedHeader(_ value: String) -> String {
    guard !value.allSatisfy(\.isASCII) else { return value }
    let encoded = Data(value.utf8).base64EncodedString()
    return "=?utf-8?B?\(encoded)?="
}

func renderRFC822(_ message: JudgedMessage) -> String {
    var lines: [String] = []
    lines.append("Message-ID: <\(message.id)@judged.example>")
    lines.append("Date: \(message.date)")
    lines.append("From: \(encodedHeader(message.from))")
    lines.append("To: \(encodedHeader(message.to))")
    if let cc = message.cc {
        lines.append("Cc: \(encodedHeader(cc))")
    }
    lines.append("Subject: \(encodedHeader(message.subject))")
    if message.attachments.isEmpty {
        lines.append("")
        lines.append(message.body)
    } else {
        let boundary = makeBoundary(messageID: message.id)
        lines.append("MIME-Version: 1.0")
        lines.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
        lines.append("")
        lines.append("--\(boundary)")
        lines.append("Content-Type: text/plain; charset=utf-8")
        lines.append("")
        lines.append(message.body)
        lines.append("")
        for attachment in message.attachments {
            lines.append("--\(boundary)")
            lines.append("Content-Type: \(attachment.contentType); charset=utf-8")
            lines.append("Content-Disposition: attachment; filename=\"\(attachment.filename)\"")
            lines.append("")
            lines.append(attachment.text)
            if !attachment.text.hasSuffix("\n") {
                lines.append("")
            }
        }
        lines.append("--\(boundary)--")
    }
    return lines.joined(separator: "\r\n") + "\r\n"
}

// MARK: - Corpus access

public enum JudgedCorpus {
    /// Topical message IDs, in corpus order, for the sanity check.
    public static let topicalIDs: [String] = allTopicalMessages.map { $0.id }

    /// The complete judged corpus: topical messages plus the deterministic
    /// distractor set, ready to ingest.
    public static func makeMessages() -> [JudgedMessage] {
        allTopicalMessages + noiseMessages(count: 260, seed: 0x6A75_6467_6564)
    }

    /// Rendered RFC 822 bytes, in ingest order.
    public static func makeRFC822() -> [String] {
        makeMessages().map(renderRFC822)
    }
}
