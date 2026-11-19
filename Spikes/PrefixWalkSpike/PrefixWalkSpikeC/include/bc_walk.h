/* Spike 002 public C API: FTS5 posting-walk top-k on the 1M probe DB. */
#ifndef BC_WALK_H
#define BC_WALK_H

#include <sqlite3.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Register the "bc_topk" auxiliary function on db (once). */
int bc_walk_init(sqlite3 *db);

/* Run one walk: MATCH query (prefix shape like 'c*'), top-k by FTS5 bm25
 * with the probe corpus's column weights. Results readable afterwards via
 * bc_result_*. Returns SQLITE_OK or an error code. */
int bc_walk_query(sqlite3 *db, const char *query, int k);

/* Same walk without per-instance enumeration (pure posting-walk cost). */
int bc_walk_query_docs_only(sqlite3 *db, const char *query, int k);

/* SQL reference top-k for verification: ascending bm25, ids + scores. */
int bc_sql_topk(sqlite3 *db, const char *query, int k,
                sqlite3_int64 *outIds, double *outScores, int *outN);

int bc_open_ro(const char *path, sqlite3 **ppDb);
int bc_close(sqlite3 *db);
int bc_exec(sqlite3 *db, const char *sql);
int bc_prepare(sqlite3 *db, const char *sql, sqlite3_stmt **ppStmt);
int bc_step(sqlite3_stmt *p);
sqlite3_int64 bc_column_int64(sqlite3_stmt *p, int i);
const char *bc_column_text(sqlite3_stmt *p, int i);
int bc_finalize(sqlite3_stmt *p);
const char *bc_errmsg(sqlite3 *db);

/* Results of the last bc_walk_query. */
int bc_result_n(void);
sqlite3_int64 bc_result_rowid(int i);
double bc_result_score(int i);

/* Timings and counters of the last walk (nanoseconds). */
long long bc_stat_ns_docs_only(void);   /* pass 1: doc-only walks (idf counts) */
long long bc_stat_ns_score(void);       /* pass 2: scoring walks (per-instance) */
long long bc_stat_ns_scan(void);        /* final: idf fold + top-k scan */
long long bc_stat_ns_total(void);       /* end to end inside C */
long long bc_stat_docs_visited(void);   /* total docs visited by scoring walks */
long long bc_stat_instances(void);      /* total phrase instances enumerated */
int bc_stat_phrases(void);
long long bc_stat_nhits(int phrase);    /* docs containing each phrase */
double bc_stat_idf(int phrase);
long long bc_stat_out_of_range(void);   /* rowids beyond the score array */

/* True when the top-k would be degenerate (every idf clamped): the walk
 * works but ranking carries almost no information. */
int bc_stat_degenerate(void);

const char *bc_last_error(void);
const char *bc_link_version(void);

#ifdef __cplusplus
}
#endif

#endif /* BC_WALK_H */
