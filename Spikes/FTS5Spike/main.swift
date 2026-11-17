import Foundation
import NaturalLanguage
import SQLite3

// M0 spike: FTS5 with our own Swift tokenizer pipeline (decision 0007).
//
// Answers three questions from ROADMAP M0:
//   1. NLTokenizer segmentation quality on Chinese, Japanese, Korean samples.
//   2. Trigram index size per 100,000 messages.
//   3. A baseline (nDCG@10, recall@50, query latency) to set the relevance
//      targets recorded in docs/TESTING.md.
//
// Usage: swift run FTS5Spike   (env: CORPUS_N, default 100000; QUERIES_N, default 200)
// Prints one PASS/FAIL/INFO line per step; exits 0 only if every step passed.

let env = ProcessInfo.processInfo.environment
setvbuf(stdout, nil, _IONBF, 0)
let corpusN = Int(env["CORPUS_N"] ?? "") ?? 100_000
let queriesN = Int(env["QUERIES_N"] ?? "") ?? 200

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed = 0

func report(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { passed += 1; print("PASS \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
    else { failed += 1; print("FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
}

func info(_ name: String, _ detail: String) {
    print("INFO \(name) — \(detail)")
}

// MARK: - Tokenizer pipeline (the design under test)

/// Case fold, NFKC, diacritic fold.
func fold(_ s: String) -> String {
    let nfkc = s.precomposedStringWithCompatibilityMapping
    return nfkc.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
}

/// Word tokens with NLTokenizer; segments CJK, Japanese, Thai where there
/// are no spaces. Falls back to whitespace splitting if no language is set.
func wordTokens(_ text: String, language: NLLanguage?) -> [String] {
    let tokenizer = NLTokenizer(unit: .word)
    if let language { tokenizer.setLanguage(language) }
    tokenizer.string = text
    var out: [String] = []
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
        out.append(String(text[range]))
        return true
    }
    if out.isEmpty {
        out = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
    return out
}

/// Detect the language of a piece of text.
func detect(_ text: String) -> NLLanguage? {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    return recognizer.dominantLanguage
}

/// The full pipeline for a field: detect language, segment, fold.
func pipelineTokens(_ text: String) -> [String] {
    let language = detect(text)
    return wordTokens(fold(text), language: language)
        .map { fold($0) }
        .filter { !$0.isEmpty }
}

// MARK: - CJK segmentation quality

struct CJKSample {
    let name: String
    let text: String
    let expectedWords: [String]
}

let cjkSamples: [CJKSample] = [
    CJKSample(
        name: "chinese",
        text: "我明天要去北京开会，请把发票发给我。",
        // 汉语 word segmentation hand-checked against common readings.
        expectedWords: ["我", "明天", "要", "去", "北京", "开会", "请", "把", "发票", "发", "给", "我"]
    ),
    CJKSample(
        name: "japanese",
        text: "明日の会議の資料を送ってください。",
        expectedWords: ["明日", "の", "会議", "の", "資料", "を", "送っ", "て", "ください"]
    ),
    CJKSample(
        name: "korean",
        text: "내일 회의 자료를 보내 주세요.",
        expectedWords: ["내일", "회의", "자료를", "보내", "주세요"]
    ),
]

func cjkQuality() -> Bool {
    var allOK = true
    for sample in cjkSamples {
        let tokens = pipelineTokens(sample.text)
        let tokenSet = Set(tokens)
        let found = sample.expectedWords.filter { tokenSet.contains($0) }
        let recall = Double(found.count) / Double(sample.expectedWords.count)
        let ok = recall >= 0.8
        allOK = allOK && ok
        report(
            "cjk-segmentation-\(sample.name)",
            ok,
            "recall=\(String(format: "%.2f", recall)) found=\(found.count)/\(sample.expectedWords.count) tokens=\(tokens.prefix(14).joined(separator: "/"))"
        )
    }
    return allOK
}

// MARK: - Synthetic corpus

struct Message {
    let subject: String
    let fromName: String
    let fromAddr: String
    let to: String
    let body: String
    let quoted: String
    let date: Double // unix time
}

// Deterministic pseudo-random generator so runs are comparable.
struct LCG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func pick<C: Collection>(_ c: C) -> C.Element { c[c.index(c.startIndex, offsetBy: below(c.count))] }
}

let givenNames = ["alice", "bob", "carol", "dave", "erin", "frank", "grace", "heidi", "ivan", "judy", "mei", "hiroshi", "soo-jin", "anna", "pierre", "klaus", "olga", "wei", "yuki", "maria"]
let surnames = ["smith", "jones", "garcia", "muller", "dupont", "tanaka", "kim", "ivanov", "chen", "rossi", "novak", "weber", "petrov", "sato", "lopez"]
let companies = ["acme-corp", "bluebird-labs", "cedar-and-sons", "delta-dental", "evergreen-supply", "foxglove-media", "granite-bank", "harbor-freight-co", "indigo-press", "juniper-health", "kestrel-aviation", "lumen-energy", "maple-couriers", "northwind-trading", "oakline-insurance"]
let domains = ["example.com", "example.org", "example.net", "mail.example.com"]
let subjectWords = ["invoice", "order", "confirmation", "meeting", "schedule", "report", "budget", "contract", "renewal", "payment", "receipt", "shipment", "delivery", "flight", "hotel", "reservation", "ticket", "statement", "summary", "reminder", "password", "reset", "account", "policy", "claim", "estimate", "quote", "project", "update", "review"]
let bodyWords = subjectWords + ["attached", "please", "find", "kindly", "regards", "thanks", "advance", "regards,", "hello", "dear", "team", "colleagues", "follow", "up", "regarding", "per", "our", "discussion", "attached,", "copies", "cc'd", "forwarded", "approved", "denied", "pending", "completed", "processing", "shipped", "refunded", "overdue", "due", "friday", "monday", "monthly", "quarterly", "annual"]
let amounts = ["€42.50", "$1,250.00", "$89.99", "€1,000", "$340.15", "¥12,800", "£75.20", "$9.99"]

let chineseBodies = [
    "您的订单已经发货，发票将在月底前寄出。请查收附件中的收据。",
    "下周一的会议改到下午三点，请确认是否能参加。会议资料随后发出。",
    "本月账单金额为一千二百五十元，如需发票请在周五前回复。",
    "我们已收到您的付款，收据见附件。谢谢您的支持。",
]
let japaneseBodies = [
    "来週の打ち合わせの資料を添付します。ご確認ください。",
    "請求書を送ります。お支払い期限は月末です。",
    "会議は午後三時から始まります。資料は後ほどお送りします。",
]
let koreanBodies = [
    "첨부된 송장을 확인해 주세요. 이번 달 말까지 결제가 필요합니다.",
    "다음 주 회의 자료를 보내 드립니다. 확인 후 회신 부탁드립니다.",
    "결제가 완료되었습니다. 영수증을 첨부합니다.",
]

func makeCorpus(_ n: Int, rng: inout LCG) -> (messages: [Message], termPostings: [String: [Int]], addrPostings: [String: [Int]], companyPostings: [String: [Int]]) {
    var messages: [Message] = []
    messages.reserveCapacity(n)
    var termPostings: [String: [Int]] = [:]     // distinctive subject word -> message indexes
    var addrPostings: [String: [Int]] = [:]     // full sender address -> indexes
    var companyPostings: [String: [Int]] = [:]  // company token -> indexes
    let now: Double = 1_800_000_000
    for i in 0..<n {
        let company = rng.pick(companies)
        let person = "\(rng.pick(givenNames)).\(rng.pick(surnames))@\(rng.pick(domains))"
        let w1 = rng.pick(subjectWords)
        let w2 = rng.pick(subjectWords)
        let subject = "\(w1) \(w2) — \(company) #\(rng.below(100_000))"
        var from: String
        var fromName: String
        if rng.below(10) == 0 {
            // Some senders belong to a company identity, useful for company queries.
            from = "billing@\(company).example.com"
            fromName = "\(company) billing"
        } else {
            from = person
            fromName = "\(rng.pick(givenNames)) \(rng.pick(surnames))"
        }
        let to = "\(rng.pick(givenNames)).\(rng.pick(surnames))@\(rng.pick(domains))"
        var bodyWords_ = (0..<rng.below(40) + 40).map { _ in rng.pick(bodyWords) }
        bodyWords_.append(rng.pick(amounts))
        var body = bodyWords_.joined(separator: " ")
        var quoted = ""
        let langRoll = rng.below(100)
        var bodyText = body
        var subjectText = subject
        switch langRoll {
        case 0..<6:
            bodyText = rng.pick(chineseBodies)
            subjectText = "订单确认 — \(company)"
        case 6..<11:
            bodyText = rng.pick(japaneseBodies)
            subjectText = "請求書 — \(company)"
        case 11..<15:
            bodyText = rng.pick(koreanBodies)
            subjectText = "송장 확인 — \(company)"
        default:
            break
        }
        if rng.below(3) == 0 {
            quoted = "> \(bodyWords_.prefix(10).joined(separator: " "))"
        }
        body = bodyText
        let date = now - Double(rng.below(3 * 365 * 24 * 3600))
        messages.append(Message(
            subject: subjectText, fromName: fromName, fromAddr: from, to: to,
            body: body, quoted: quoted, date: date
        ))
        // Postings for the judged queries.
        addrPostings[from, default: []].append(i)
        companyPostings[company, default: []].append(i)
        for w in [w1, w2] where w.count >= 5 {
            termPostings[w, default: []].append(i)
        }
    }
    return (messages, termPostings, addrPostings, companyPostings)
}

// MARK: - SQLite

nonisolated(unsafe) let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

nonisolated(unsafe) var db: OpaquePointer?
func sqliteOpen() -> Bool {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("fts5spike-\(corpusN).sqlite").path
    try? FileManager.default.removeItem(atPath: path)
    try? FileManager.default.removeItem(atPath: path + "-wal")
    try? FileManager.default.removeItem(atPath: path + "-shm")
    return sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK
}
func exec(_ sql: String) -> Bool {
    sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
}
func prepare(_ sql: String) -> OpaquePointer? {
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
    return stmt
}

// MARK: - Spike steps

let corpusStart = Date()
var rng = LCG(state: 0x9E3779B97F4A7C15)
let corpus = makeCorpus(corpusN, rng: &rng)
let genSeconds = Date().timeIntervalSince(corpusStart)
info("corpus", "\(corpusN) messages generated in \(String(format: "%.1f", genSeconds))s")

guard sqliteOpen() else {
    report("sqlite-open", false, "cannot open temp database")
    print("FTS5Spike: \(passed) passed, \(failed) failed")
    exit(1)
}
defer { sqlite3_close(db) }

var fts5Available = false
if let stmt = prepare("SELECT sqlite_compileoption_used('ENABLE_FTS5')") {
    if sqlite3_step(stmt) == SQLITE_ROW {
        fts5Available = sqlite3_column_int(stmt, 0) == 1
    }
    sqlite3_finalize(stmt)
}
report("fts5-available", fts5Available)

_ = exec("PRAGMA journal_mode=WAL")
_ = exec("PRAGMA synchronous=OFF")

// CJK segmentation quality first: it decides the pipeline before any bulk run.
_ = cjkQuality()

// Table 1: the product index. Text arrives pre-tokenized from Swift, so
// unicode61 only has to split on the spaces we inserted.
let created = exec("""
CREATE VIRTUAL TABLE mail_fts USING fts5(
  subject, from_name, from_addr, body, quoted, msg_date UNINDEXED
)
""")
report("fts5-create", created)

let insertStart = Date()
let insertSQL = "INSERT INTO mail_fts(subject, from_name, from_addr, body, quoted, msg_date) VALUES(?,?,?,?,?,?);"
guard let insert = prepare(insertSQL) else {
    report("fts5-insert", false, "prepare failed")
    print("FTS5Spike: \(passed) passed, \(failed) failed")
    exit(1)
}
_ = exec("BEGIN")
for (i, m) in corpus.messages.enumerated() {
    let subjectTokens = pipelineTokens(m.subject).joined(separator: " ")
    let nameTokens = pipelineTokens(m.fromName).joined(separator: " ")
    // The address field is stored folded but raw: unicode61 splits it on
    // '@' and '.', which yields exactly the address-aware tokens DESIGN 6A
    // wants (jane, doe, jane.doe-as-phrase, example, example.com), and the
    // same rules apply to queries, so phrases line up.
    let addrTokens = fold(m.fromAddr)
    let bodyTokens = pipelineTokens(m.body).joined(separator: " ")
    let quotedTokens = pipelineTokens(m.quoted).joined(separator: " ")
    sqlite3_bind_text(insert, 1, subjectTokens, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(insert, 2, nameTokens, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(insert, 3, addrTokens, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(insert, 4, bodyTokens, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(insert, 5, quotedTokens, -1, SQLITE_TRANSIENT)
    sqlite3_bind_double(insert, 6, m.date)
    guard sqlite3_step(insert) == SQLITE_DONE else {
        report("fts5-insert", false, "step failed at \(i)")
        print("FTS5Spike: \(passed) passed, \(failed) failed")
        exit(1)
    }
    sqlite3_reset(insert)
    if i % 25_000 == 0 { _ = exec("COMMIT"); _ = exec("BEGIN") }
}
sqlite3_finalize(insert)
_ = exec("COMMIT")
let insertSeconds = Date().timeIntervalSince(insertStart)
info("ingest-rate", String(format: "%.0f messages/s (tokenize+insert)", Double(corpusN) / insertSeconds))

// Table 2: the trigram index, raw folded text, for substrings and CJK
// queries whose segmentation disagrees with the text.
let triStart = Date()
report("trigram-create", exec("CREATE VIRTUAL TABLE mail_tri USING fts5(subject, sender, body, tokenize='trigram')"))
guard let triInsert = prepare("INSERT INTO mail_tri(subject, sender, body) VALUES(?,?,?);") else {
    report("trigram-insert", false, "prepare failed")
    print("FTS5Spike: \(passed) passed, \(failed) failed")
    exit(1)
}
_ = exec("BEGIN")
for (i, m) in corpus.messages.enumerated() {
    let s = fold(m.subject)
    let f = fold("\(m.fromName) \(m.fromAddr)")
    let b = fold(m.body)
    sqlite3_bind_text(triInsert, 1, s, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(triInsert, 2, f, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(triInsert, 3, b, -1, SQLITE_TRANSIENT)
    guard sqlite3_step(triInsert) == SQLITE_DONE else {
        report("trigram-insert", false, "step failed at \(i)")
        print("FTS5Spike: \(passed) passed, \(failed) failed")
        exit(1)
    }
    sqlite3_reset(triInsert)
    if i % 25_000 == 0 { _ = exec("COMMIT"); _ = exec("BEGIN") }
}
sqlite3_finalize(triInsert)
_ = exec("COMMIT")
let triSeconds = Date().timeIntervalSince(triStart)
info("trigram-insert", String(format: "%.1fs", triSeconds))

// Sizes: per-table page usage via dbstat, falling back to whole-file size.
func tablePages(_ table: String) -> Int? {
    guard let stmt = prepare("SELECT sum(pgsize) FROM dbstat WHERE name LIKE ?") else { return nil }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, table + "%", -1, SQLITE_TRANSIENT)
    if sqlite3_step(stmt) == SQLITE_ROW {
        let v = sqlite3_column_int64(stmt, 0)
        return Int(v)
    }
    return nil
}
var pageSize = 4096
if let stmt = prepare("PRAGMA page_size") {
    if sqlite3_step(stmt) == SQLITE_ROW { pageSize = Int(sqlite3_column_int64(stmt, 0)) }
    sqlite3_finalize(stmt)
}
let ftsBytes = tablePages("mail_fts")
let triBytes = tablePages("mail_tri")
if let f = ftsBytes, let t = triBytes {
    let per100k: (Int) -> Double = { bytes in Double(bytes) / Double(corpusN) * 100_000.0 / 1_048_576.0 }
    info("fts-size", String(format: "main FTS %.1f MB, trigram %.1f MB per 100k messages", per100k(f), per100k(t)))
    report("trigram-size-measured", true, String(format: "%.1f MB per 100k messages", per100k(t)))
} else {
    let path = String(cString: sqlite3_db_filename(db, "main"))
    let total = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    info("fts-size", "dbstat unavailable; total file \(total / 1_048_576) MB (page \(pageSize))")
    report("trigram-size-measured", false, "dbstat unavailable")
}

// The "narrow" trigram candidate: subject and sender only. DESIGN 6A says
// M2 narrows the trigram to the fields where it pays off if full-body is
// too large; measure both here so the choice has data.
let triNarrowStart = Date()
report("trigram-narrow-create", exec("CREATE VIRTUAL TABLE mail_tri_h USING fts5(subject, sender, tokenize='trigram')"))
guard let triNInsert = prepare("INSERT INTO mail_tri_h(subject, sender) VALUES(?,?);") else {
    report("trigram-narrow-insert", false, "prepare failed")
    print("FTS5Spike: \(passed) passed, \(failed) failed")
    exit(1)
}
_ = exec("BEGIN")
for (i, m) in corpus.messages.enumerated() {
    sqlite3_bind_text(triNInsert, 1, fold(m.subject), -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(triNInsert, 2, fold("\(m.fromName) \(m.fromAddr)"), -1, SQLITE_TRANSIENT)
    guard sqlite3_step(triNInsert) == SQLITE_DONE else {
        report("trigram-narrow-insert", false, "step failed at \(i)")
        print("FTS5Spike: \(passed) passed, \(failed) failed")
        exit(1)
    }
    sqlite3_reset(triNInsert)
    if i % 25_000 == 0 { _ = exec("COMMIT"); _ = exec("BEGIN") }
}
sqlite3_finalize(triNInsert)
_ = exec("COMMIT")
info("trigram-narrow-insert", String(format: "%.1fs", Date().timeIntervalSince(triNarrowStart)))
if let h = tablePages("mail_tri_h") {
    info("trigram-narrow-size", String(format: "%.1f MB per 100k messages (subject+sender only)", Double(h) / Double(corpusN) * 100_000.0 / 1_048_576.0))
}

// MARK: - Judged queries with known answers

struct JudgedQuery {
    let label: String
    let ftsMatch: String
    let triMatch: String?
    let relevant: Set<Int> // indexes
}

var judged: [JudgedQuery] = []

// Subject term queries: graded relevance — subject hit counts most.
var subjectQueryCount = 0
for (term, postings) in corpus.termPostings.shuffled(using: &rng) {
    if subjectQueryCount >= queriesN / 2 { break }
    guard postings.count >= 5 && postings.count <= 20_000 else { continue }
    judged.append(JudgedQuery(
        label: "subject:\(term)",
        ftsMatch: "{subject} : \(term)",
        triMatch: nil,
        relevant: Set(postings)
    ))
    subjectQueryCount += 1
}

// Sender-address queries.
var addrQueryCount = 0
for (addr, postings) in corpus.addrPostings.shuffled(using: &rng) {
    if addrQueryCount >= queriesN / 4 { break }
    guard postings.count >= 3 else { continue }
    judged.append(JudgedQuery(
        label: "from:\(addr)",
        ftsMatch: "{from_addr} : \"\(addr)\"",
        triMatch: nil,
        relevant: Set(postings)
    ))
    addrQueryCount += 1
}

// Company queries on the trigram table (substring semantics).
var companyQueryCount = 0
for (company, postings) in corpus.companyPostings.shuffled(using: &rng) {
    if companyQueryCount >= queriesN / 4 { break }
    guard postings.count >= 5 && postings.count <= 8000 else { continue }
    judged.append(JudgedQuery(
        label: "company:\(company)",
        ftsMatch: "{from_name} : \(company.split(separator: "-").map(String.init).joined(separator: " "))",
        triMatch: company,
        relevant: Set(postings)
    ))
    companyQueryCount += 1
}

func runFTSQuery(_ match: String, limit: Int) -> [Int64] {
    guard let stmt = prepare("SELECT rowid FROM mail_fts WHERE mail_fts MATCH ? ORDER BY bm25(mail_fts, 12.0, 8.0, 6.0, 1.0, 0.5) LIMIT \(limit)") else { return [] }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, match, -1, SQLITE_TRANSIENT)
    var out: [Int64] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        out.append(sqlite3_column_int64(stmt, 0))
    }
    return out
}

func runTriQuery(_ match: String, limit: Int) -> [Int64] {
    guard let stmt = prepare("SELECT rowid FROM mail_tri WHERE mail_tri MATCH ? ORDER BY rank LIMIT \(limit)") else { return [] }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, match, -1, SQLITE_TRANSIENT)
    var out: [Int64] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        out.append(sqlite3_column_int64(stmt, 0))
    }
    return out
}

// Merge FTS and trigram rankings by reciprocal rank fusion (DESIGN 6A).
func fused(_ a: [Int64], _ b: [Int64], limit: Int) -> [Int64] {
    var scores: [Int64: Double] = [:]
    for (rank, id) in a.enumerated() { scores[id, default: 0] += 1.0 / Double(60 + rank + 1) }
    for (rank, id) in b.enumerated() { scores[id, default: 0] += 1.0 / Double(60 + rank + 1) }
    return scores.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
}

var latenciesFirst: [Double] = []
var latenciesPage: [Double] = []
var recalls: [Double] = []
var ndcgs: [Double] = []

for q in judged {
    let t0 = Date()
    let page: [Int64]
    if let tri = q.triMatch {
        page = fused(runFTSQuery(q.ftsMatch, limit: 50), runTriQuery(tri, limit: 50), limit: 50)
    } else {
        page = runFTSQuery(q.ftsMatch, limit: 50)
    }
    latenciesPage.append(Date().timeIntervalSince(t0))

    // First-ten latency: a separate small query, as the app issues one on
    // each keystroke.
    let t2 = Date()
    let first: [Int64]
    if let tri = q.triMatch {
        first = fused(runFTSQuery(q.ftsMatch, limit: 10), runTriQuery(tri, limit: 10), limit: 10)
    } else {
        first = runFTSQuery(q.ftsMatch, limit: 10)
    }
    latenciesFirst.append(Date().timeIntervalSince(t2))
    _ = first

    let relevant = q.relevant
    guard !relevant.isEmpty else { continue }
    let relSet = Set(relevant.map { Int64($0 + 1) })
    let hits = page.filter { relSet.contains($0) }
    let recall = Double(hits.count) / Double(min(relevant.count, 50))
    recalls.append(recall)

    // Grade: a hit is fully relevant (3) if it is in the top slice of the
    // relevant set by date (recency proxy), else 2 for the rest. This keeps
    // the graded math real without inventing a second corpus pass.
    let sortedByDate = relevant.sorted { corpus.messages[$0].date > corpus.messages[$1].date }
    let top = Set(sortedByDate.prefix(min(3, relevant.count)).map { Int64($0 + 1) })
    let ideal: [Double] = sortedByDate.prefix(10).map { pow(2.0, Double(top.contains(Int64($0 + 1)) ? 3 : 2)) - 1.0 }
    var idcg = 0.0
    for (rank, g) in ideal.enumerated() { idcg += g / log2(Double(rank + 2)) }
    var dcg = 0.0
    for (rank, id) in first.enumerated() where relSet.contains(id) {
        let rel: Double = top.contains(id) ? 3 : 2
        dcg += (pow(2.0, rel) - 1.0) / log2(Double(rank + 2))
    }
    ndcgs.append(idcg == 0 ? 0 : dcg / idcg)
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let idx = min(sorted.count - 1, Int((p / 100.0) * Double(sorted.count)))
    return sorted[idx]
}

let avgRecall = recalls.reduce(0, +) / Double(max(recalls.count, 1))
let avgNDCG = ndcgs.reduce(0, +) / Double(max(ndcgs.count, 1))
let byKind = Dictionary(grouping: judged, by: { $0.label.split(separator: ":").first.map(String.init) ?? "?" })
    .map { "\($0.key)=\($0.value.count)" }
    .sorted()
    .joined(separator: " ")
info("queries", "\(judged.count) judged queries (target was \(queriesN)); mix: \(byKind)")
info("latency-first10", String(format: "p50=%.1fms p95=%.1fms max=%.1fms", percentile(latenciesFirst, 50) * 1000, percentile(latenciesFirst, 95) * 1000, percentile(latenciesFirst, 100) * 1000))
info("latency-page50", String(format: "p50=%.1fms p95=%.1fms max=%.1fms", percentile(latenciesPage, 50) * 1000, percentile(latenciesPage, 95) * 1000, percentile(latenciesPage, 100) * 1000))
info("relevance-baseline", String(format: "recall@50=%.3f nDCG@10=%.3f", avgRecall, avgNDCG))

// The spike's bar: the baseline must show the approach is usable — term and
// address queries find the known set, and answers come back far under the
// M2 budget (200 ms for a ranked page).
report("baseline-recall", avgRecall >= 0.9, String(format: "recall@50=%.3f (bar 0.90)", avgRecall))
report("baseline-latency", percentile(latenciesFirst, 95) < 0.2, String(format: "p95 first-10 %.1f ms (budget 200 ms)", percentile(latenciesFirst, 95) * 1000))

// CJK: a segmented Chinese query must find the Chinese messages.
let cjkProbe = pipelineTokens("发票").joined(separator: " ")
var cjkHits = 0
if let stmt = prepare("SELECT count(*) FROM mail_fts WHERE mail_fts MATCH ?") {
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, "{body} : \(cjkProbe)", -1, SQLITE_TRANSIENT)
    if sqlite3_step(stmt) == SQLITE_ROW { cjkHits = Int(sqlite3_column_int64(stmt, 0)) }
}
report("cjk-retrieval", cjkHits > 0, "invoice (发票) via segmented tokens matched \(cjkHits) bodies")

// Trigram: a substring that tokenization would miss must be found.
let triProbe = "blue"
var triHits = 0
if let stmt = prepare("SELECT count(*) FROM mail_tri WHERE mail_tri MATCH ?") {
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, triProbe, -1, SQLITE_TRANSIENT)
    if sqlite3_step(stmt) == SQLITE_ROW { triHits = Int(sqlite3_column_int64(stmt, 0)) }
}
report("trigram-substring", triHits > 0, "substring '\(triProbe)' matched \(triHits) rows")

print("FTS5Spike: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
