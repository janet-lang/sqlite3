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

# (let [db (sql/open ":memory:")]
#   (defer (sql/close db)
#     (sql/eval db `CREATE TABLE t(s TEXT); INSERT INTO t VALUES ('42');`)
#     (assert (= 1 (length (sql/eval db `SELECT s FROM t WHERE s = ?;` [42])))
#             "42 bound as 42.0 and missed a \"42\" row")))
#
# This establishes a contract re: bind1's case JANET_NUMBER: 
# I previously tried changing integral numbers'
# representations so a Janet 42 wouldn't become a TEXT "42.0" so
# `where s = ?` given 42 wouldn't make it "42.0" and then miss actual "42"
# however this causes other correctness errors/breaking change
# where (db/val "select ? / ?" 7 2) returned 3, instead of 3.5 (before and now).
# I believe keeping "42.0" is better, because it's more predictable.
(let [db (sql/open ":memory:")]
  (defer (sql/close db)
    (assert (deep= @[{:v 3.5}] (sql/eval db `SELECT ? / ? AS v;` [7 2])) "integral numbers didn't bind as REAL")
    (assert (deep= @[{:v 3}] (sql/eval db `SELECT ? / ? AS v;` [(int/s64 7) (int/s64 2)])) "int/s64 didn't bind as INTEGER")
    (sql/eval db `CREATE TABLE t(s TEXT);`)
    (sql/eval db `INSERT INTO t VALUES (?), (?);` [42 (int/s64 42)])
    (assert (deep= @[{:s "42.0"} {:s "42"}] (sql/eval db `SELECT s FROM t;`)) "TEXT storage of numbers changed")))