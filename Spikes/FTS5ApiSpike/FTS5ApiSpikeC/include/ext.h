/* Spike 001 public C API: fts5_api retrieval + auxiliary function demo. */
#ifndef BC_EXT_H
#define BC_EXT_H

#include <sqlite3.h>

#ifdef __cplusplus
extern "C" {
#endif

const char *bc_last_error(void);

/* Documented fts5.h mechanism: SELECT fts5(?1) with the output pointer
 * bound as a BLOB. Returns SQLITE_OK and sets *ppApi on success. */
int bc_fts5_api_from_db(sqlite3 *db, fts5_api **ppApi);

/* Register the "bc_aux" FTS5 auxiliary function on db. */
int bc_register_aux(sqlite3 *db);

void bc_aux_reset(void);
long long bc_aux_invoked(void);
long long bc_aux_phrase_count(void);
long long bc_aux_row_count(void);
long long bc_aux_walk_docs(void);
long long bc_aux_walk_hits(void);
int bc_aux_xquery_rc(void);

const char *bc_link_version(void);

int bc_open(const char *path, sqlite3 **ppDb, int flags);
int bc_close(sqlite3 *db);
int bc_exec(sqlite3 *db, const char *sql);
int bc_prepare(sqlite3 *db, const char *sql, sqlite3_stmt **ppStmt);
int bc_step(sqlite3_stmt *p);
sqlite3_int64 bc_column_int64(sqlite3_stmt *p, int i);
int bc_finalize(sqlite3_stmt *p);
const char *bc_errmsg(sqlite3 *db);

#ifdef __cplusplus
}
#endif

#endif /* BC_EXT_H */
