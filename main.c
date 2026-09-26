/*
* Copyright (c) 2018 Calvin Rose
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to
* deal in the Software without restriction, including without limitation the
* rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
* sell copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in
* all copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
* FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
* IN THE SOFTWARE.
*/

#ifdef USE_SYSTEM_SQLITE
#include <sqlite3.h>
#else
#include "sqlite3.h"
#endif
#include <janet.h>

#define FLAG_CLOSED 1

#define MSG_DB_CLOSED "database already closed"

typedef struct {
    sqlite3* handle;
    int flags;
    int errcode;
} Db;

/* Close a db, noop if already closed */
static void closedb(Db *db) {
    if (!(db->flags & FLAG_CLOSED)) {
        db->flags |= FLAG_CLOSED;
        sqlite3_close_v2(db->handle);
    }
}

/* Called to garbage collect a sqlite3 connection */
static int gcsqlite(void *p, size_t s) {
    (void) s;
    Db *db = (Db *)p;
    closedb(db);
    return 0;
}

#if JANET_VERSION_MAJOR == 1 && JANET_VERSION_MINOR < 6
static Janet sql_conn_get(void *p, Janet key);
#else
static int sql_conn_get(void *p, Janet key, Janet *out);
#endif

static const JanetAbstractType sql_conn_type = {
    "sqlite3.connection",
    gcsqlite,
    NULL,
    sql_conn_get,
#ifdef JANET_ATEND_GET
    JANET_ATEND_GET
#endif
};

/* Open a new database connection */
static Janet sql_open(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);
    const char *filename = janet_getcstring(argv, 0);
    sqlite3 *conn;
    int status = sqlite3_open(filename, &conn);
    if (status != SQLITE_OK) {
        const uint8_t *msg = janet_cstring(sqlite3_errmsg(conn));
        sqlite3_close_v2(conn);
        janet_panics(msg);
    }
    Db *db = (Db *) janet_abstract(&sql_conn_type, sizeof(Db));
    db->handle = conn;
    db->flags = 0;
    /* 4 other funcs set this, for attribution purposes*/
    db->errcode = SQLITE_OK;
    return janet_wrap_abstract(db);
}

/* Close a database connection */
static Janet sql_close(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);
    Db *db = janet_getabstract(argv, 0, &sql_conn_type);
    closedb(db);
    return janet_wrap_nil();
}

/* Check for embedded NULL bytes */
static int has_null(const uint8_t *str, int32_t len) {
    while (len--) {
        if (!str[len])
            return 1;
    }
    return 0;
}

/* Get open connection from argv, panicking when closed */
static Db *getopendb(const Janet *argv, int32_t n) {
    Db *db = janet_getabstract(argv, n, &sql_conn_type);
    if (db->flags & FLAG_CLOSED) janet_panic(MSG_DB_CLOSED);
    return db;
}

/* Get sql from argv, panicking on embedded NULL */
static const uint8_t *getquery(const Janet *argv, int32_t n) {
    const uint8_t *query = janet_getstring(argv, n);
    if (has_null(query, janet_string_length(query))) {
        janet_panic("cannot have embedded NULL in sql statements");
    }
    return query;
}

/* Record connection's error for error-code and copy msg, since sqlite calls overwrite */
static const uint8_t *save_error(Db *db) {
    db->errcode = sqlite3_errcode(db->handle);
    return janet_cstring(sqlite3_errmsg(db->handle));
}

/* Bind a single parameter */
static int bind1(sqlite3_stmt *stmt, int index, Janet value, const char **msg) {
    int res;
    switch (janet_type(value)) {
        default:
            *msg = "invalid sql value";
            return SQLITE_MISMATCH;
        case JANET_NIL:
            res = sqlite3_bind_null(stmt, index);
            break;
        case JANET_BOOLEAN:
            res = sqlite3_bind_int(stmt, index, janet_unwrap_boolean(value));
            break;
        case JANET_NUMBER:
            res = sqlite3_bind_double(stmt, index, janet_unwrap_number(value));
            break;
        case JANET_STRING:
        case JANET_SYMBOL:
        case JANET_KEYWORD:
            {
                const uint8_t *str = janet_unwrap_string(value);
                int32_t len = janet_string_length(str);
                if (has_null(str, len)) {
                    *msg = "cannot have embedded nulls in text values";
                    return SQLITE_MISMATCH;
                } else {
                    res = sqlite3_bind_text(stmt, index, (const char *)str, len, SQLITE_STATIC);
                }
            }
            break;
        case JANET_BUFFER:
            {
                JanetBuffer *buffer = janet_unwrap_buffer(value);
                res = sqlite3_bind_blob(stmt, index, buffer->data, buffer->count, SQLITE_STATIC);
            }
            break;
#ifdef JANET_INT_TYPES
        case JANET_ABSTRACT:
            switch (janet_is_int(value)) {
                default:
                    *msg = "invalid sql value";
                    return SQLITE_MISMATCH;
                case JANET_INT_S64:
                    res = sqlite3_bind_int64(stmt, index, janet_unwrap_s64(value));
                    break;
                case JANET_INT_U64:
                    {
                        uint64_t u = janet_unwrap_u64(value);
                        if (u > INT64_MAX) {
                            *msg = "integer too large for sqlite";
                            return SQLITE_MISMATCH;
                        }
                        res = sqlite3_bind_int64(stmt, index, (sqlite3_int64) u);
                    }
                    break;
            }
            break;
#endif
    }
    if (res != SQLITE_OK) {
        sqlite3 *db = sqlite3_db_handle(stmt);
        *msg = sqlite3_errmsg(db);
    }
    return res;
}

/* Bind many parameters */
static int bindmany(sqlite3_stmt *stmt, Janet params, const char **msg) {
    /* parameters */
    const Janet *seq;
    const JanetKV *kvs;
    int32_t len, cap;
    int limitindex = sqlite3_bind_parameter_count(stmt);
    if (janet_indexed_view(params, &seq, &len)) {
        if (len > limitindex) {
            *msg = "invalid index in sql parameters";
            return SQLITE_RANGE;
        }
        for (int i = 0; i < len; i++) {
            int res = bind1(stmt, i + 1, seq[i], msg);
            if (res != SQLITE_OK) {
                return res;
            }
        }
    } else if (janet_dictionary_view(params, &kvs, &len, &cap)) {
        for (int i = 0; i < cap; i++) {
            int index = 0;
            switch (janet_type(kvs[i].key)) {
                default:
                    /* Will fail */
                    break;
                case JANET_NIL:
                    /* Will skip as nil keys indicate empty hash table slot */
                    continue;
                case JANET_NUMBER:
                    if (!janet_checkint(kvs[i].key)) break;
                    index = janet_unwrap_integer(kvs[i].key);
                    break;
                case JANET_KEYWORD:
                    {
                        /* Find named parameter's index for keyword, trying each prefix sqlite accepts */
                        const uint8_t *kw = janet_unwrap_keyword(kvs[i].key);
                        int32_t kwlen = janet_string_length(kw);
                        if (has_null(kw, kwlen)) break;
                        char buf[64];
                        char *name = (kwlen + 2 <= (int32_t) sizeof(buf)) ? buf : janet_smalloc(kwlen + 2);
                        memcpy(name + 1, kw, kwlen);
                        name[kwlen + 1] = '\0';
                        for (const char *prefix = ":@$"; *prefix && !index; prefix++) {
                            name[0] = *prefix;
                            index = sqlite3_bind_parameter_index(stmt, name);
                        }
                        if (name != buf) janet_sfree(name);
                    }
                    break;
                case JANET_STRING:
                case JANET_SYMBOL:
                    {
                        const uint8_t *s = janet_unwrap_string(kvs[i].key);
                        index = sqlite3_bind_parameter_index(
                                stmt,
                                (const char *)s);
                    }
                    break;
            }
            if (index <= 0 || index > limitindex) {
                *msg = "invalid index in sql parameters";
                return SQLITE_RANGE;
            }
            int res = bind1(stmt, index, kvs[i].value, msg);
            if (res != SQLITE_OK) {
                return res;
            }
        }
    } else {
        *msg = "invalid type for sql parameters";
        return SQLITE_MISMATCH;    
    }
    return SQLITE_OK;
}

/* Return error message unless stepping finished */
static const char *step_error(sqlite3_stmt *stmt, int status) {
    return (status == SQLITE_DONE) ? NULL : sqlite3_errmsg(sqlite3_db_handle(stmt));
}

/* Execute a statement but don't collect results */
static const char *execute(sqlite3_stmt *stmt) {
    int status;
    do {
        status = sqlite3_step(stmt);
    } while (status == SQLITE_ROW);
    return step_error(stmt, status);
}

/* Convert element/column of current row to Janet value */
static Janet column_value(sqlite3_stmt *stmt, int i) {
    switch (sqlite3_column_type(stmt, i)) {
        case SQLITE_NULL:
            return janet_wrap_nil();
        case SQLITE_INTEGER:
            return janet_wrap_number((double) sqlite3_column_int64(stmt, i));
        case SQLITE_FLOAT:
            return janet_wrap_number(sqlite3_column_double(stmt, i));
        case SQLITE_TEXT:
            {
                const uint8_t *text = sqlite3_column_text(stmt, i);
                int nbytes = sqlite3_column_bytes(stmt, i);
                return janet_stringv(text, nbytes);
            }
        case SQLITE_BLOB:
            {
                const void *blob = sqlite3_column_blob(stmt, i);
                int nbytes = sqlite3_column_bytes(stmt, i);
                JanetBuffer *b = janet_buffer(nbytes);
                if (nbytes) memcpy(b->data, blob, nbytes);
                b->count = nbytes;
                return janet_wrap_buffer(b);
            }
    }
    return janet_wrap_nil();
}

/* Execute and return values from prepared statement */
static const char *execute_collect(sqlite3_stmt *stmt, JanetArray *rows) {
    /* Count number of columns in result */
    int ncol = sqlite3_column_count(stmt);
    int status;

    /* Get column names */
    Janet *tupstart = janet_tuple_begin(ncol);
    for (int i = 0; i < ncol; i++) {
        tupstart[i] = janet_ckeywordv(sqlite3_column_name(stmt, i));
    }
    const Janet *colnames = janet_tuple_end(tupstart);

    do {
        status = sqlite3_step(stmt);
        if (status == SQLITE_ROW) {
            JanetKV *row = janet_struct_begin(ncol);
            for (int i = 0; i < ncol; i++) {
                janet_struct_put(row, colnames[i], column_value(stmt, i));
            }
            janet_array_push(rows, janet_wrap_struct(janet_struct_end(row)));
        }
    } while (status == SQLITE_ROW);
    return step_error(stmt, status);
}

/* Return columns from executing statement */
static const char *execute_collect_to_dataframe(sqlite3_stmt *stmt, JanetTable *cols) {
    /* Count number of columns in result */
    int ncol = sqlite3_column_count(stmt);
    int status;

    /* Key one array per column */
    JanetArray **vecs = janet_smalloc(sizeof(JanetArray *) * ncol);
    for (int i = 0; i < ncol; i++) {
        Janet name = janet_ckeywordv(sqlite3_column_name(stmt, i));
        vecs[i] = janet_array(0);
        janet_table_put(cols, name, janet_wrap_array(vecs[i]));
    }
    do {
        status = sqlite3_step(stmt);
        if (status == SQLITE_ROW) {
            for (int i = 0; i < ncol; i++) {
                janet_array_push(vecs[i], column_value(stmt, i));
            }
        }
    } while (status == SQLITE_ROW);
    janet_sfree(vecs);
    return step_error(stmt, status);
}

typedef enum { COLLECT_ROWS, COLLECT_TO_DF } CollectMode;

/* Evaluate sql string, collecting the final result to the target shape */
static Janet sql_eval_impl(int32_t argc, Janet *argv, CollectMode mode) {
    janet_arity(argc, 2, 3);
    const uint8_t *err;
    sqlite3_stmt *stmt = NULL;
    Db *db = getopendb(argv, 0);
    db->errcode = SQLITE_OK;
    const uint8_t *query = getquery(argv, 1);
    JanetArray *rows = (mode == COLLECT_ROWS)  ? janet_array(0) : NULL;
    JanetTable *cols = (mode == COLLECT_TO_DF) ? janet_table(0) : NULL;
    const char *c = (const char *)query;
    const char *end = c + janet_string_length(query) + 1;
    int has_params = argc == 3 && !janet_checktype(argv[2], JANET_NIL);

    /* Evaluate all statements in a loop */
    while (*c) {
        /* Compile the next statement */
        if (sqlite3_prepare_v2(db->handle, c, (int)(end - c), &stmt, &c) != SQLITE_OK) {
            janet_panics(save_error(db));        
        }
        /* Trailing whitespace and comments compile to no statement */
        if (NULL == stmt) break;
        const char *berr = NULL;
        if (has_params) {
            int res = bindmany(stmt, argv[2], &berr);
            if (res != SQLITE_OK) { db->errcode = res; err = janet_cstring(berr); goto error; }
        }
        /* Only returning last statement's result */
        if (mode == COLLECT_TO_DF) {
            cols = janet_table(0);
            berr = execute_collect_to_dataframe(stmt, cols);
        } else {
            rows = janet_array(10);
            berr = execute_collect(stmt, rows);
        }
        if (berr) { err = save_error(db); goto error; }
        sqlite3_finalize(stmt);
    }
    /* Good return path */
    return (mode == COLLECT_TO_DF) ? janet_wrap_table(cols) : janet_wrap_array(rows);

error:
    sqlite3_finalize(stmt);
    janet_panics(err);
    return janet_wrap_nil();
}

static Janet sql_eval(int32_t argc, Janet *argv) {
    return sql_eval_impl(argc, argv, COLLECT_ROWS);
}

static Janet sql_eval_to_dataframe(int32_t argc, Janet *argv) {
    return sql_eval_impl(argc, argv, COLLECT_TO_DF);
}

/* Execute statement repeatedly against parameter set */
static Janet sql_eval_many(int32_t argc, Janet *argv) {
    janet_arity(argc, 3, 4);
    const uint8_t *err;
    sqlite3_stmt *stmt = NULL, *stmt_extra = NULL;
    Db *db = getopendb(argv, 0);
    db->errcode = SQLITE_OK;
    const uint8_t *query = getquery(argv, 1);
    const Janet *sets;
    int32_t nsets;
    if (!janet_indexed_view(argv[2], &sets, &nsets)) {
        janet_panic("expected array or tuple of parameter sets");
    }

    int keep_partial = 0;
    if (argc == 4 && !janet_checktype(argv[3], JANET_NIL)) {
        if (!janet_keyeq(argv[3], "keep-partial")) janet_panicf("expected :keep-partial, got %v", argv[3]);
        keep_partial = 1;
    }

    const char *c = (const char *)query;
    const char *end = c + janet_string_length(query) + 1;
    if (sqlite3_prepare_v2(db->handle, c, (int)(end - c), &stmt, &c) != SQLITE_OK) {
        janet_panics(save_error(db));
    }
    if (NULL == stmt) janet_panic("expected a sql statement");
    /* Trailing whitespace and comments compile to no statement */
    if (sqlite3_prepare_v2(db->handle, c, (int)(end - c), &stmt_extra, &c) != SQLITE_OK) {
        err = save_error(db);
        goto error;
    }
    if (NULL != stmt_extra) {
        err = janet_cstring("expected only one sql statement");
        goto error;
    }

    /* savepoint starts transaction when not in one and nests when inside one */
    if (sqlite3_exec(db->handle, "SAVEPOINT eval_many;", NULL, NULL, NULL) != SQLITE_OK) {
        err = save_error(db);
        goto error;
    }

    for (int32_t i = 0; i < nsets; i++) {
        const char *berr;
        int res = bindmany(stmt, sets[i], &berr);
        if (res != SQLITE_OK) { db->errcode = res; err = janet_cstring(berr); goto rollback;}
        if (execute(stmt)) { err = save_error(db); goto rollback;}
        if (sqlite3_reset(stmt) != SQLITE_OK) {
            err = save_error(db);
            goto rollback;
        }
        /* No check, on every non-NULL statement it returns SQLITE_OK https://github.com/sqlite/sqlite/blob/f544d3599a10b95aa3ee8f8c1fd182f6a2fc2798/src/vdbeapi.c#L157
         * No failure modes given https://www.sqlite.org/c3ref/clear_bindings.html */
        sqlite3_clear_bindings(stmt);
    }

    if (sqlite3_exec(db->handle, "RELEASE eval_many;", NULL, NULL, NULL) != SQLITE_OK) {
        err = save_error(db);
        goto rollback;
    }
    sqlite3_finalize(stmt);
    return janet_wrap_nil();

rollback:
    /* If RELEASE fails (e.g. for SQLITE_BUSY), the transaction's still open, so we rollback */
    if (!keep_partial || sqlite3_exec(db->handle, "RELEASE eval_many;", NULL, NULL, NULL) != SQLITE_OK) {
        sqlite3_exec(db->handle, "ROLLBACK TO eval_many; RELEASE eval_many;", NULL, NULL, NULL);
    }
error:
    sqlite3_finalize(stmt);
    sqlite3_finalize(stmt_extra);
    janet_panics(err);
    return janet_wrap_nil();
}

/* Gets the last inserted row id */
static Janet sql_last_insert_rowid(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);
    Db *db = getopendb(argv, 0);
    sqlite3_int64 id = sqlite3_last_insert_rowid(db->handle);
    return janet_wrap_number((double) id);
}

/* Get the sqlite3 errcode */
static Janet sql_error_code(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);
    Db *db = getopendb(argv, 0);
    return janet_wrap_integer(db->errcode);
}

/* Toggle or report whether extension loading is allowed */
static Janet sql_allow_loading_extensions(int32_t argc, Janet *argv) {
    janet_arity(argc, 1, 2);
    Db *db = getopendb(argv, 0);
    db->errcode = SQLITE_OK;
    int enable_loading = janet_optboolean(argv, argc, 1, -1);
    int setting;
    int status = sqlite3_db_config(db->handle, SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION, enable_loading, &setting);
    if (status != SQLITE_OK) {
        db->errcode = status;
        janet_panic(sqlite3_errstr(status));
    }
    return janet_wrap_boolean(setting);
}

/* Load extension */
static Janet sql_load_extension(int32_t argc, Janet *argv) {
    janet_arity(argc, 2, 3);
    Db *db = getopendb(argv, 0);
    db->errcode = SQLITE_OK;
    const char *zFile = janet_getcstring(argv, 1);
    const char *zProc = janet_optcstring(argv, argc, 2, NULL);
    char *pzErrMsg = NULL;
    int status = sqlite3_load_extension(db->handle, zFile, zProc, &pzErrMsg);
    if (status != SQLITE_OK) {
        db->errcode = status;
        const uint8_t *jErrMsg = janet_cstring(pzErrMsg ? pzErrMsg : sqlite3_errstr(status));
        sqlite3_free(pzErrMsg);
        janet_panics(jErrMsg);
    }
    return argv[1];
}

static JanetMethod conn_methods[] = {
    {"error-code", sql_error_code},
    {"close", sql_close},
    {"eval", sql_eval},
    {"eval-to-dataframe", sql_eval_to_dataframe},
    {"last-insert-rowid", sql_last_insert_rowid},
    {"allow-loading-extensions", sql_allow_loading_extensions},
    {"load-extension", sql_load_extension},
    {"eval-many", sql_eval_many},
    {NULL, NULL}
};

#if JANET_VERSION_MAJOR == 1 && JANET_VERSION_MINOR < 6
static Janet sql_conn_get(void *p, Janet key) {
    (void) p;
    if (!janet_checktype(key, JANET_KEYWORD)) {
        janet_panicf("expected keyword, get %v", key);
    }
    return janet_getmethod(janet_unwrap_keyword(key), conn_methods);
}
#else
static int sql_conn_get(void *p, Janet key, Janet *out) {
    (void) p;
    if (!janet_checktype(key, JANET_KEYWORD)) {
        janet_panicf("expected keyword, get %v", key);
    }
    return janet_getmethod(janet_unwrap_keyword(key), conn_methods, out);
}
#endif

/*****************************************************************************/

static const JanetReg cfuns[] = {
    {"open", sql_open, 
        "(sqlite3/open path)\n\n"
        "Opens a sqlite3 database on disk or in-memory when passed \":memory:\" as path. Returns the database handle if the database was opened "
        "successfully, and otherwise throws an error."
    },
    {"close", sql_close, 
        "(sqlite3/close db)\n\n"
        "Closes a database. Use this to free a database after use. Returns nil."
    },
    {"eval-to-dataframe", sql_eval_to_dataframe,
        "(sqlite3/eval-to-dataframe db sql [,params])\n\n"
        "Evaluate sql like (sqlite3/eval ...), but return results as columnar dataframe: a "
        "table mapping each column name (a keyword) to an array of that column's values. "
        "Columns are present even when no rows match, so the result is usable directly."
        "If two result columns share a name the later overwrites the former."
    },
    {"eval", sql_eval, 
        "(sqlite3/eval db sql [,params])\n\n"
        "Evaluate sql in the context of database db. Multiple sql statements "
        "can be chained together, and optionally parameters maybe passed in. "
        "The optional parameters maybe either an indexed data type (tuple or array), or a dictionary "
        "data type (struct or table). If params is a tuple or array, then sqlite "
        "parameters are substituted using indices. For example:\n\n"
        "\t(sqlite3/eval db `SELECT * FROM tab WHERE id = ?;` [123])\n\n"
        "Will select rows from tab where id is equal to 123. Alternatively, "
        "the programmer can use named parameters with tables or structs, like so:\n\n"
        "\t(sqlite3/eval db `SELECT * FROM tab WHERE id = :id;` {:id 123})\n\n"
        "Will return an array of rows, where each row contains a table where columns names "
        "are keys for column values.\n\n"
        "Ints are returned as Janet numbers, rounding above 2^53. To read them `select` with "
        "`CAST(col AS TEXT)` and parse with `int/s64` to read them exactly. "
        "A nil param's the same as none."
    },
    {"last-insert-rowid", sql_last_insert_rowid, 
        "(sqlite3/last-insert-rowid db)\n\n"
        "Returns the id of the last inserted row."
    },
    {"error-code", sql_error_code,
        "(sqlite3/error-code db)\n\n"
        "Returns the error number of the last sqlite3 command that threw an error. "
        "Errors binding params report SQLITE_RANGE (25) for no match "
        "and SQLITE_MISMATCH (20) for values sqlite can't store. Cross "
        "check these numbers with the SQLite documentation for more information."
    },
    {"allow-loading-extensions", sql_allow_loading_extensions,
        "(sqlite3/allow-loading-extensions db [boolean-param])\n\n"
        "Reports or toggles the setting to load SQLite extensions according to presence and value "
        "of boolean-param. Returns a boolean value indicating whether extension loading is allowed."
    },
    {"load-extension", sql_load_extension,
        "(sqlite3/load-extension db library-file-path [library-entrypoint])\n\n"
        "Loads the SQLite extension library from library-file-path, optionally specifying "
        "the library-entrypoint. Extension loading must be enabled prior to calling this function. "
        "Returns library-file-path."
    },
    {"eval-many", sql_eval_many,
        "(sqlite3/eval-many db sql param-sets &opt :keep-partial)\n\n"
        "Evaluates an sql statement once per element of param-sets (like map) "
        "only preparing statement once, binding arguments like the params argument of "
        "(sqlite3/eval ...); both indexed and named parameters work. All executions "
        "run inside a savepoint (equivalent to a transaction) where any error rolls it back "
        "unless given `:keep-partial`. The purpose is bulk writes, so it returns nil.\n\n"
        "  * (sqlite3/eval-many db \"INSERT INTO tracks VALUES (?, ?, ?);\"\n"
        "        (map tuple (tracks :title) (tracks :bpm) (tracks :gain_db)))\n"
    },
    {NULL, NULL, NULL}
};

JANET_MODULE_ENTRY(JanetTable *env) {
    janet_cfuns(env, "sqlite3", cfuns);
}