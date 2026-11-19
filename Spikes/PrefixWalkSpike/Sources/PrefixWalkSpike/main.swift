// Spike 002: C posting-walk top-k over FTS5 prefix shapes on the 1M probe
// corpus. Question: can the first-keystroke shape (single prefix term,
// e.g. 'c*') come back under the 50 ms budget (DESIGN 6A, enforced from
// M2), using xQueryPhrase walks + exact bm25 top-k in C?
//
// Usage: swift run PrefixWalkSpike <probe1m.db> [repeats]
// Prints one INFO line per shape with p50/min over repeats, plus a
// verification pass against SQL bm25 on a mid-size shape.

import Foundation
import PrefixWalkSpikeC

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed = 0

func report(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { passed += 1; print("PASS \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
    else { failed += 1; print("FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
}

guard CommandLine.arguments.count >= 2 else {
    print("usage: PrefixWalkSpike <probe1m.db> [repeats]")
    exit(2)
}
let dbPath = CommandLine.arguments[1]
let repeats = CommandLine.arguments.count >= 3 ? Int(CommandLine.arguments[2]) ?? 5 : 5

nonisolated(unsafe) var db: OpaquePointer?
nonisolated(unsafe) var dbOut: OpaquePointer?
let openRc = bc_open_ro(dbPath, &dbOut)
db = dbOut
guard openRc == SQLITE_OK, db != nil else {
    print("FAIL open — \(String(cString: bc_last_error()))")
    exit(1)
}
defer { bc_close(db) }
_ = bc_exec(db, "PRAGMA mmap_size=2147483648; PRAGMA cache_size=-64000;")
guard bc_walk_init(db) == SQLITE_OK else {
    print("FAIL bc_walk_init — \(String(cString: bc_last_error()))")
    exit(1)
}
print("INFO link version — \(String(cString: bc_link_version()))")

// Warm the page cache with a small query first.
_ = bc_walk_query(db, "mono", 10)

struct Sample { let minMs: Double; let p50Ms: Double }

func measure(_ query: String, k: Int32, instances: Bool, repeats: Int) -> Sample? {
    var times: [Double] = []
    for _ in 0..<repeats {
        let rc = instances ? bc_walk_query(db, query, k) : bc_walk_query_docs_only(db, query, k)
        guard rc == SQLITE_OK else {
            print("FAIL walk \(query) — \(String(cString: bc_last_error()))")
            return nil
        }
        times.append(Double(bc_stat_ns_total()) / 1e6)
    }
    times.sort()
    let p50 = times.count % 2 == 1
        ? times[times.count / 2]
        : (times[times.count / 2 - 1] + times[times.count / 2]) / 2
    return Sample(minMs: times.first ?? 0, p50Ms: p50)
}

func statLine(_ query: String) -> String {
    let docs = bc_stat_docs_visited()
    let inst = bc_stat_instances()
    let per = inst > 0 ? String(format: "%.0f ns/inst", Double(bc_stat_ns_score()) / Double(max(inst, 1))) : ""
    let deg = bc_stat_degenerate() == 1 ? " [degenerate idf]" : ""
    return "docs=\(docs) inst=\(inst) \(per)\(deg)"
}

// Shapes: 1-char prefixes (first keystroke), 2-char prefixes, exact terms
// (posting-list ceiling), and two-phrase variants (second keystroke).
let shapes: [(String, Int32)] = [
    ("c", 10), ("j", 10), ("m", 10), ("s", 10), ("b", 10), ("t", 10), ("w", 10),
    ("jo", 10), ("mu", 10), ("re", 10), ("wo", 10), ("ca", 10), ("sa", 10),
    ("jojasu", 10),
    ("mu* jojasu", 10), ("mu* jo*", 10), ("caju nusi", 10),
]

print("")
for (stem, k) in shapes {
    let q = stem.contains("*") || stem.contains(" ") ? stem : stem + "*"
    let dOnly = measure(q, k: k, instances: false, repeats: repeats)
    let full = measure(q, k: k, instances: true, repeats: repeats)
    guard let dOnly, let full else { continue }
    let total = String(format: "full p50 %.1f min %.1f | walk-only p50 %.1f min %.1f ms",
                       full.p50Ms, full.minMs, dOnly.p50Ms, dOnly.minMs)
    print("INFO \(q) — \(total) — \(statLine(q))")
}

// Verification: mid-size exact term (M ≈ 62k), C walk vs SQL bm25.
print("")
var sqlIds = [sqlite3_int64](repeating: 0, count: 10)
var sqlScores = [Double](repeating: 0, count: 10)
var sqlN = Int32(0)
if bc_sql_topk(db, "voladece", 10, &sqlIds, &sqlScores, &sqlN) == SQLITE_OK {
    _ = bc_walk_query(db, "voladece", 10)
    let n = Swift.min(Int(bc_result_n()), Int(sqlN))
    // Tie-aware comparison: sort both by (score desc, rowid asc). SQL bm25
    // is negative; our score is positive relevance, so keys agree.
    var mine: [(rid: Int64, s: Double)] = []
    var theirs: [(rid: Int64, s: Double)] = []
    for i in 0..<n {
        let ci = Int32(i)
        mine.append((bc_result_rowid(ci), bc_result_score(ci)))
        theirs.append((sqlIds[i], -sqlScores[i]))
    }
    let sortedMine = mine.sorted { $0.s != $1.s ? $0.s > $1.s : $0.rid < $1.rid }
    let sortedTheirs = theirs.sorted { $0.s != $1.s ? $0.s > $1.s : $0.rid < $1.rid }
    var same = true
    for i in 0..<n {
        if abs(sortedMine[i].s - sortedTheirs[i].s) > 1e-4 * Swift.max(1.0, abs(sortedMine[i].s)) { same = false }
    }
    report("top-10 ids match SQL (voladece, tie-aware)",
           sortedMine.map { String($0.rid) } == sortedTheirs.map { String($0.rid) },
           "C: \(sortedMine.map { String($0.rid) }.joined(separator: ",")) | SQL: \(sortedTheirs.map { String($0.rid) }.joined(separator: ","))")
    report("top-10 scores match SQL (voladece)", same)
} else {
    report("SQL reference run", false, String(cString: bc_last_error()))
}

// Vocabulary-gated alternative: term completions via fts5vocab (no
// postings walked). This is the cheapest honest first-keystroke response.
print("")
_ = bc_exec(db, "CREATE VIRTUAL TABLE temp.v USING fts5vocab('main', 'probe_fts', 'row')")
for stem in ["c", "j", "m", "jo", "mu", "wo"] {
    let end = String(stem.dropLast()) + String(UnicodeScalar(UInt8(stem.last!.asciiValue! + 1)))
    var stmt: OpaquePointer?
    let sql = "SELECT term, doc FROM temp.v WHERE term >= '\(stem)' AND term < '\(end)' ORDER BY doc DESC LIMIT 8"
    guard bc_prepare(db, sql, &stmt) == SQLITE_OK else {
        report("vocab probe \(stem)", false, String(cString: bc_errmsg(db)))
        continue
    }
    let t0 = DispatchTime.now().uptimeNanoseconds
    var terms: [String] = []
    while bc_step(stmt) == SQLITE_ROW {
        if let t = bc_column_text(stmt, 0) { terms.append(String(cString: t)) }
    }
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    bc_finalize(stmt)
    print("INFO vocab \(stem)* — \(String(format: "%.2f", ms)) ms — top: \(terms.prefix(5).joined(separator: " "))")
}

if failed == 0 {
    print("SPIKE-002 RESULT: PASS (\(passed) checks)")
} else {
    print("SPIKE-002 RESULT: FAIL (\(failed) failed of \(passed + failed))")
    exit(1)
}
