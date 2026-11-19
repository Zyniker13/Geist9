// Spike 002 C side: whole-corpus FTS5 posting walk with exact bm25 top-k,
// on the probe 1M corpus. Mirrors SQLite's bm25 (k1=1.2, b=0.75, per-column
// weights, idf clamp at 1e-6) so results are comparable with SQL bm25.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <math.h>
#include <sqlite3.h>

#include "bc_walk.h"

#define BC_MAX_PHRASES 4
#define BC_MAX_COLS 7
#define BC_MAXRID 1200000 /* probe1m rowids are 1..~1M dense */

static const double kWeights[BC_MAX_COLS] = {12.0, 8.0, 6.0, 5.0, 1.0, 0.4, 0.3};

static const char *kLastError = "";
const char *bc_last_error(void) { return kLastError; }

/* Documented fts5.h mechanism: SELECT fts5(?1) with the output pointer
 * bound via the typed-pointer API. */
int bc_fts5_api_from_db(sqlite3 *db, fts5_api **ppApi) {
    sqlite3_stmt *pStmt = NULL;
    *ppApi = NULL;
    int rc = sqlite3_prepare_v2(db, "SELECT fts5(?1)", -1, &pStmt, NULL);
    if (rc != SQLITE_OK) { kLastError = sqlite3_errmsg(db); return rc; }
    rc = sqlite3_bind_pointer(pStmt, 1, (void *)ppApi, "fts5_api_ptr", NULL);
    if (rc != SQLITE_OK) { kLastError = sqlite3_errmsg(db); sqlite3_finalize(pStmt); return rc; }
    rc = sqlite3_step(pStmt);
    sqlite3_finalize(pStmt);
    if (rc != SQLITE_ROW) {
        kLastError = rc == SQLITE_DONE ? "fts5() returned no row" : sqlite3_errmsg(db);
        return rc == SQLITE_DONE ? SQLITE_ERROR : rc;
    }
    if (*ppApi == NULL) { kLastError = "fts5_api pointer not populated"; return SQLITE_ERROR; }
    return SQLITE_OK;
}

/* Persistent per-phrase raw arrays (survive cfg memset between queries). */
static double *g_raw[BC_MAX_PHRASES];

static long long now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

/* --- configuration + state ------------------------------------------- */

typedef struct BcCfg {
    int k;
    double weights[BC_MAX_COLS];
    int countInstances; /* 0: doc-only walk (walk cost), 1: enumerate tf */
    int done;           /* the aux function runs the pipeline once */
    double *raw[BC_MAX_PHRASES];      /* per-phrase idf-independent parts */
    long long nhits[BC_MAX_PHRASES];
    double idf[BC_MAX_PHRASES];
    int nPhrases;
    long long N;
    double avgdl[BC_MAX_COLS];
    long long docsVisited, instances, outOfRange;
    long long nsScore, nsScan, nsTotal;
    int degenerate;
    int nResults;
    sqlite3_int64 rowid[64];
    double score[64];
} BcCfg;

static BcCfg g_cfg;

static void bc_sift_down(double *s, sqlite3_int64 *r, int n, int i) {
    for (;;) {
        int l = 2 * i + 1, rr = 2 * i + 2, m = i;
        if (l < n && s[l] < s[m]) m = l;
        if (rr < n && s[rr] < s[m]) m = rr;
        if (m == i) break;
        double ts = s[i]; s[i] = s[m]; s[m] = ts;
        sqlite3_int64 tr = r[i]; r[i] = r[m]; r[m] = tr;
        i = m;
    }
}

typedef struct BcWalkState {
    BcCfg *cfg;
    int phrase;
    double *raw;
    long long docs, insts, oor;
} BcWalkState;

/* Invoked once per doc containing the phrase. Mirrors fts5Bm25Function:
 * freq = sum over the phrase's instances of the instance column's weight,
 * D = whole-row token count, one corpus-wide avgdl. */
static int bc_score_cb(const Fts5ExtensionApi *pApi, Fts5Context *pFts, void *pUserData) {
    BcWalkState *st = (BcWalkState *)pUserData;
    BcCfg *cfg = st->cfg;
    sqlite3_int64 rowid = pApi->xRowid(pFts);
    if (rowid < 1 || rowid >= BC_MAXRID) { st->oor++; return SQLITE_OK; }
    st->docs++;

    if (!cfg->countInstances) return SQLITE_OK; /* doc-only variant */

    double freq = 0.0;
    int col = -1, off = -1;
    Fts5PhraseIter iter;
    for (pApi->xPhraseFirst(pFts, st->phrase, &iter, &col, &off); col >= 0;
         pApi->xPhraseNext(pFts, &iter, &col, &off)) {
        freq += (col < BC_MAX_COLS) ? cfg->weights[col] : 1.0;
        st->insts++;
    }
    if (freq > 0.0) {
        int nTok = 0;
        if (pApi->xColumnSize(pFts, -1, &nTok) != SQLITE_OK) nTok = 1;
        double d = (double)nTok;
        double norm = 0.25 + 0.75 * d / cfg->avgdl[0]; /* 1 - b + b*D/avgdl */
        if (norm <= 0) norm = 1e-6;
        st->raw[rowid] += (freq * 2.2) / (freq + 1.2 * norm); /* k1=1.2, k1+1=2.2 */
    }
    return SQLITE_OK;
}

/* Invoked once per result row of the capture query; runs the pipeline on
 * the first call only. */
static void bc_topk_aux(const Fts5ExtensionApi *pApi, Fts5Context *pFts,
                        sqlite3_context *pCtx, int nArg, sqlite3_value **apArg) {
    (void)nArg; (void)apArg;
    BcCfg *cfg = &g_cfg;
    if (cfg->done) { sqlite3_result_int(pCtx, cfg->k); return; }
    cfg->done = 1;
    long long t0 = now_ns();

    cfg->nPhrases = pApi->xPhraseCount(pFts);
    if (cfg->nPhrases > BC_MAX_PHRASES) cfg->nPhrases = BC_MAX_PHRASES;
    if (pApi->xRowCount(pFts, &cfg->N) != SQLITE_OK) {
        sqlite3_result_error(pCtx, "xRowCount failed", -1);
        return;
    }
    /* One corpus-wide average doc length, as FTS5's bm25 does it:
     * xColumnTotalSize(-1) / N (all indexed columns together). */
    {
        sqlite3_int64 tot = 0;
        cfg->avgdl[0] = (pApi->xColumnTotalSize(pFts, -1, &tot) == SQLITE_OK && cfg->N > 0)
            ? (double)tot / (double)cfg->N : 1.0;
    }

    for (int p = 0; p < cfg->nPhrases; p++) {
        if (!g_raw[p]) g_raw[p] = (double *)malloc(sizeof(double) * BC_MAXRID);
        memset(g_raw[p], 0, sizeof(double) * BC_MAXRID);
        cfg->raw[p] = g_raw[p];
    }

    BcWalkState st;
    memset(&st, 0, sizeof(st));
    st.cfg = cfg;
    long long tWalk = now_ns();
    for (int p = 0; p < cfg->nPhrases; p++) {
        st.phrase = p;
        st.raw = cfg->raw[p];
        st.docs = st.insts = st.oor = 0;
        int rc = pApi->xQueryPhrase(pFts, p, &st, bc_score_cb);
        if (rc != SQLITE_OK) {
            kLastError = "xQueryPhrase failed";
            sqlite3_result_error_code(pCtx, rc);
            return;
        }
        cfg->nhits[p] = st.docs;
        cfg->docsVisited += st.docs;
        cfg->instances += st.insts;
        cfg->outOfRange += st.oor;
        double idf = log((cfg->N - (double)st.docs + 0.5) / ((double)st.docs + 0.5));
        if (idf <= 0.0) { idf = 1e-6; cfg->degenerate = 1; }
        cfg->idf[p] = idf;
    }
    cfg->nsScore = now_ns() - tWalk;

    /* Fold idf into the raw parts and take the top-k with a bounded scan. */
    long long tScan = now_ns();
    int k = cfg->k;
    double heapScore[64];
    sqlite3_int64 heapRow[64];
    int heapN = 0;
    for (long long rid = 1; rid < BC_MAXRID; rid++) {
        double s = 0.0;
        for (int p = 0; p < cfg->nPhrases; p++) s += cfg->idf[p] * cfg->raw[p][rid];
        if (s <= 0.0) continue;
        if (heapN < k) {
            heapScore[heapN] = s; heapRow[heapN] = rid; heapN++;
            if (heapN == k) {
                for (int i = heapN / 2 - 1; i >= 0; i--) bc_sift_down(heapScore, heapRow, heapN, i);
            }
        } else if (s > heapScore[0]) {
            heapScore[0] = s; heapRow[0] = rid;
            bc_sift_down(heapScore, heapRow, heapN, 0);
        }
    }
    cfg->nsScan = now_ns() - tScan;

    cfg->nResults = heapN;
    for (int i = 0; i < heapN; i++) {
        int best = 0;
        for (int j = 1; j < heapN - i; j++)
            if (heapScore[j] > heapScore[best]) best = j;
        cfg->rowid[i] = heapRow[best];
        cfg->score[i] = heapScore[best];
        heapScore[best] = heapScore[heapN - i - 1];
        heapRow[best] = heapRow[heapN - i - 1];
    }

    cfg->nsTotal = now_ns() - t0;
    sqlite3_result_int(pCtx, cfg->k);
}

/* --- driver ------------------------------------------------------------ */

int bc_walk_init(sqlite3 *db) {
    fts5_api *api = NULL;
    int rc = bc_fts5_api_from_db(db, &api);
    if (rc != SQLITE_OK) { kLastError = sqlite3_errmsg(db); return rc; }
    return api->xCreateFunction(api, "bc_topk", NULL, bc_topk_aux, NULL);
}

static int bc_walk_run(sqlite3 *db, const char *query, int k, int countInstances) {
    memset(&g_cfg, 0, sizeof(g_cfg));
    g_cfg.k = k;
    memcpy(g_cfg.weights, kWeights, sizeof(kWeights));
    g_cfg.countInstances = countInstances;

    sqlite3_stmt *stmt = NULL;
    const char *sql =
        "SELECT bc_topk(probe_fts) FROM probe_fts WHERE probe_fts MATCH ? LIMIT 1";
    int rc = sqlite3_prepare_v2(db, sql, -1, &stmt, NULL);
    if (rc != SQLITE_OK) { kLastError = sqlite3_errmsg(db); return rc; }
    rc = sqlite3_bind_text(stmt, 1, query, -1, SQLITE_STATIC);
    if (rc != SQLITE_OK) { kLastError = sqlite3_errmsg(db); sqlite3_finalize(stmt); return rc; }
    rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    if (rc != SQLITE_ROW) {
        kLastError = rc == SQLITE_DONE ? "no rows matched" : sqlite3_errmsg(db);
        return rc == SQLITE_DONE ? SQLITE_ERROR : rc;
    }
    return SQLITE_OK;
}

int bc_walk_query(sqlite3 *db, const char *query, int k) {
    return bc_walk_run(db, query, k, 1);
}

int bc_walk_query_docs_only(sqlite3 *db, const char *query, int k) {
    return bc_walk_run(db, query, k, 0);
}

/* SQL reference top-k (ids + bm25) for verification, ascending bm25. */
int bc_sql_topk(sqlite3 *db, const char *query, int k,
                sqlite3_int64 *outIds, double *outScores, int *outN) {
    sqlite3_stmt *stmt = NULL;
    const char *sql =
        "SELECT rowid, bm25(probe_fts, 12.0, 8.0, 6.0, 5.0, 1.0, 0.4, 0.3) AS s "
        "FROM probe_fts WHERE probe_fts MATCH ? ORDER BY s LIMIT ?";
    int rc = sqlite3_prepare_v2(db, sql, -1, &stmt, NULL);
    if (rc != SQLITE_OK) { kLastError = sqlite3_errmsg(db); return rc; }
    sqlite3_bind_text(stmt, 1, query, -1, SQLITE_STATIC);
    sqlite3_bind_int(stmt, 2, k);
    int n = 0;
    while (sqlite3_step(stmt) == SQLITE_ROW && n < k) {
        outIds[n] = sqlite3_column_int64(stmt, 0);
        outScores[n] = sqlite3_column_double(stmt, 1);
        n++;
    }
    int rc2 = sqlite3_finalize(stmt);
    *outN = n;
    return rc2 == SQLITE_OK ? SQLITE_OK : rc2;
}

/* --- accessors ---------------------------------------------------------- */

int bc_open_ro(const char *path, sqlite3 **ppDb) {
    return sqlite3_open_v2(path, ppDb, SQLITE_OPEN_READONLY, NULL);
}
int bc_close(sqlite3 *db) { return sqlite3_close(db); }
int bc_exec(sqlite3 *db, const char *sql) {
    char *err = NULL;
    int rc = sqlite3_exec(db, sql, NULL, NULL, &err);
    if (err) kLastError = err; /* leaked intentionally: spike */
    return rc;
}
int bc_prepare(sqlite3 *db, const char *sql, sqlite3_stmt **ppStmt) {
    return sqlite3_prepare_v2(db, sql, -1, ppStmt, NULL);
}
int bc_step(sqlite3_stmt *p) { return sqlite3_step(p); }
sqlite3_int64 bc_column_int64(sqlite3_stmt *p, int i) { return sqlite3_column_int64(p, i); }
const char *bc_column_text(sqlite3_stmt *p, int i) {
    return (const char *)sqlite3_column_text(p, i);
}
int bc_finalize(sqlite3_stmt *p) { return sqlite3_finalize(p); }
const char *bc_errmsg(sqlite3 *db) { return sqlite3_errmsg(db); }

int bc_result_n(void) { return g_cfg.nResults; }
sqlite3_int64 bc_result_rowid(int i) { return g_cfg.rowid[i]; }
double bc_result_score(int i) { return g_cfg.score[i]; }

long long bc_stat_ns_score(void) { return g_cfg.nsScore; }
long long bc_stat_ns_scan(void) { return g_cfg.nsScan; }
long long bc_stat_ns_total(void) { return g_cfg.nsTotal; }
long long bc_stat_docs_visited(void) { return g_cfg.docsVisited; }
long long bc_stat_instances(void) { return g_cfg.instances; }
int bc_stat_phrases(void) { return g_cfg.nPhrases; }
long long bc_stat_nhits(int phrase) { return g_cfg.nhits[phrase]; }
double bc_stat_idf(int phrase) { return g_cfg.idf[phrase]; }
long long bc_stat_out_of_range(void) { return g_cfg.outOfRange; }
int bc_stat_degenerate(void) { return g_cfg.degenerate; }

const char *bc_link_version(void) { return sqlite3_libversion(); }
