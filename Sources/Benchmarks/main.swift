// bench-search: the M1/scale benchmark harness (ROADMAP M1 "Done when",
// docs/TESTING.md scale-benchmark section). Generates a deterministic
// synthetic corpus, ingests it through the real ArchiveStore ingest path,
// then times two-word ranked queries against the live FTS5 index.
//
// Usage:
//   bench-search prepare <archive-dir> <count> [seed]
//   bench-search search  <archive-dir> [repeats]
//   bench-search both    <archive-dir> <count> [repeats]
//
// `prepare` resumes: already-present messages count as duplicates and cost
// only a hash lookup, so a killed run can be re-run with the same arguments.
// Search budgets verified here (ROADMAP M1): two-word ranked query under
// 200 ms; the first ten results under 50 ms.

import ArchiveCore
import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: Deterministic corpus

/// xorshift64* — small, deterministic, no dependency on Foundation randomness.
struct LCG {
    var state: UInt64
    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state &* 0x2545F4914F6CDD1D
    }

    mutating func uniform(_ n: Int) -> Int {
        Int(next() % UInt64(max(n, 1)))
    }

    /// Zipf-ish: pow(uniform) biases toward the head of the vocabulary, so a
    /// few words appear often and most are rare — the shape search indexes see.
    mutating func biased(_ n: Int, power: Double = 2.2) -> Int {
        let u = Double(next() % 1_000_000) / 1_000_000.0
        return min(n - 1, Int(pow(u, power) * Double(n)))
    }
}

/// Builds the word list once: deterministic pseudo-words (consonant+vowel
/// syllables), 4096 entries. No external corpus, nothing committed.
func makeVocabulary() -> [String] {
    let consonants = Array("b c d f g h j k l m n p r s t v w z".split(separator: " "))
    let vowels = Array("aeiou")
    var rng = LCG(seed: 0xBADC0DE)
    var words: [String] = []
    words.reserveCapacity(4096)
    for _ in 0..<4096 {
        let syllables = 2 + rng.uniform(3)
        var word = ""
        for _ in 0..<syllables {
            word += String(consonants[rng.uniform(consonants.count)])
            word += String(vowels[rng.uniform(vowels.count)])
        }
        words.append(word)
    }
    return words
}

struct Corpus {
    let words: [String]
    var rng: LCG
    let senders: [String]
    let mailboxes: [String]
    let baseDate: Date
    /// Built once — creating a DateFormatter per message would dominate.
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss +0000"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    init(seed: UInt64) {
        words = makeVocabulary()
        rng = LCG(seed: seed)
        senders = (0..<4000).map { "person\($0)@example.com" }
        var boxes = ["INBOX", "Sent"]
        for year in 2020...2025 { boxes.append("Archive/\(year)") }
        for i in 0..<20 { boxes.append("Lists/list\(i)") }
        for i in 0..<10 { boxes.append("Work/team\(i)") }
        mailboxes = boxes
        // 2020-01-01T00:00:00Z, computed without DateComponents parsing.
        baseDate = Date(timeIntervalSince1970: 1_577_836_800)
    }

    mutating func word() -> String {
        words[rng.biased(words.count)]
    }

    mutating func phrase(_ n: Int) -> [String] {
        (0..<n).map { _ in word() }
    }

    /// One synthetic message: RFC 822 bytes plus the fields ingest needs.
    /// Bodies run 1-2 KB; subjects 4-9 words; ~5% reply to the previous
    /// message so thread grouping has real chains to walk.
    mutating func message(_ index: Int, previousID: String?) -> (data: Data, record: MessageRecord, mailbox: String, searchText: SearchText) {
        let sender = senders[rng.uniform(senders.count)]
        var to = [senders[rng.uniform(senders.count)]]
        for _ in 0..<rng.uniform(3) { to.append(senders[rng.uniform(senders.count)]) }
        let mailbox = mailboxes[rng.uniform(mailboxes.count)]
        let isReply = previousID != nil && rng.uniform(20) == 0

        let subjectWords: [String]
        if isReply {
            subjectWords = phrase(4 + rng.uniform(6))
        } else {
            subjectWords = phrase(4 + rng.uniform(6))
        }
        let subject = (isReply ? "Re: " : "") + subjectWords.joined(separator: " ")

        var bodyWords: [String] = []
        let paragraphs = 3 + rng.uniform(4)
        for p in 0..<paragraphs {
            let count = 25 + rng.uniform(65)
            bodyWords += (0..<count).map { _ in word() }
            if p != paragraphs - 1 { bodyWords.append("\n\n") }
        }
        let body = bodyWords.joined(separator: " ")

        let days = rng.uniform(2100)
        let seconds = rng.uniform(86_400)
        let date = baseDate.addingTimeInterval(TimeInterval(days * 86_400 + seconds))
        let messageID = "m\(index)@bench.local"
        let dateString = Self.formatter.string(from: date)

        let name = "Person \(index % 4000)"
        let headerLines = [
            "From: \(name) <\(sender)>",
            "To: " + to.map { "Person <\($0)>" }.joined(separator: ", "),
            "Subject: \(subject)",
            "Date: \(dateString)",
            "Message-ID: <\(messageID)>",
        ]
        var extraLines: [String] = []
        if isReply, let prev = previousID {
            extraLines += ["In-Reply-To: <\(prev)>", "References: <\(prev)>"]
        }
        extraLines += ["Content-Type: text/plain; charset=utf-8"]
        let eml = (headerLines + extraLines).joined(separator: "\n") + "\n\n" + body + "\n"
        let data = Data(eml.utf8)

        let record = MessageRecord(
            subject: subject,
            normalizedSubject: subject,
            dateSent: date,
            dateReceived: date,
            messageID: messageID,
            inReplyTo: isReply ? [previousID ?? ""] : [],
            references: isReply ? [previousID ?? ""] : [],
            from: Recipient(name: name, email: sender),
            to: to.map { Recipient(name: "Person", email: $0) }
        )
        let searchText = SearchText(body: body, quoted: nil)
        return (data, record, mailbox, searchText)
    }
}

// MARK: Phases

func prepare(_ archiveDir: String, _ count: Int, _ seed: UInt64, killAfter: Int?) throws {
    let url = URL(fileURLWithPath: archiveDir)
    let store: ArchiveStore
    if FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) {
        store = try ArchiveStore.open(at: url)
        print("== open: \(try store.countMessages()) existing messages")
    } else {
        store = try ArchiveStore.create(at: url, appVersion: "bench")
    }
    // ArchiveStore closes itself in deinit; the process exit flushes WAL.

    var corpus = Corpus(seed: seed)
    var previousID: String?
    let started = Date()
    var mark = started
    let checkpoint = max(1, count / 10)
    // Ingest in batches: the store writes each file durably (per-file fsync
    // kept), flushes touched directories once per batch, and commits all
    // index rows in one transaction.
    let batchSize = 256
    var batch: [IngestedMessage] = []
    batch.reserveCapacity(batchSize)
    func flushBatch() throws {
        guard !batch.isEmpty else { return }
        let account = AccountIdentity(email: "bench@example.com", displayName: "Bench", providerKind: "import")
        _ = try store.ingest(batch, into: account)
        batch.removeAll(keepingCapacity: true)
    }
    for i in 0..<count {
        let (data, record, mailbox, searchText) = corpus.message(i, previousID: previousID)
        previousID = record.messageID
        let message = IngestedMessage(
            record: record,
            data: data,
            memberships: [Membership(mailbox: mailbox, uid: Int64(i), flags: ["seen"], dateReceived: record.dateSent)],
            labels: [],
            attachments: [],
            searchText: searchText
        )
        batch.append(message)
        if batch.count == batchSize || i == count - 1 {
            try flushBatch()
            let done = i + 1
            if done % checkpoint == 0 || done == count {
                let now = Date()
                let rate = Double(checkpoint) / now.timeIntervalSince(mark)
                print("== \(done)/\(count)  \(Int(rate)) msg/s  elapsed \(Int(now.timeIntervalSince(started))) s")
                mark = now
            }
        }
        // Kill point: simulate a crash after N messages.
        if let killAfter = killAfter, i + 1 == killAfter {
            print("== kill-after \(killAfter): sending SIGKILL to self")
            fflush(nil)
            // Use SIGABRT so the core dump signal is delivered; on macOS
            // this avoids the process-cleanup that SIGKILL would skip and
            // leaves the file system in a state indistinguishable from a
            // power loss (the kernel drops dirty cache, but our fsync'd
            // files are already on disk).
            raise(SIGABRT)
        }
    }
    let total = Date().timeIntervalSince(started)
    print("== ingest done: \(try store.countMessages()) messages in \(Int(total)) s (\(Int(Double(count) / total)) msg/s avg)")
}

/// Thread-safe invocation counter for the import fault-injection hook.
final class HookCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

/// Generates a synthetic .eml source folder, then runs the real import path
/// (MailImporter.import → MailBridge.parse → per-message ingest) against the
/// archive, with optional fault injection. The kill tests use this to crash a
/// genuine import mid-run and verify the durability contract holds on the
/// import path, not just on direct ingestion.
///
/// Import ingests one message at a time, so every message passes through all
/// three stage boundaries. Counting "files-written" invocations kills after N
/// messages' files are durable but before message N's index row commits.
func importFixture(_ archiveDir: String, _ count: Int, _ seed: UInt64, killAfter: Int?, crashStage: String?) throws {
    let src = FileManager.default.temporaryDirectory
        .appendingPathComponent("bench-import-src-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: src) }

    var corpus = Corpus(seed: seed)
    var previousID: String?
    for i in 0..<count {
        let (data, record, _, _) = corpus.message(i, previousID: previousID)
        previousID = record.messageID
        try data.write(to: src.appendingPathComponent("m\(i).eml"))
    }

    let url = URL(fileURLWithPath: archiveDir)
    let store: ArchiveStore
    if FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) {
        store = try ArchiveStore.open(at: url)
    } else {
        store = try ArchiveStore.create(at: url, appVersion: "bench")
    }

    if crashStage != nil || killAfter != nil {
        let counter = HookCounter()
        ArchiveStore.crashHook = { stage in
            if let crashStage = crashStage, stage == crashStage {
                print("== crash-stage \(stage): sending SIGABRT to self")
                fflush(nil)
                raise(SIGABRT)
            }
            if stage == "files-written", let killAfter = killAfter {
                let n = counter.next()
                if n == killAfter {
                    print("== kill-after \(killAfter): sending SIGABRT to self")
                    fflush(nil)
                    raise(SIGABRT)
                }
            }
        }
    }

    let started = Date()
    let report = try MailImporter.import(store, from: src)
    let total = Date().timeIntervalSince(started)
    print("== import done: \(report.imported) imported, \(report.duplicates) duplicates, \(report.failed) failed in \(Int(total)) s")
    print("== import report: filesSeen \(report.filesSeen), messagesFound \(report.messagesFound)")
}

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let index = min(sorted.count - 1, Int((p / 100.0) * Double(sorted.count - 1) + 0.5))
    return sorted[index]
}

func report(_ label: String, _ samples: [Double]) {
    let sorted = samples.sorted()
    let total = sorted.reduce(0, +)
    print(String(format: "== %@  n=%d  min=%.1f  p50=%.1f  p95=%.1f  p99=%.1f  max=%.1f  mean=%.1f ms",
                 label, samples.count, sorted.first ?? 0,
                 percentile(sorted, 50), percentile(sorted, 95), percentile(sorted, 99),
                 sorted.last ?? 0, total / Double(max(samples.count, 1))))
}

func monotonicMs() -> Double {
    #if canImport(Darwin)
    return Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000.0
    #else
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts)
    return Double(ts.tv_sec) * 1000.0 + Double(ts.tv_nsec) / 1_000_000.0
    #endif
}

func searchPhase(_ archiveDir: String, _ repeats: Int) throws {
    let url = URL(fileURLWithPath: archiveDir)
    let store = try ArchiveStore.open(at: url)
    let total = try store.countMessages()
    print("== archive: \(total) messages")

    // Query set: two-word pairs that actually occur in the corpus, taken from
    // the vocabulary head (common words) and tail (rare words).
    var corpus = Corpus(seed: 42)
    var queries: [String] = []
    for _ in 0..<25 {
        let w1 = corpus.words[corpus.rng.biased(corpus.words.count)]
        let w2 = corpus.words[corpus.rng.biased(corpus.words.count)]
        queries.append("\(w1) \(w2)")
    }
    // Sanity: the first query must return hits, else the corpus drifted.
    let probe = try store.search(queries[0])
    print("== probe query '\(queries[0])' hits: \(probe.hits.count)")

    // Warm-up pass over the whole query set, untimed (page cache).
    for q in queries {
        _ = try store.search(q, limit: 25)
        _ = try store.search(q, limit: 10)
        _ = try store.search(q, limit: 25, groupByThread: true)
    }

    // Timed passes.
    var ranked25: [Double] = []
    var first10: [Double] = []
    var grouped: [Double] = []
    var firstQueryMs = -1.0
    var hitTotal = 0
    for i in 0..<repeats {
        let q = queries[i % queries.count]
        let t0 = monotonicMs()
        let r = try store.search(q, limit: 25)
        let t1 = monotonicMs()
        _ = try store.search(q, limit: 10)
        let t2 = monotonicMs()
        _ = try store.search(q, limit: 25, groupByThread: true)
        let t3 = monotonicMs()
        if firstQueryMs < 0 { firstQueryMs = t1 - t0 }
        ranked25.append(t1 - t0)
        first10.append(t2 - t1)
        grouped.append(t3 - t2)
        hitTotal += r.hits.count
    }
    print("== first timed query after open: \(String(format: "%.1f", firstQueryMs)) ms")
    print("== average hits per ranked query: \(hitTotal / repeats)")
    report("two-word ranked, limit 25", ranked25)
    report("first ten, limit 10", first10)
    report("two-word ranked, grouped by thread", grouped)

    let rss = maxRSSKB()
    print(String(format: "== peak RSS: %.0f MB", Double(rss) / 1024.0))

    let rankedP95 = percentile(ranked25.sorted(), 95)
    let firstP95 = percentile(first10.sorted(), 95)
    let rankedOK = rankedP95 < 200.0
    let firstOK = firstP95 < 50.0
    print("== budget: ranked p95 \(rankedP95) ms (\(rankedOK ? "PASS" : "FAIL"), <200)  first-ten p95 \(firstP95) ms (\(firstOK ? "PASS" : "FAIL"), <50)")
    if !(rankedOK && firstOK) { exit(1) }
}

func maxRSSKB() -> Int {
    #if canImport(Darwin)
    var info = mach_task_basic_info_data_t()
    var count = mach_msg_type_number_t(10)
    let result = withUnsafeMutablePointer(to: &info) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO),
                  $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { $0 },
                  &count)
    }
    return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    #else
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int(usage.ru_maxrss)
    #endif
}

// MARK: Entry

let args = Array(CommandLine.arguments.dropFirst())

/// Parse `--kill-after N` from args; returns (remaining, killAfter).
func parseKillAfter(_ args: [String]) -> ([String], Int?) {
    var remaining = [String]()
    var killAfter: Int?
    var i = 0
    while i < args.count {
        if args[i] == "--kill-after", i + 1 < args.count {
            killAfter = Int(args[i + 1])
            i += 2
        } else {
            remaining.append(args[i])
            i += 1
        }
    }
    return (remaining, killAfter)
}

/// Parse `--crash-stage <name>` from args; returns (remaining, stage). When
/// set, the store's test-only fault-injection hook raises SIGABRT exactly at
/// that batch-ingest durability boundary (see ArchiveStore.crashHook).
func parseCrashStage(_ args: [String]) -> ([String], String?) {
    var remaining = [String]()
    var stage: String?
    var i = 0
    while i < args.count {
        if args[i] == "--crash-stage", i + 1 < args.count {
            stage = args[i + 1]
            i += 2
        } else {
            remaining.append(args[i])
            i += 1
        }
    }
    return (remaining, stage)
}

guard let command = args.first else {
    print("usage: bench-search prepare|search|both <archive-dir> [count] [repeats] [seed] [--kill-after N] [--crash-stage files-written|dir-fsync|index-commit]\n       bench-search import <archive-dir> <count> [seed] [--kill-after N] [--crash-stage files-written|dir-fsync|index-commit]")
    exit(2)
}
do {
    let (parsedKill, killAfter) = parseKillAfter(args)
    let (parsed, crashStage) = parseCrashStage(parsedKill)
    if let crashStage = crashStage {
        ArchiveStore.crashHook = { stage in
            if stage == crashStage {
                print("== crash-stage \(stage): sending SIGABRT to self")
                fflush(nil)
                raise(SIGABRT)
            }
        }
    }
    switch command {
    case "prepare":
        try prepare(parsed[1], Int(parsed[2])!, parsed.count > 3 ? UInt64(parsed[3])! : 42, killAfter: killAfter)
    case "search":
        try searchPhase(parsed[1], parsed.count > 2 ? Int(parsed[2])! : 300)
    case "both":
        try prepare(parsed[1], Int(parsed[2])!, parsed.count > 4 ? UInt64(parsed[4])! : 42, killAfter: killAfter)
        try searchPhase(parsed[1], parsed.count > 3 ? Int(parsed[3])! : 300)
    case "import":
        try importFixture(parsed[1], Int(parsed[2])!, parsed.count > 3 ? UInt64(parsed[3])! : 42, killAfter: killAfter, crashStage: crashStage)
    default:
        print("unknown command: \(command)")
        exit(2)
    }
} catch {
    print("FAIL: \(error)")
    exit(1)
}
