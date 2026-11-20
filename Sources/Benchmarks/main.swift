// bench-search: the M1/scale benchmark harness (ROADMAP M1 "Done when",
// docs/TESTING.md scale-benchmark section). Generates a deterministic
// synthetic corpus, ingests it through the real ArchiveStore ingest path,
// then times two-word ranked queries against the live FTS5 index.
//
// Usage:
//   bench-search prepare     <archive-dir> <count> [seed]
//   bench-search search      <archive-dir> [repeats]
//   bench-search both        <archive-dir> <count> [repeats]
//   bench-search as-you-type <archive-dir> [repeats]
//   bench-search vector-prepare <archive-dir> <count> [seed]
//   bench-search vector-search  <archive-dir> [repeats] [seed]
//   bench-search vector-prepare-real <archive-dir> <model-dir> [count] [seed]
//   bench-search vector-recall-real  <archive-dir> <model-dir> [queries] [seed]
//
// `prepare` resumes: already-present messages count as duplicates and cost
// only a hash lookup, so a killed run can be re-run with the same arguments.
// Search budget verified here (ROADMAP M1 / DESIGN 6A): a full ranked page
// (two-word query, limit 25) under 200 ms. The limit-10 pass is the same
// shape and is informational only.
//
// As-you-type budget (DESIGN 6A): first-keystroke results under 50 ms on a
// 1M-message archive. The phase measures 1-character (pure completion from
// the first-letter table), 2-character (pure completion from fts5vocab),
// and 4-character (gated ranked prefix search) prefixes, each cycling
// through 20 queries and repeating 300 times.

import ArchiveCore
import Foundation
import GRDB

#if canImport(Darwin)
import ArchiveEmbedApple
// SearchEval links Benchmarks on macOS only (see Package.swift): the
// judged-relevance phase and its CoreML-driven semantic slice live here.
import SearchEval
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
            print("== kill-after \(killAfter): sending SIGABRT to self")
            fflush(nil)
            // abort(), not raise(SIGABRT): the Swift Linux runtime installs a
            // one-shot SIGABRT handler (its crash backtracer) that returns,
            // leaving the process alive after the first raise. abort() is
            // guaranteed by POSIX to terminate: glibc resets the disposition,
            // unblocks the signal, and re-raises. Same signal, same default
            // core-dump action, indistinguishable from a power loss.
            abort()
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
                // abort(): see the comment at the prepare-path kill point.
                abort()
            }
            if stage == "files-written", let killAfter = killAfter {
                let n = counter.next()
                if n == killAfter {
                    print("== kill-after \(killAfter): sending SIGABRT to self")
                    fflush(nil)
                    abort()
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
    // The limit-10 pass is the same two-word ranked shape as limit 25 and
    // carries no separate budget (see the header comment): its p95 is
    // expected to track the ranked page and is printed for regression
    // visibility only. DESIGN 6A's 50 ms budget belongs to the as-you-type
    // prefix path, which does not exist yet (M2 work).
    print("== budget: ranked p95 \(rankedP95) ms (\(rankedOK ? "PASS" : "FAIL"), <200)  first-ten p95 \(firstP95) ms (informational, same shape as ranked)")
    if !rankedOK { exit(1) }
}

/// DESIGN 6A first-keystroke budget: results under 50 ms on a 1M-message
/// archive. Measures three shapes:
///   1-char — pure completion from the first-letter table (gate always
///           blocks ranked; the match set is huge).
///   2-char — pure completion from a live fts5vocab range (gate still
///           blocks on a 1M archive, but the path is different).
///   4-char — gated ranked prefix search (the prefix's match set is small
///            enough that the gate lets it through).
func asYouTypePhase(_ archiveDir: String, _ repeats: Int) throws {
    let url = URL(fileURLWithPath: archiveDir)
    let store = try ArchiveStore.open(at: url)
    let total = try store.countMessages()
    print("== archive: \(total) messages")

    // The import path rebuilds the first-letter table at the end of the
    // import (decision 0025); do the same here so that any archive —
    // including ones prepared before core-v7 — can serve 1-character
    // completions.
    try store.refreshAsYouTypeVocabulary()

    // Build three deterministic query sets from the corpus vocabulary.
    let words = makeVocabulary()
    // 1-char: first-letter of the first 20 vocabulary words (head → common).
    var oneChar: [String] = []
    for i in 0..<20 {
        let c = String(words[i].prefix(1))
        if !oneChar.contains(c) { oneChar.append(c) }
    }
    // 2-char: first two letters of the first 20 vocabulary words.
    var twoChar: [String] = []
    for i in 0..<20 {
        let p = String(words[i].prefix(2))
        if !twoChar.contains(p) { twoChar.append(p) }
    }
    // 4-char: first four letters of the last 20 vocabulary words (tail → rare).
    var fourChar: [String] = []
    for i in (words.count - 20)..<words.count {
        let p = String(words[i].prefix(4))
        if !fourChar.contains(p) { fourChar.append(p) }
    }

    // Warm-up pass: one timed call per query to prime caches.
    for q in oneChar + twoChar + fourChar {
        _ = try store.searchAsYouType(q)
    }

    // Timed passes.
    var oneCharMs: [Double] = []
    var oneCharCompletions = 0
    var oneCharRanked = 0
    var twoCharMs: [Double] = []
    var twoCharCompletions = 0
    var twoCharRanked = 0
    var fourCharMs: [Double] = []
    var fourCharCompletions = 0
    var fourCharRanked = 0

    for i in 0..<repeats {
        let q1 = oneChar[i % oneChar.count]
        let t1a = monotonicMs()
        let r1 = try store.searchAsYouType(q1)
        let t1b = monotonicMs()
        oneCharMs.append(t1b - t1a)
        oneCharCompletions += r1.completions.count
        if !r1.ranked.isEmpty { oneCharRanked += 1 }

        let q2 = twoChar[i % twoChar.count]
        let t2a = monotonicMs()
        let r2 = try store.searchAsYouType(q2)
        let t2b = monotonicMs()
        twoCharMs.append(t2b - t2a)
        twoCharCompletions += r2.completions.count
        if !r2.ranked.isEmpty { twoCharRanked += 1 }

        let q4 = fourChar[i % fourChar.count]
        let t4a = monotonicMs()
        let r4 = try store.searchAsYouType(q4)
        let t4b = monotonicMs()
        fourCharMs.append(t4b - t4a)
        fourCharCompletions += r4.completions.count
        if !r4.ranked.isEmpty { fourCharRanked += 1 }
    }

    let oneP95 = percentile(oneCharMs.sorted(), 95)
    let twoP95 = percentile(twoCharMs.sorted(), 95)
    let fourP95 = percentile(fourCharMs.sorted(), 95)

    report("1-char completion (first keystroke)", oneCharMs)
    report("2-char completion (vocabulary table)", twoCharMs)
    report("4-char prefix (gated ranked)", fourCharMs)

    print(String(format: "1-char: %d completions total, %d gate-passed (ranked)", oneCharCompletions, oneCharRanked))
    print(String(format: "2-char: %d completions total, %d gate-passed (ranked)", twoCharCompletions, twoCharRanked))
    print(String(format: "4-char: %d completions total, %d gate-passed (ranked)", fourCharCompletions, fourCharRanked))

    // DESIGN 6A: completion keystrokes are first-keystroke queries (50 ms);
    // a gated 4-char prefix that returns a ranked page is a ranked query
    // (200 ms). The phase is informational only: it fails the run only when
    // a documented budget is missed.
    let keyBudget = 50.0
    let rankedBudget = 200.0
    let oneOK = oneP95 < keyBudget
    let twoOK = twoP95 < keyBudget
    let fourOK = fourP95 < rankedBudget
    print("== budget: 1-char p95 \(String(format: "%.1f", oneP95)) ms (\(oneOK ? "PASS" : "FAIL"), <\(keyBudget))  2-char p95 \(String(format: "%.1f", twoP95)) ms (\(twoOK ? "PASS" : "FAIL"), <\(keyBudget))  4-char p95 \(String(format: "%.1f", fourP95)) ms (\(fourOK ? "PASS" : "FAIL"), <\(rankedBudget))")
    if !oneOK || !twoOK || !fourOK { exit(1) }
}

func maxRSSKB() -> Int {
    #if canImport(Darwin)
    // task_vm_info rather than MACH_TASK_BASIC_INFO: the latter's task_info
    // call returns KERN_INVALID_ARGUMENT here (harness printed "0 MB" since
    // it was introduced), while task_vm_info reports resident_size reliably.
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO),
                  $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { $0 },
                  &count)
    }
    return result == KERN_SUCCESS ? Int(info.resident_size / 1024) : 0
    #else
    var usage = rusage()
    // Linux: RUSAGE_SELF is a __rusage_who enum; the C function wants Int32.
    #if os(Linux)
    getrusage(__rusage_who_t(RUSAGE_SELF.rawValue), &usage)
    #else
    getrusage(RUSAGE_SELF, &usage)
    #endif
    return Int(usage.ru_maxrss)
    #endif
}

// MARK: Semantic scale benchmark (decision 0045 scale-measurement slice)

/// DESIGN 6A semantic budget: a semantic query at one million messages must
/// finish in under 300 ms. The archive here holds one float16 embedding per
/// message at the real model's dimension (384). Rows go straight into
/// `message` + `message_embedding` — the phase measures the scan, not ingest.
///
///   bench-search vector-prepare <archive-dir> <count> [seed]
///   bench-search vector-search  <archive-dir> [repeats] [seed]
///
/// Vectors are deterministic: rows get uniform [-1, 1) draws from a seeded
/// xorshift, and the row nearest `count/2` stores 0.7 × query0, so the probe
/// query must return exactly that row at rank 1. A broken scan (wrong math,
/// wrong layout) fails the sanity check instead of passing a meaningless
/// timing. `vector-search` must use the same seed as `vector-prepare` to
/// rebuild query0.

struct VectorRNG {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    /// Uniform in [-1, 1).
    mutating func unit() -> Float {
        var value = Float(bitPattern: 0x3F80_0000 | UInt32(truncatingIfNeeded: next() & 0x007F_FFFF)) - 1.0
        if next() & 1 == 1 { value = -value }
        return value
    }
    mutating func vector(_ dim: Int) -> [Float] {
        var v = [Float]()
        v.reserveCapacity(dim)
        for _ in 0..<dim { v.append(unit()) }
        return v
    }
}

let vectorDim = 384
let vectorModel = "bench-vector"

func vectorHash(_ i: Int64) -> Data {
    var bytes = [UInt8](repeating: 0, count: 8)
    for k in 0..<8 { bytes[k] = UInt8(truncatingIfNeeded: i >> (8 * k)) }
    return Data(bytes)
}

func vectorPrepare(_ archiveDir: String, _ count: Int, _ seed: UInt64) throws {
    let store = try ArchiveStore.create(at: URL(fileURLWithPath: archiveDir), appVersion: "0.1.0")
    var rng = VectorRNG(seed: seed)
    let query0 = rng.vector(vectorDim)
    let specialRow = Int64(max(1, count / 2))
    let started = monotonicMs()
    var i: Int64 = 0
    let batch = 4096
    while i < count {
        try store.db.write { db in
            for _ in 0..<batch where i < count {
                i += 1
                let vector = (i == specialRow) ? query0.map { $0 * 0.7 } : rng.vector(vectorDim)
                let vectorBlob = VectorIndex.encode(vector)
                try db.execute(
                    sql: "INSERT INTO message (hash, size, subject) VALUES (?, ?, ?)",
                    arguments: [vectorHash(i), vectorBlob.count, "vec-\(i)"]
                )
                try db.execute(
                    sql: "INSERT INTO message_embedding (id, model, dim, vector) VALUES (?, ?, ?, ?)",
                    arguments: [db.lastInsertedRowID, vectorModel, vectorDim, vectorBlob]
                )
            }
        }
        if Int(i) / batch % 25 == 0 || i == count {
            let mark = monotonicMs()
            print(String(format: "== %lld rows (%.0f rows/s so far)", i, Double(i) * 1000.0 / max(mark - started, 1)))
            fflush(nil)
        }
    }
    let done = monotonicMs()
    print(String(format: "== inserted %d embeddings (dim %d) in %.1f s", count, vectorDim, (done - started) / 1000.0))
}

func vectorSearch(_ archiveDir: String, _ repeats: Int, _ seed: UInt64) throws {
    let store = try ArchiveStore.open(at: URL(fileURLWithPath: archiveDir))
    let stored = try store.db.read { db in
        try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM message_embedding WHERE model = ?", arguments: [vectorModel]
        ) ?? 0
    }
    print("== archive: \(stored) embeddings (dim \(vectorDim), model \(vectorModel))")
    guard stored > 0 else { print("FAIL: run vector-prepare first"); exit(1) }

    var rng = VectorRNG(seed: seed)
    let query0 = rng.vector(vectorDim)
    let specialRow = Int64(max(1, stored / 2))
    var queries: [[Float]] = [query0]
    for _ in 0..<24 { queries.append(rng.vector(vectorDim)) }

    // Sanity probe (its wall time doubles as the cold-ish first-scan mark):
    // the planted row must come back at rank 1 with cosine 1.0 (0.7 × 0.7
    // scales out of cosine).
    let probeStart = monotonicMs()
    let probe = try store.db.read { db in
        try VectorIndex.search(db, model: vectorModel, query: query0, limit: 5)
    }
    let probeMs = monotonicMs() - probeStart
    let probeOK = probe.first?.messageID == specialRow
    print(String(format: "== probe: rank1 id %lld (expected %lld), first-scan %.1f ms — %@",
                 probe.first?.messageID ?? -1, specialRow, probeMs, probeOK ? "PASS" : "FAIL"))
    guard probeOK else { exit(1) }

    // Warm-up, untimed.
    _ = try store.db.read { db in
        try VectorIndex.search(db, model: vectorModel, query: queries[7], limit: 20)
    }

    var samples: [Double] = []
    samples.reserveCapacity(repeats)
    var hitTotal = 0
    for r in 0..<repeats {
        let query = queries[r % queries.count]
        let t0 = monotonicMs()
        let hits = try store.db.read { db in
            try VectorIndex.search(db, model: vectorModel, query: query, limit: 20)
        }
        let t1 = monotonicMs()
        samples.append(t1 - t0)
        hitTotal += hits.count
    }
    print("== average hits per scan: \(hitTotal / max(repeats, 1))")
    print(String(format: "== peak RSS: %.0f MB", Double(maxRSSKB()) / 1024.0))
    report("semantic scan, dim \(vectorDim), limit 20", samples)

    let sorted = samples.sorted()
    let p95 = percentile(sorted, 95)
    let ok = p95 < 300.0
    print(String(format: "== budget: semantic scan p95 %.1f ms — %@ (<300)", p95, ok ? "PASS" : "FAIL"))
    if !ok { exit(1) }
}

/// Staged timing for the semantic scan (scale-slice diagnostics): the same
/// batched SELECT without scoring, then the full search, then a batch-size
/// sweep. The gap between the first two is decode + Accelerate math.
///
///   bench-search vector-profile <archive-dir> [seed]
///
func vectorProfile(_ archiveDir: String, _ seed: UInt64) throws {
    let store = try ArchiveStore.open(at: URL(fileURLWithPath: archiveDir))
    var rng = VectorRNG(seed: seed)
    let query = rng.vector(vectorDim)
    let stored = try store.db.read { db in
        try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM message_embedding WHERE model = ?", arguments: [vectorModel]
        ) ?? 0
    }
    print("== archive: \(stored) embeddings (dim \(vectorDim))")
    guard stored > 0 else { print("FAIL: run vector-prepare first"); exit(1) }

    var samples: [Double] = []
    for _ in 0..<3 {
        let a = monotonicMs()
        var lastID: Int64 = 0
        var seen = 0
        while true {
            let rows: [(id: Int64, blob: Data)] = try store.db.read { db in
                let fetched = try Row.fetchAll(
                    db,
                    sql: "SELECT id, vector FROM message_embedding WHERE model = ? AND id > ? ORDER BY id LIMIT ?",
                    arguments: [vectorModel, lastID, VectorIndex.scanBatchSize]
                )
                if fetched.isEmpty { return [] }
                lastID = fetched[fetched.count - 1]["id"]
                return fetched.map { (id: ($0["id"] as Int64), blob: ($0["vector"] as Data)) }
            }
            if rows.isEmpty { break }
            seen += rows.count
            for row in rows { _ = row.blob.count }
        }
        precondition(seen == stored, "fetch pass saw \(seen) of \(stored) rows")
        samples.append(monotonicMs() - a)
    }
    report("fetch only (batched SELECT + blob touch)", samples)

    samples.removeAll()
    for _ in 0..<3 {
        let a = monotonicMs()
        _ = try store.db.read { db in
            try VectorIndex.search(db, model: vectorModel, query: query, limit: 20)
        }
        samples.append(monotonicMs() - a)
    }
    report("full search (default batchSize \(VectorIndex.scanBatchSize))", samples)

    for size in [1024, 2048, 16384, 32768] {
        var one: [Double] = []
        for _ in 0..<2 {
            let a = monotonicMs()
            _ = try store.db.read { db in
                try VectorIndex.search(db, model: vectorModel, query: query, limit: 20, batchSize: size)
            }
            one.append(monotonicMs() - a)
        }
        report("full search, batchSize \(size)", one)
    }

    // Cursor fetch variant: stream rows instead of materializing them twice,
    // and read columns by index — the fetch shape the search now uses.
    var cursorSamples: [Double] = []
    for _ in 0..<3 {
        let a = monotonicMs()
        var lastID: Int64 = 0
        var seen = 0
        try store.db.read { db in
            while true {
                var batch: [(id: Int64, blob: Data)] = []
                batch.reserveCapacity(VectorIndex.scanBatchSize)
                let cursor = try Row.fetchCursor(
                    db,
                    sql: "SELECT id, vector FROM message_embedding WHERE model = ? AND id > ? ORDER BY id LIMIT ?",
                    arguments: [vectorModel, lastID, VectorIndex.scanBatchSize]
                )
                while let row = try cursor.next() {
                    batch.append((row[0], row[1]))
                }
                if batch.isEmpty { break }
                lastID = batch[batch.count - 1].id
                seen += batch.count
                for row in batch { _ = row.blob.count }
            }
        }
        precondition(seen == stored, "cursor fetch saw \(seen) of \(stored) rows")
        cursorSamples.append(monotonicMs() - a)
    }
    report("cursor fetch + index access (no mmap)", cursorSamples)

    // Same cursor fetch with a 1 GB mmap window on the reader connection.
    var mmapSamples: [Double] = []
    for _ in 0..<3 {
        let a = monotonicMs()
        var lastID: Int64 = 0
        var seen = 0
        try store.db.read { db in
            try db.execute(sql: "PRAGMA mmap_size = 1073741824")
            while true {
                var batch: [(id: Int64, blob: Data)] = []
                batch.reserveCapacity(VectorIndex.scanBatchSize)
                let cursor = try Row.fetchCursor(
                    db,
                    sql: "SELECT id, vector FROM message_embedding WHERE model = ? AND id > ? ORDER BY id LIMIT ?",
                    arguments: [vectorModel, lastID, VectorIndex.scanBatchSize]
                )
                while let row = try cursor.next() {
                    batch.append((row[0], row[1]))
                }
                if batch.isEmpty { break }
                lastID = batch[batch.count - 1].id
                seen += batch.count
                for row in batch { _ = row.blob.count }
            }
        }
        precondition(seen == stored, "mmap fetch saw \(seen) of \(stored) rows")
        mmapSamples.append(monotonicMs() - a)
    }
    report("cursor fetch + index access (mmap 1 GB)", mmapSamples)
    print(String(format: "== peak RSS: %.0f MB", Double(maxRSSKB()) / 1024.0))
}

/// Cluster the prepared vector archive and time the clustered scan
/// (decision 0046). Run after `vector-prepare`.
///
///   bench-search vector-cluster <archive-dir> [repeats] [seed]
///
/// Reports the cluster-build time, cluster sizes and assignment coverage,
/// then p50/p95/p99 of the clustered scan at the default nprobe against
/// the same 300 ms budget the exact scan is held to.
func vectorCluster(_ archiveDir: String, _ repeats: Int, _ seed: UInt64) throws {
    let store = try ArchiveStore.open(at: URL(fileURLWithPath: archiveDir))
    let stored = try store.db.read { db in
        try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM message_embedding WHERE model = ?", arguments: [vectorModel]
        ) ?? 0
    }
    print("== archive: \(stored) embeddings (dim \(vectorDim), model \(vectorModel))")
    guard stored > 0 else { print("FAIL: run vector-prepare first"); exit(1) }

    let t0 = monotonicMs()
    let clusterCount = try store.db.write { db in
        try VectorIndex.maybeCluster(db, model: vectorModel, seed: seed)
    }
    print(String(format: "== buildClusters: %d clusters in %.1f ms", clusterCount, monotonicMs() - t0))
    guard clusterCount > 0 else {
        print("FAIL: no clusters built (rows \(stored) below clusterMinRows \(VectorIndex.clusterMinRows)?)")
        exit(1)
    }
    let clusters = try store.db.read { db in try VectorIndex.clusters(db, model: vectorModel) }
    var sizes = clusters.map(\.count)
    sizes.sort()
    let covered = sizes.reduce(0, +)
    print("== coverage \(covered)/\(stored) rows; size min \(sizes.first ?? 0)" +
        " median \(sizes[sizes.count / 2]) max \(sizes.last ?? 0)")
    precondition(covered <= stored, "cluster counts exceed row count")

    var rng = VectorRNG(seed: seed)
    let query0 = rng.vector(vectorDim)
    let specialRow = Int64(max(1, stored / 2))
    var queries: [[Float]] = [query0]
    for _ in 0..<24 { queries.append(rng.vector(vectorDim)) }

    // Same sanity probe as the exact scan: the planted row at rank 1 with
    // cosine 1.0, now through the clustered path.
    let probeStart = monotonicMs()
    let probe = try store.db.read { db in
        try VectorIndex.search(db, model: vectorModel, query: query0, limit: 5)
    }
    let probeMs = monotonicMs() - probeStart
    let probeOK = probe.first?.messageID == specialRow
    print(String(format: "== probe: rank1 id %lld (expected %lld), first scan %.1f ms — %@",
                 probe.first?.messageID ?? -1, specialRow, probeMs, probeOK ? "PASS" : "FAIL"))
    guard probeOK else { exit(1) }

    _ = try store.db.read { db in
        try VectorIndex.search(db, model: vectorModel, query: queries[7], limit: 20)
    }

    var samples: [Double] = []
    samples.reserveCapacity(max(repeats, 1))
    var hitTotal = 0
    for r in 0..<repeats {
        let query = queries[r % queries.count]
        let a = monotonicMs()
        let hits = try store.db.read { db in
            try VectorIndex.search(db, model: vectorModel, query: query, limit: 20)
        }
        samples.append(monotonicMs() - a)
        hitTotal += hits.count
    }
    print("== average hits per scan: \(hitTotal / max(repeats, 1))")
    print(String(format: "== peak RSS: %.0f MB", Double(maxRSSKB()) / 1024.0))
    report("clustered scan, dim \(vectorDim), limit 20, nprobe \(VectorIndex.defaultProbeCount)", samples)

    let sorted = samples.sorted()
    let p95 = percentile(sorted, 95)
    let ok = p95 < 300.0
    print(String(format: "== budget: clustered scan p95 %.1f ms — %@ (<300)", p95, ok ? "PASS" : "FAIL"))
    if !ok { exit(1) }
}

/// Recall of the clustered scan against the exact scan (decision 0046).
///
///   bench-search vector-recall <archive-dir> [queries] [seed]
///
/// For each nprobe in a sweep, reports recall@limit — the fraction of the
/// exact scan's top-limit hits the clustered scan finds — plus p50/p95
/// latency. The exact baseline is `nprobe: nil`, the pre-0046 full scan.
func vectorRecall(_ archiveDir: String, _ queryCount: Int, _ seed: UInt64) throws {
    let store = try ArchiveStore.open(at: URL(fileURLWithPath: archiveDir))
    let stored = try store.db.read { db in
        try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM message_embedding WHERE model = ?", arguments: [vectorModel]
        ) ?? 0
    }
    print("== archive: \(stored) embeddings (dim \(vectorDim), model \(vectorModel))")
    guard stored > 0 else { print("FAIL: run vector-prepare first"); exit(1) }
    let clusters = try store.db.read { db in try VectorIndex.clusters(db, model: vectorModel) }
    guard !clusters.isEmpty else { print("FAIL: run vector-cluster first"); exit(1) }

    var rng = VectorRNG(seed: seed)
    var queries: [[Float]] = []
    for _ in 0..<max(queryCount, 1) { queries.append(rng.vector(vectorDim)) }
    try runRecallSweep(store, model: vectorModel, queries: queries, limit: 20)
}

/// Shared recall sweep (decision 0046): times the exact scan once as the
/// baseline, then each nprobe in the sweep, reporting recall@limit and
/// p50/p95/max latency per point. Both the random-vector sweep and the
/// real-text sweep run through this, so their numbers stay comparable.
func runRecallSweep(_ store: ArchiveStore, model: String, queries: [[Float]], limit: Int) throws {
    var exact: [[Int64]] = []
    var exactSamples: [Double] = []
    for query in queries {
        let a = monotonicMs()
        let hits = try store.db.read { db in
            try VectorIndex.search(db, model: model, query: query, limit: limit, nprobe: nil)
        }
        exactSamples.append(monotonicMs() - a)
        exact.append(hits.map(\.messageID))
    }
    let exactSorted = exactSamples.sorted()
    print(String(format: "== exact    : recall@%d 1.000  p50 %6.1f ms  p95 %6.1f ms  max %6.1f ms (baseline)",
                 limit, percentile(exactSorted, 50), percentile(exactSorted, 95),
                 exactSorted[exactSorted.count - 1]))

    let clusterCount = try store.db.read { db in try VectorIndex.clusters(db, model: model) }.count
    let sweep = [1, 2, 4, 8, 16, 32, 64].filter { $0 <= clusterCount }
    for nprobe in sweep {
        var recall = 0.0
        var samples: [Double] = []
        for (i, query) in queries.enumerated() {
            let a = monotonicMs()
            let hits = try store.db.read { db in
                try VectorIndex.search(db, model: model, query: query, limit: limit, nprobe: nprobe)
            }
            samples.append(monotonicMs() - a)
            let found = Set(hits.map(\.messageID))
            let want = Set(exact[i])
            recall += Double(want.intersection(found).count) / Double(max(want.count, 1))
        }
        recall /= Double(queries.count)
        let sorted = samples.sorted()
        print(String(format: "== nprobe %3d: recall@%d %.3f  p50 %6.1f ms  p95 %6.1f ms  max %6.1f ms",
                     nprobe, limit, recall, percentile(sorted, 50), percentile(sorted, 95),
                     sorted[sorted.count - 1]))
    }
    print(String(format: "== peak RSS: %.0f MB", Double(maxRSSKB()) / 1024.0))
}

// MARK: Real-text semantic measurement (decisions 0045/0046)
//
// The pseudo-word corpus in `Corpus` measures keyword search and the
// random-vector archives in the `vector-*` phases measure scale, but bge
// needs real natural language for meaningful embeddings. This section
// embeds a deterministic topic-clustered English corpus with the
// converted model (via the ArchiveEmbedApple adapter) and re-runs the
// nprobe recall sweep on those embeddings, where k-means structure comes
// from actual topic clusters instead of random noise.

/// Topic-clustered English text for the real-model measurements.
///
/// Deterministic: the same seed produces the same messages. No real
/// people, places, or companies — every proper noun here is invented.
struct RealTextCorpus {
    struct Topic {
        let subjects: [String]
        let sentences: [String]
    }

    /// (marker, options) pairs for slot substitution. Array, not
    /// dictionary, so resolution order — and therefore the generated
    /// corpus — is identical everywhere.
    static let fillers: [(String, [String])] = [
        ("N", ["3", "5", "8", "12", "17", "24", "31", "46", "58", "72", "89"]),
        ("W", ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]),
        ("M", ["January", "February", "March", "April", "May", "June", "September", "October", "November"]),
        ("T", ["9:30", "11:00", "1:15", "2:45", "4:00", "6:30"]),
        ("AMT", ["$18", "$35", "$65", "$120", "$240", "$480", "$1,150"]),
        ("C", ["Riverton", "Lakeview", "Stonebridge", "Foxglove", "Harbor Mill", "Cedar Run", "Ashfield"]),
        ("K", ["Cedar Run Labs", "Harbor Mill Studio", "Stonebridge Press", "Foxglove Design", "Riverton Works", "Ashfield Group"]),
    ]

    static let topics: [Topic] = [
        Topic(
            subjects: ["Heater still out after {N} days", "Repair visit moved to {W}", "Lease renewal terms for unit {N}"],
            sentences: [
                "The heater in unit {N} quit again and the rooms are cold by evening.",
                "The plumber said the part arrives {W} and the repair takes about {N} minutes.",
                "Our lease runs through {M} and the renewal still lists the old parking spot.",
                "Please send the repair confirmation so I can file it with the lease papers.",
                "The building manager promised a callback last {W} but nothing came through.",
                "If the heat is not fixed by {W} I want to know what the next step is.",
            ]),
        Topic(
            subjects: ["Release {N}.{N} blocked on the flaky login test", "Staging deploy moved to {W} {T}", "Rollback plan for the payments service"],
            sentences: [
                "The payments service failed the smoke test twice on staging overnight.",
                "We cut the release branch on {W} and the build went green after two retries.",
                "The flaky login test passed {N} times locally and failed twice in CI.",
                "Rollback is a single command but the database migration needs a manual step.",
                "Can we hold the config changes until the deploy finishes on {W}?",
                "I moved the demo to {T} so the new build has time to soak.",
            ]),
        Topic(
            subjects: ["Changing the return flight to {W}", "Hotel near the venue for {N} nights", "Trip to {C} confirmation"],
            sentences: [
                "The return flight lands at {T} and the seat map is open for changes.",
                "The hotel near the venue has rooms for {N} nights at {AMT} per night.",
                "I want to move the trip to {C} one week later if the fare holds.",
                "The confirmation email never arrived so the booking reference is missing.",
                "Parking at the airport is cheaper when booked {N} days ahead.",
                "Send the updated itinerary once the dates are locked.",
            ]),
        Topic(
            subjects: ["Table for {N} on {W} at {T}", "Reservation change for Friday", "Birthday dinner plans"],
            sentences: [
                "We need a table for {N} people at {T} on {W}.",
                "The quiet room in the back worked well for the last dinner.",
                "One guest is vegetarian so the menu needs a couple of meatless options.",
                "The reservation is under {K} and the count may grow by two.",
                "Can we move the booking {N} minutes later without losing the table?",
                "The parking behind the restaurant fills up after {T}.",
            ]),
        Topic(
            subjects: ["Permission slip for the {M} field trip", "Parent meeting on {W} at {T}", "School photo order deadline"],
            sentences: [
                "The field trip to the nature center happens on {W} and costs {AMT}.",
                "The parent meeting starts at {T} and runs about an hour.",
                "Photo orders close on {W} and the packet went home early in {M}.",
                "The bus returns to the school at {T} so pickup runs a little late.",
                "Please sign the slip and send it back by {W}.",
                "After-school club meets {N} more times before the break.",
            ]),
        Topic(
            subjects: ["Dentist appointment on {W} at {T}", "Prescription refill question", "Reschedule the annual checkup"],
            sentences: [
                "The dentist can see me at {T} on {W} instead of the original slot.",
                "The pharmacy needs {N} days to order the refill.",
                "The annual checkup moved to {M} because of a scheduling conflict.",
                "Bring the insurance card and the list of current prescriptions.",
                "The clinic calls the evening before to confirm each appointment.",
                "If the visit runs late I might miss the {T} pickup.",
            ]),
        Topic(
            subjects: ["Invoice {N} past due", "Payment received for order {N}", "Question about the {M} statement"],
            sentences: [
                "Invoice {N} for {AMT} is past due by {N} days.",
                "The payment posted on {W} and the balance is now zero.",
                "The {M} statement lists two charges that look duplicated.",
                "Purchase orders need an approval code before processing.",
                "Our accounting cutoff is {W} so anything later rolls to next month.",
                "Please confirm the billing address before the next cycle.",
            ]),
        Topic(
            subjects: ["Standup notes {W}", "Blockers before sprint planning", "Demo schedule for {W}"],
            sentences: [
                "Yesterday I finished the search pagination work and started the review fixes.",
                "The data refresh job is blocked on the staging credentials.",
                "Planning moves to {W} at {T} because two people are out.",
                "The demo covers the import flow and the new archive viewer.",
                "I can pair on the flaky test right after standup.",
                "Tickets for the next sprint are still unpointed.",
            ]),
        Topic(
            subjects: ["Review requested for the export fix", "Small PR for the index cleanup", "Follow-up on yesterday's review comments"],
            sentences: [
                "The export fix touches the writer path and the error mapping.",
                "I added a regression test that fails without the change.",
                "The index cleanup is {N} lines and mostly mechanical.",
                "Review comments from {W} are addressed except the concurrency question.",
                "The branch is green and ready for a second look.",
                "Can you re-review by {W} so it makes the release?",
            ]),
        Topic(
            subjects: ["Kitchen remodel quote for {C}", "Contractor visit on {W}", "Tile order delay"],
            sentences: [
                "The kitchen remodel quote came in at {AMT} including permits.",
                "The contractor can start on {W} and estimates {N} working days.",
                "The tile order slipped a week and the backsplash is now the bottleneck.",
                "We need a decision on the cabinet handles before the install.",
                "Dust barriers go up on {W} so plan around the noise.",
                "The final walkthrough is scheduled for {T} on {W}.",
            ]),
        Topic(
            subjects: ["Brake noise getting worse", "Oil change reminder", "Tire rotation before the {M} trip"],
            sentences: [
                "The car makes a grinding noise when braking below {N} mph.",
                "The service shop has an opening on {W} at {T}.",
                "An oil change and a tire rotation cost {AMT} together.",
                "The loaner car needs a reservation {N} days ahead.",
                "The brakes were replaced {N} months ago so this is under warranty.",
                "Drop it off before {T} and pick it up after work.",
            ]),
        Topic(
            subjects: ["Gym schedule change for {W}", "Swim lane reservation", "Training plan for the {M} 10k"],
            sentences: [
                "The morning classes move to {T} starting {W}.",
                "I reserved a swim lane for {N} days at {T}.",
                "The 10k plan adds one long run each {W}.",
                "The pool closes early on {W} for maintenance.",
                "Coaching sessions cost {AMT} per month.",
                "Sign-ups for the race close at the end of {M}.",
            ]),
        Topic(
            subjects: ["Community garden work day", "Tomato seedlings ready for pickup", "Watering schedule for the raised beds"],
            sentences: [
                "The work day is on {W} starting at {T} by the tool shed.",
                "The tomato seedlings are ready and cost {AMT} a flat.",
                "The raised beds need watering every {N} days in {M}.",
                "The compost bin breaks down fastest when turned on {W}.",
                "Rabbits got into the lettuce row again this {W}.",
                "Bring gloves and a spade if you have them.",
            ]),
        Topic(
            subjects: ["Order {N} prints by {W}", "Portrait session reschedule", "Album proof ready"],
            sentences: [
                "The {N} prints order ships by {W} and costs {AMT}.",
                "The portrait session moved to {T} on {W}.",
                "The album proof is ready for review online.",
                "The studio recommends the matte finish for framing.",
                "Pickup is at the {C} location after {T}.",
                "The gallery link expires in {N} days.",
            ]),
        Topic(
            subjects: ["Talk slot for the {M} workshop", "Badge pickup hours", "Speaker dinner headcount"],
            sentences: [
                "My talk slot is {T} on {W} in the main hall.",
                "Badge pickup opens at {T} and closes an hour before the keynote.",
                "The speaker dinner headcount is due {W}.",
                "Travel costs are capped at {AMT} per speaker.",
                "The venue wifi dropped during the last rehearsal.",
                "Slides are due to the AV desk by {T}.",
            ]),
        Topic(
            subjects: ["Next meeting {W}: chapters {N}-{N}", "Hosting rotation for {M}", "Book pick poll results"],
            sentences: [
                "We meet at {T} on {W} and discuss chapters {N} through {N}.",
                "Hosting rotates in {M} and the {C} house has the next slot.",
                "The poll picked the river novel by {N} votes.",
                "Snacks rotate with the hosting, so bring something small.",
                "The library holds {N} copies under the club name.",
                "New members can join mid-book without any problem.",
            ]),
        Topic(
            subjects: ["Food drive shift on {W}", "Volunteer orientation for {C}", "Donation pickup route"],
            sentences: [
                "The food drive shift runs {T} to {T} on {W}.",
                "Orientation for new volunteers happens at the {C} branch.",
                "The pickup route covers {N} stops and takes about two hours.",
                "Donations are up {N} percent over last {M}.",
                "Wear closed shoes and bring a water bottle.",
                "Reply by {W} if you can cover an extra shift.",
            ]),
        Topic(
            subjects: ["Claim {N} paperwork checklist", "Policy renewal in {M}", "Deductible question for the roof claim"],
            sentences: [
                "Claim {N} needs the photos and the repair estimate attached.",
                "The policy renews in {M} and the premium goes up {AMT}.",
                "The roof claim deductible is {AMT} this year.",
                "The adjuster visits on {W} between {T} and {T}.",
                "Send the signed form back within {N} days.",
                "Keep the receipts until the claim closes.",
            ]),
        Topic(
            subjects: ["Dinner plan for {W}", "Slow cooker chili recipe", "Grocery list for the week"],
            sentences: [
                "For {W} dinner I plan a slow cooker chili with beans.",
                "The recipe needs {N} minutes of prep and {N} hours on low.",
                "The grocery list covers produce for {N} meals.",
                "The farmers market on {C} street opens at {T}.",
                "Leftovers keep {N} days in the fridge.",
                "Double the batch and freeze half for later.",
            ]),
        Topic(
            subjects: ["Dog grooming on {W}", "Vet shot reminder for the cat", "Pet sitter for the {M} trip"],
            sentences: [
                "The grooming appointment is at {T} on {W}.",
                "The cat is due for shots in {M} and the clinic opens at {T}.",
                "The pet sitter charges {AMT} per visit for {N} visits.",
                "The dog pulls on the leash near the {C} park.",
                "Food delivery arrives every {N} weeks on {W}.",
                "Leave the carrier out the night before.",
            ]),
    ]

    var rng: LCG

    init(seed: UInt64) {
        rng = LCG(seed: seed)
    }

    /// Deterministic (subject, body) for the next corpus message.
    mutating func message() -> (subject: String, body: String) {
        let topic = RealTextCorpus.topics[rng.uniform(RealTextCorpus.topics.count)]
        let subject = resolve(topic.subjects[rng.uniform(topic.subjects.count)])
        var lines: [String] = []
        for _ in 0..<(3 + rng.uniform(2)) {
            lines.append(resolve(topic.sentences[rng.uniform(topic.sentences.count)]))
        }
        return (subject, lines.joined(separator: " "))
    }

    mutating func resolve(_ template: String) -> String {
        var out = template
        for (marker, options) in RealTextCorpus.fillers {
            let token = "{\(marker)}"
            guard out.contains(token) else { continue }
            let value = options[rng.uniform(options.count)]
            out = out.replacingOccurrences(of: token, with: value)
        }
        return out
    }
}

/// Held-out query phrasings for the real-text sweep: written as natural
/// questions about the corpus topics, worded differently from the corpus
/// templates, so recall measures semantic similarity rather than
/// template match.
let realQueries: [String] = [
    "Is there any update on the heating problem in my apartment?",
    "When will someone come to look at the broken radiator?",
    "Can we push the software launch to later in the week?",
    "Why does the login test keep failing on the build server?",
    "How do I change my flight to a later date?",
    "Looking for a quiet hotel near the convention center",
    "Book a table for six people on Friday evening",
    "What time does the parent teacher meeting start?",
    "I need to move my dentist appointment to next month",
    "Did the invoice from last month ever get paid?",
    "What is still open before sprint planning on Monday?",
    "Please review my pull request when you have a minute",
    "How long will the kitchen remodeling take?",
    "The car is making a strange noise when I brake",
    "Can I switch my gym membership to mornings?",
    "When is the community garden work day this month?",
    "Where can I pick up the printed photos I ordered?",
    "Who is giving the opening talk at the workshop?",
    "Which book are we reading for the next meeting?",
    "Can I still sign up to volunteer for the food drive?",
    "What papers do I need for the insurance claim?",
    "Suggestions for an easy dinner to cook tonight",
    "Who can watch the dog while we are away?",
    "What is the moving truck schedule for the end of the month?",
    "Has the new sofa been delivered yet?",
    "The internet has dropped out three times today",
    "Which documents should I keep for the tax return?",
    "Do I need to renew my parking permit this year?",
    "Is the pool open early on weekends now?",
    "Looking for the receipt for the desk chair I returned",
]

let realModelName = "bge-small-en-v1.5"

#if canImport(ArchiveEmbedApple)
import ArchiveEmbedApple

func loadRealModel(_ modelDir: String) -> CoreMLEmbedding {
    guard let model = CoreMLEmbedding.load(named: realModelName, in: [URL(fileURLWithPath: modelDir)]) else {
        print("FAIL: cannot load \(realModelName) from \(modelDir)")
        exit(1)
    }
    return model
}

///   bench-search vector-prepare-real <archive-dir> <model-dir> [count] [seed]
///
/// Builds a fresh embedding-only archive whose vectors are real-model
/// embeddings of the topic-clustered English corpus, so the recall sweep
/// runs on embeddings with actual semantic structure.
func vectorPrepareReal(_ archiveDir: String, _ modelDir: String, _ count: Int, _ seed: UInt64) throws {
    let model = loadRealModel(modelDir)
    let store = try ArchiveStore.create(at: URL(fileURLWithPath: archiveDir), appVersion: "0.1.0")
    var corpus = RealTextCorpus(seed: seed)
    let started = monotonicMs()
    func generateRows(_ n: Int) -> [(subject: String, text: String)] {
        var out: [(subject: String, text: String)] = []
        out.reserveCapacity(n)
        for _ in 0..<n {
            let m = corpus.message()
            out.append((m.subject, EmbeddingBackfill.documentText(subject: m.subject, body: m.body)))
        }
        return out
    }
    let rows = generateRows(count)
    let subjects = rows.map(\.subject)
    let texts = rows.map(\.text)
    print(String(format: "== generated %d texts in %.0f ms", count, monotonicMs() - started))
    fflush(nil)

    // Embed concurrently: each closure writes only its own row slots of
    // `vectors`, so the shared mutable array is never contended.
    let embedStarted = monotonicMs()
    nonisolated(unsafe) var vectors = [[Float]](repeating: [], count: count)
    let chunk = 32
    let chunks = max(1, (count + chunk - 1) / chunk)
    DispatchQueue.concurrentPerform(iterations: chunks) { c in
        let lo = c * chunk
        let hi = min(lo + chunk, count)
        for i in lo..<hi {
            vectors[i] = model.embed(texts[i]) ?? []
        }
    }
    let embedded = vectors.filter { $0.count == model.dimension }
    print(String(format: "== embedded %d/%d in %.1f s (dim %d)",
                 embedded.count, count, (monotonicMs() - embedStarted) / 1000.0, model.dimension))
    guard embedded.count == count else {
        print("FAIL: \(count - embedded.count) embeddings missing or wrong dimension")
        exit(1)
    }

    // Insert (message, message_embedding) pairs, batched like vectorPrepare.
    let insertStarted = monotonicMs()
    let batch = 4096
    let db = store.db
    let vectorModel = model.identifier
    let vectorDim = model.dimension
    var i = 0
    while i < count {
        try db.write { db in
            for _ in 0..<batch where i < count {
                let vector = vectors[i]
                let vectorBlob = VectorIndex.encode(vector)
                try db.execute(
                    sql: "INSERT INTO message (hash, size, subject) VALUES (?, ?, ?)",
                    arguments: [vectorHash(Int64(i)), vectorBlob.count, subjects[i]]
                )
                try db.execute(
                    sql: "INSERT INTO message_embedding (id, model, dim, vector) VALUES (?, ?, ?, ?)",
                    arguments: [db.lastInsertedRowID, vectorModel, vectorDim, vectorBlob]
                )
                i += 1
            }
        }
        if i / batch % 25 == 0 || i == count {
            let mark = monotonicMs()
            print(String(format: "== %lld rows (%.0f rows/s so far)", Int64(i), Double(i) * 1000.0 / max(mark - insertStarted, 1)))
            fflush(nil)
        }
    }
    let done = monotonicMs()
    print(String(format: "== inserted %d real-model embeddings (dim %d, model %@) in %.1f s",
                 count, vectorDim, vectorModel, (done - insertStarted) / 1000.0))
}

///   bench-search vector-recall-real <archive-dir> <model-dir> [queries] [seed]
///
/// Clusters the real-model archive if needed, embeds held-out query
/// phrasings with the same model, and runs the shared nprobe recall
/// sweep — recall now measured on real natural-language embeddings.
func vectorRecallReal(_ archiveDir: String, _ modelDir: String, _ queryCount: Int, _ seed: UInt64) throws {
    let model = loadRealModel(modelDir)
    let store = try ArchiveStore.open(at: URL(fileURLWithPath: archiveDir))
    let stored = try store.db.read { db in
        try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM message_embedding WHERE model = ?", arguments: [model.identifier]
        ) ?? 0
    }
    print("== archive: \(stored) embeddings (dim \(model.dimension), model \(model.identifier))")
    guard stored > 0 else { print("FAIL: run vector-prepare-real first"); exit(1) }

    var clusters = try store.db.read { db in try VectorIndex.clusters(db, model: model.identifier) }
    if clusters.isEmpty {
        let t0 = monotonicMs()
        let clusterCount = try store.db.write { db in
            try VectorIndex.maybeCluster(db, model: model.identifier, seed: seed)
        }
        print(String(format: "== buildClusters: %d clusters in %.1f ms", clusterCount, monotonicMs() - t0))
        guard clusterCount > 0 else {
            print("FAIL: no clusters built (rows \(stored) below clusterMinRows \(VectorIndex.clusterMinRows)?)")
            exit(1)
        }
        clusters = try store.db.read { db in try VectorIndex.clusters(db, model: model.identifier) }
    }
    var sizes = clusters.map(\.count)
    sizes.sort()
    let covered = sizes.reduce(0, +)
    print("== coverage \(covered)/\(stored) rows; size min \(sizes.first ?? 0)" +
        " median \(sizes[sizes.count / 2]) max \(sizes.last ?? 0)")
    precondition(covered <= stored, "cluster counts exceed row count")

    let n = max(min(queryCount, realQueries.count), 1)
    let queries = realQueries.prefix(n).map { q -> [Float] in
        guard let v = model.embed(q), v.count == model.dimension else {
            print("FAIL: query embedding failed for \(q)")
            exit(1)
        }
        return v
    }
    try runRecallSweep(store, model: model.identifier, queries: queries, limit: 20)
}

///   bench-search relevance [model-dir]
///
/// Runs the full RelevanceRunner on the judged corpus (~150 messages).
/// With no model-dir: keyword-only gate (decision 0047).
/// With model-dir: hybrid search — keyword gate + semantic slice.
/// Loads the real model (bge-small-en-v1.5) or falls back to the toy model.
func relevancePhase(_ modelDir: String?) throws {
    var semanticModel: (any EmbeddingModel)?
    if let modelDir = modelDir {
        let dir = URL(fileURLWithPath: modelDir)
        // Try the real model first; it exits on failure, so probe for its
        // package first and fall back to the toy model when absent.
        let realModelDir = dir.appendingPathComponent(realModelName)
        if FileManager.default.fileExists(atPath: realModelDir.path) {
            semanticModel = loadRealModel(modelDir)
            print("== relevance with semantic model: \(semanticModel!.identifier)")
        } else {
            let toyModelURL = dir.appendingPathComponent("toy_embedding.mlmodel")
            let toyVocabURL = dir.appendingPathComponent("toy_vocab.txt")
            guard FileManager.default.fileExists(atPath: toyModelURL.path),
                  FileManager.default.fileExists(atPath: toyVocabURL.path) else {
                print("FAIL: no \(realModelName) package or toy model in \(modelDir)")
                exit(2)
            }
            let vocabText = try String(contentsOf: toyVocabURL, encoding: .utf8)
            semanticModel = try CoreMLEmbedding(modelAt: toyModelURL, vocabulary: vocabText)
            print("== relevance with toy semantic model")
        }
    } else {
        semanticModel = nil
        print("== relevance keyword-only gate (no model)")
    }

    let run = try RelevanceRunner.run(appVersion: "0.0.0-eval", semanticModel: semanticModel)
    print(String(format: "gate: nDCG@10=%.4f recall@50=%.4f topRank=%.1f queries=%d",
                 run.meanNDCG10, run.meanRecall50, run.meanTopRank,
                 run.scores.count))
    for slice in run.slices {
        print(String(format: "slice %@: nDCG@10=%.4f recall@50=%.4f topRank=%.1f queries=%d",
                     slice.capability as NSString, slice.meanNDCG10, slice.meanRecall50, slice.meanTopRank,
                     slice.scores.count))
    }
}
#else
func vectorPrepareReal(_ archiveDir: String, _ modelDir: String, _ count: Int, _ seed: UInt64) throws {
    print("FAIL: vector-prepare-real requires macOS (ArchiveEmbedApple)")
    exit(2)
}

func vectorRecallReal(_ archiveDir: String, _ modelDir: String, _ queryCount: Int, _ seed: UInt64) throws {
    print("FAIL: vector-recall-real requires macOS (ArchiveEmbedApple)")
    exit(2)
}

func relevancePhase(_ modelDir: String?) throws {
    print("FAIL: relevance requires macOS (SearchEval + ArchiveEmbedApple)")
    exit(2)
}
#endif

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
    print("usage: bench-search prepare|search|both|as-you-type <archive-dir> [count] [repeats] [seed] [--kill-after N] [--crash-stage files-written|dir-fsync|index-commit]\n       bench-search import <archive-dir> <count> [seed] [--kill-after N] [--crash-stage files-written|dir-fsync|index-commit]\n       bench-search vector-prepare <archive-dir> <count> [seed]\n       bench-search vector-search <archive-dir> [repeats] [seed]  (same seed as vector-prepare)\n       bench-search vector-cluster <archive-dir> [repeats] [seed]  (after vector-prepare; decision 0046)\n       bench-search vector-recall <archive-dir> [queries] [seed]  (after vector-cluster; decision 0046)\n       bench-search vector-prepare-real <archive-dir> <model-dir> [count] [seed]  (real-model embeddings, macOS only)\n       bench-search vector-recall-real <archive-dir> <model-dir> [queries] [seed]  (real-model recall; decision 0046)")
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
                // abort(): see the comment at the prepare-path kill point.
                abort()
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
    case "as-you-type":
        try asYouTypePhase(parsed[1], parsed.count > 2 ? Int(parsed[2])! : 300)
    case "vector-prepare":
        try vectorPrepare(parsed[1], Int(parsed[2])!, parsed.count > 3 ? UInt64(parsed[3])! : 42)
    case "vector-search":
        try vectorSearch(parsed[1], parsed.count > 2 ? Int(parsed[2])! : 20, parsed.count > 3 ? UInt64(parsed[3])! : 42)
    case "vector-profile":
        try vectorProfile(parsed[1], parsed.count > 2 ? UInt64(parsed[2])! : 42)
    case "vector-cluster":
        try vectorCluster(parsed[1], parsed.count > 2 ? Int(parsed[2])! : 20, parsed.count > 3 ? UInt64(parsed[3])! : 42)
    case "vector-recall":
        try vectorRecall(parsed[1], parsed.count > 2 ? Int(parsed[2])! : 10, parsed.count > 3 ? UInt64(parsed[3])! : 42)
    case "vector-prepare-real":
        try vectorPrepareReal(parsed[1], parsed[2], parsed.count > 3 ? Int(parsed[3])! : 10000,
                              parsed.count > 4 ? UInt64(parsed[4])! : 42)
    case "vector-recall-real":
        try vectorRecallReal(parsed[1], parsed[2], parsed.count > 3 ? Int(parsed[3])! : 30,
                             parsed.count > 4 ? UInt64(parsed[4])! : 42)
    case "relevance":
        try relevancePhase(parsed.count > 1 ? parsed[1] : nil)
    default:
        print("unknown command: \(command)")
        exit(2)
    }
} catch {
    print("FAIL: \(error)")
    exit(1)
}
