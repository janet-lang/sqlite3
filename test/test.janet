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
    (each [x t] [[1 "integer"] [(math/pow 2 60) "integer"] [1.5 "real"] [1e300 "real"]]
      (assert (deep= @[{:t t}] (sql/eval db `SELECT typeof(?) AS t;` [x]))
              (string/format "%q didn't bind as %s" x t)))
    (sql/eval db `CREATE TABLE t(s TEXT); `)
    (sql/eval db `INSERT INTO t VALUES (?);` [42])
    (assert (deep= @[{:s "42"}] (sql/eval db `SELECT s FROM t;`)) "TEXT col stored integral number with .0")
    (assert (= 1 (length (sql/eval db `SELECT s FROM t WHERE s = ?;` [42]))) "integral number didn't match text")))