// Spike 001: can a SwiftPM C target reach fts5_api and register an FTS5
// auxiliary function, on the same libsqlite3 the app (and GRDB) links?
//
// All sqlite3 calls go through C shims so the Swift side compiles on
// Linux too (no SQLite3 systemLibrary module there).
//
// Usage: swift run FTS5ApiSpike
// Prints one PASS/FAIL/INFO line per step; exits 0 only if every step passed.

import Foundation
import FTS5ApiSpikeC

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed = 0

func report(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { passed += 1; print("PASS \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
    else { failed += 1; print("FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
}

func info(_ name: String, _ detail: String) {
    print("INFO \(name) — \(detail)")
}

func check(_ rc: Int32, _ what: String, _ db: OpaquePointer?) -> Bool {
    guard rc == SQLITE_OK else {
        let msg = db.map { String(cString: bc_errmsg($0)) } ?? String(cString: bc_last_error())
        report(what, false, msg)
        return false
    }
    return true
}

var db: OpaquePointer?
defer { if db != nil { bc_close(db) } }

// 1. Open a temporary database.
let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("fts5api-spike-\(UUID().uuidString).db").path
var dbOut: OpaquePointer?
let openRc = bc_open(tmp, &dbOut, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
db = dbOut
report("open", openRc == SQLITE_OK)

// 2. Create an FTS5 table (proves the linked library has FTS5 compiled in).
check(bc_exec(db, """
CREATE TABLE t(a, b);
CREATE VIRTUAL TABLE t_fts USING fts5(a, b, content='t', content_rowid='rowid');
"""), "create fts5 table", db)

// 3. Insert a tiny fixture and rebuild the index.
// 'banana' appears in rows 1, 2, 4; row 4 has it twice (4 instances total).
check(bc_exec(db, """
INSERT INTO t(rowid, a, b) VALUES
 (1, 'banana apple', 'x'),
 (2, 'banana cherry', 'y'),
 (3, 'apple durian', 'z'),
 (4, 'cherry banana banana', 'w');
INSERT INTO t_fts(t_fts) VALUES('rebuild');
"""), "fixture insert", db)

info("link version", String(cString: bc_link_version()))

// 4. Retrieve fts5_api and register the auxiliary function.
check(bc_register_aux(db), "fts5_api + xCreateFunction", db)

// 5. Invoke the aux function through the SELECT list of a MATCH query.
//    The aux function sees the per-row Fts5Context and walks the whole
//    posting list of phrase 0 ('banana') via xQueryPhrase.
bc_aux_reset()
var stmt: OpaquePointer?
check(bc_prepare(db, "SELECT rowid, bc_aux(t_fts) FROM t_fts WHERE t_fts MATCH 'banana' ORDER BY rank", &stmt), "prepare aux query", db)
defer { bc_finalize(stmt) }

var rows: [Int64] = []
var auxResults: [Int64] = []
while bc_step(stmt) == SQLITE_ROW {
    rows.append(bc_column_int64(stmt, 0))
    auxResults.append(bc_column_int64(stmt, 1))
}
info("query rows", rows.map(String.init).joined(separator: ","))
report("aux invoked once per result row", bc_aux_invoked() == Int64(rows.count),
       "invoked=\(bc_aux_invoked()) rows=\(rows.count)")
report("phrase count seen by aux", bc_aux_phrase_count() == 1, "got \(bc_aux_phrase_count())")
report("row count seen by aux", bc_aux_row_count() == 4, "got \(bc_aux_row_count())")
report("xQueryPhrase rc", bc_aux_xquery_rc() == SQLITE_OK, "rc=\(bc_aux_xquery_rc())")
report("phrase-0 walk: 3 docs", bc_aux_walk_docs() == 3, "docs=\(bc_aux_walk_docs())")
report("phrase-0 walk: 4 instances", bc_aux_walk_hits() == 4, "hits=\(bc_aux_walk_hits())")
report("walk result visible per row", auxResults.allSatisfy { $0 == 3 },
       "\(auxResults.map(String.init).joined(separator: ","))")

// 6. OR query: aux sees the merged query; phrase 0 is now 'apple' (2 docs),
//    emitted across 4 result rows.
bc_aux_reset()
var stmt2: OpaquePointer?
check(bc_prepare(db, "SELECT rowid, bc_aux(t_fts) FROM t_fts WHERE t_fts MATCH 'apple OR cherry' ORDER BY rank", &stmt2), "prepare aux query 2", db)
defer { bc_finalize(stmt2) }
var rows2 = 0
while bc_step(stmt2) == SQLITE_ROW { rows2 += 1 }
report("aux on OR-query", bc_aux_invoked() == Int64(rows2) && bc_aux_walk_docs() == 2,
       "invoked=\(bc_aux_invoked()) rows=\(rows2) phrase0Docs=\(bc_aux_walk_docs())")

if failed == 0 {
    print("SPIKE-001 RESULT: PASS (\(passed) checks)")
} else {
    print("SPIKE-001 RESULT: FAIL (\(failed) failed of \(passed + failed))")
    exit(1)
}
