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
    (assert (= 2 (length (sql/eval db `SELECT * FROM t;`))) ":keep-partial keeps the sets before the failing one")))

(let [db (sql/open ":memory:")]
  (defer (sql/close db)
    (sql/eval db `CREATE TABLE t(x); INSERT INTO t VALUES (1);`)
    (assert (deep= @[{:x 1}] (sql/eval db `SELECT x FROM t;`))
            "Statements see the schema changes of prior statements")))
(let [db (sql/open ":memory:")]
  (defer (sql/close db)
    (let [[ok err] (protect (sql/eval db `SELECT ?;` [1 2]))]
      (assert (and (not ok) (= err "invalid index in sql parameters"))
              "Additional positional parameters didn't get rejected before binding"))))

