(import /build/sqlite3 :as sql)

#
# Testing
#

(defn assert [c]
  (if (not c) (error "failed assertion")))
(def db (sql/open "build/test.db"))
(try (sql/eval db `DROP TABLE people`) ([_]))
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
(assert (= update-result {:name "Harry" :age 30 :bool 1}))


(sql/close db)
