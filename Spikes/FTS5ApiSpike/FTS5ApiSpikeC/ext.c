// Spike 001 C side: fts5_api retrieval + auxiliary function registration.
//
// The retrieval uses the mechanism documented in fts5.h: FTS5 registers a
// scalar function named "fts5" whose single argument is a BLOB; the bytes
// are treated as the address at which to store the connection's fts5_api
// pointer. No FTS5 symbols are linked — fts5.h is header-only (struct +
// function-pointer typedefs), and sqlite3_* calls resolve to the same
// libsqlite3 the app (and GRDB's systemLibrary target) already links.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sqlite3.h>
/* The SDK's sqlite3.h carries the full FTS5 extension API (Fts5ExtensionApi,
 * fts5_api, Fts5PhraseIter) — no separate fts5.h needed on macOS or Linux. */

static const char *kLastError = "";

const char *bc_last_error(void) { return kLastError; }

/* Prepare "SELECT fts5(?1)", bind the output pointer with the typed
 * pointer API under the "fts5_api_ptr" type name, step once, and read the
 * pointer back. Documented in fts5.h. */
int bc_fts5_api_from_db(sqlite3 *db, fts5_api **ppApi) {
    sqlite3_stmt *pStmt = NULL;
    *ppApi = NULL;
    int rc = sqlite3_prepare_v2(db, "SELECT fts5(?1)", -1, &pStmt, NULL);
    if (rc != SQLITE_OK) {
        kLastError = sqlite3_errmsg(db);
        return rc;
    }
    rc = sqlite3_bind_pointer(pStmt, 1, (void *)ppApi, "fts5_api_ptr", NULL);
    if (rc != SQLITE_OK) {
        kLastError = sqlite3_errmsg(db);
        sqlite3_finalize(pStmt);
        return rc;
    }
    rc = sqlite3_step(pStmt);
    if (rc != SQLITE_ROW) {
        kLastError = rc == SQLITE_DONE ? "fts5() returned no row" : sqlite3_errmsg(db);
        sqlite3_finalize(pStmt);
        return rc == SQLITE_DONE ? SQLITE_ERROR : rc;
    }
    sqlite3_finalize(pStmt);
    /* fts5 wrote the api pointer through the bound address. */
    if (*ppApi == NULL) {
        kLastError = "fts5_api pointer not populated";
        return SQLITE_ERROR;
    }
    return SQLITE_OK;
}

/* --- the auxiliary function under test ------------------------------- */

/* Whole-table walk state for phrase 0, filled by the xQueryPhrase callback. */
typedef struct BcWalk {
    long long docs; /* rows visited by xQueryPhrase (each contains the phrase) */
    long long hits; /* in-row instances of the phrase, via xPhraseFirst/Next */
} BcWalk;

/* Invoked once per row matching phrase 0 of the captured query. */
static int bc_walk_cb(const Fts5ExtensionApi *pApi, Fts5Context *pFts, void *pUserData) {
    BcWalk *w = (BcWalk *)pUserData;
    w->docs++;
    Fts5PhraseIter iter;
    int col = -1, off = -1;
    for (pApi->xPhraseFirst(pFts, 0, &iter, &col, &off); col >= 0;
         pApi->xPhraseNext(pFts, &iter, &col, &off)) {
        w->hits++;
    }
    return SQLITE_OK; /* SQLITE_DONE would abort the walk early (top-k cutoff) */
}

/* State captured on each invocation, verified from Swift afterwards. */
typedef struct BcAuxState {
    int invoked;       /* number of times the aux function ran */
    int phraseCount;   /* xPhraseCount */
    long long rowCount;/* xRowCount */
    BcWalk walk;       /* xQueryPhrase walk of phrase 0 */
    int xQueryRc;      /* rc of the walk */
} BcAuxState;

static BcAuxState g_aux = {0};

/* Called once per result row: SELECT bc_aux(t_fts) FROM t_fts WHERE MATCH ... */
static void bc_aux(const Fts5ExtensionApi *pApi, Fts5Context *pFts,
                   sqlite3_context *pCtx, int nArg, sqlite3_value **apArg) {
    (void)nArg; (void)apArg;
    g_aux.invoked++;
    g_aux.phraseCount = pApi->xPhraseCount(pFts);
    sqlite3_int64 nRow = 0;
    if (pApi->xRowCount(pFts, &nRow) == SQLITE_OK) g_aux.rowCount = (long long)nRow;
    BcWalk w = {0};
    g_aux.xQueryRc = pApi->xQueryPhrase(pFts, 0, &w, bc_walk_cb);
    g_aux.walk = w; /* per-invocation result, not accumulated */
    sqlite3_result_int64(pCtx, w.docs); /* visible in the result row */
}

int bc_register_aux(sqlite3 *db) {
    fts5_api *api = NULL;
    int rc = bc_fts5_api_from_db(db, &api);
    if (rc != SQLITE_OK) return rc;
    /* fts5_api::xCreateFunction(api, name, pUserData, xFunction, xDestroy) */
    return api->xCreateFunction(api, "bc_aux", NULL, bc_aux, NULL);
}

void bc_aux_reset(void) { memset(&g_aux, 0, sizeof(g_aux)); }
long long bc_aux_invoked(void) { return g_aux.invoked; }
long long bc_aux_phrase_count(void) { return g_aux.phraseCount; }
long long bc_aux_row_count(void) { return g_aux.rowCount; }
long long bc_aux_walk_docs(void) { return g_aux.walk.docs; }
long long bc_aux_walk_hits(void) { return g_aux.walk.hits; }
int bc_aux_xquery_rc(void) { return g_aux.xQueryRc; }

/* Version sanity: report what we compiled against and what we run with. */
const char *bc_link_version(void) { return sqlite3_libversion(); }

/* --- thin shims so the Swift side needs no SQLite3 module ------------- */

int bc_open(const char *path, sqlite3 **ppDb, int flags) {
    return sqlite3_open_v2(path, ppDb, flags, NULL);
}
int bc_close(sqlite3 *db) { return sqlite3_close(db); }
int bc_exec(sqlite3 *db, const char *sql) {
    char *err = NULL;
    int rc = sqlite3_exec(db, sql, NULL, NULL, &err);
    if (err) {
        kLastError = err; /* leaked intentionally: spike */
    }
    return rc;
}
int bc_prepare(sqlite3 *db, const char *sql, sqlite3_stmt **ppStmt) {
    return sqlite3_prepare_v2(db, sql, -1, ppStmt, NULL);
}
int bc_step(sqlite3_stmt *p) { return sqlite3_step(p); }
sqlite3_int64 bc_column_int64(sqlite3_stmt *p, int i) { return sqlite3_column_int64(p, i); }
int bc_finalize(sqlite3_stmt *p) { return sqlite3_finalize(p); }
const char *bc_errmsg(sqlite3 *db) { return sqlite3_errmsg(db); }

