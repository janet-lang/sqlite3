(import ../build/sqlite3 :as sql)

(let [path   "test.db" 
      _      (when (os/stat path) (os/rm path))
      db     (sql/open path)]
  (defer (os/rm path)
    (defer (sql/close db) 
           (sql/eval db `CREATE TABLE people(name TEXT, age INTEGER, bool INTEGER);`)
           (sql/eval db `INSERT INTO people values(:name, :age, :bool)` {:name "John" :age 20 :bool false})
           (sql/eval db `INSERT INTO people values(:name, :age, :bool)` {:name "Paul" :age 30 :bool true})
           (sql/eval db `INSERT INTO people values(:name, :age, :bool)` {:name "Bob" :age 40 :bool false})
           (sql/eval db `INSERT INTO people values(:name, :age, :bool)` {:name "Joe" :age 50 :bool true})
           (def results (sql/eval db `SELECT * FROM people`))
           (assert (= (length results) 4))
           
           (def update-result
             (-> (sql/eval db
                           `UPDATE people set name = :new_name where name = :old_name RETURNING name, age, bool`
                           {:new_name "Harry" :old_name "Paul"})
                 (first)))
           (assert (deep= update-result {:name "Harry" :age 30 :bool 1})))))

(let [db (sql/open ":memory:")]
  (defer (sql/close db)
    (sql/eval db `CREATE TABLE t (id INTEGER PRIMARY KEY);`)
    (protect (sql/eval-many db `INSERT INTO t VALUES (?);` [[1] [2] [1] [3]] :keep-partial)) # fails from repeated key, 3 not inserted
    (assert (= 2 (length (sql/eval db `SELECT * FROM t;`))) ":keep-partial didn't keep sets before failing one")))

(let [db (sql/open ":memory:")]
  (defer (sql/close db)
    (sql/eval db `CREATE TABLE t(x); INSERT INTO t VALUES (1);`)
    (assert (deep= @[{:x 1}] (sql/eval db `SELECT x FROM t;`))
            "Statements didn't see the schema changes of prior statements")))

(let [db (sql/open ":memory:")]
  (defer (sql/close db)
    (let [[ok err] (protect (sql/eval db `SELECT ?;` [1 2]))]
      (assert (and (not ok) (= err "invalid index in sql parameters"))
              "Additional positional parameters didn't get rejected before binding"))))

(let [db (sql/open ":memory:")]
  (defer (sql/close db)
    (assert (deep= @[{:a 1 :b 2 :c 3}]
                   (sql/eval db `SELECT :a AS a, @b AS b, $c AS c;` {:a 1 :b 2 :c 3}))
            "keyword keys didn't bind parameters with any sqlite prefix")))

(let [db (sql/open ":memory:")]
  (defer (sql/close db)
    (assert (deep= @[{:same 1}]
                   (sql/eval db `SELECT ? = 9007199254740993 AS same;` [(int/s64 "9007199254740993")]))
            "int/s64 values don' convert to sqlite integers")
    (assert (deep= @[{:same 1}]
                   (sql/eval db `SELECT ? = 9007199254740993 AS same;` [(int/u64 "9007199254740993")]))
            "int/u64 values within int64 don't convert to sqlite integers")
    (let [[ok err] (protect (sql/eval db `SELECT ?;` [(int/u64 "18446744073709551615")]))]
      (assert (and (not ok) (= err "integer too large for sqlite"))
              "int/u64 values beyond int64 should not be accepted (Sqlite wants us under INT64_MAX)"))))

(let [db (sql/open ":memory:")]
  (defer (sql/close db)
    (assert (deep= @[{:a 1}] (sql/eval db `SELECT 1 AS a;` nil)) "nil params didn't mean no params")
    (defn select-one [&opt params] (sql/eval db `SELECT 1 AS a;` params))
    (assert (deep= @[{:a 1}] (select-one)) "forwarded &opt params didn't mean no params")))

(let [db (sql/open ":memory:")]
  (defer (sql/close db)
    (sql/eval db `CREATE TABLE t (id INTEGER PRIMARY KEY);`)
    (protect (sql/eval-many db `INSERT INTO t VALUES (?);` [[1] [1]]))
    (assert (= 19 (sql/error-code db)) "rollback erased constraint failure's code")
    (protect (sql/eval-many db `INSERT INTO t VALUES (?);` [[2] [2]] :keep-partial))
    (assert (= 19 (sql/error-code db)) "release erased constraint failure's code")
    (protect (sql/eval db `SELECT ?;` [1 2]))
    (assert (= 25 (sql/error-code db)) "unmatched param didn't output SQLITE_RANGE")
    (protect (sql/eval db `SELECT ?;` [@{}]))
    (assert (= 20 (sql/error-code db)) "unstorable value didn't report SQLITE_MISMATCH")))

(let [path "busy.db"]
  (when (os/stat path) (os/rm path))
  (let [holder (sql/open path)
        writer (sql/open path)]
    (defer (os/rm path)
      (defer (do (sql/close holder) (sql/close writer))
        (sql/eval holder `CREATE TABLE t(x);`)
        (sql/eval holder `BEGIN IMMEDIATE;`)
        (let [[ok err] (protect (sql/eval-many writer `INSERT INTO t VALUES (?);` [[1]]))]
          (assert (and (not ok) (= err "database is locked")) "writing under another connection's lock didn't fail"))
        (assert (= 5 (sql/error-code writer)) "eval-many's rollback masked/erased SQLITE_BUSY")))))