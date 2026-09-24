(import ../build/sqlite3 :as sql)

(defmacro timed `Return [seconds result]`
  [& body]
  (with-syms [t0 res]
    ~(let [,t0 (os/clock :monotonic)
           ,res (do ,;body)]
       [(- (os/clock :monotonic) ,t0) ,res])))

(let [path   "bench.db"
      _      (when (os/stat path) (os/rm path))
      n      20000
      ids    (seq [i :range [0 n]] i)
      names  (seq [i :range [0 n]] (string "user-" i))
      scores (seq [i :range [0 n]] (* 0.25 (- i (/ n 2))))
      flags  (seq [i :range [0 n]] (mod i 2))
      src   @{:id ids :name names :score scores :flag flags}] 
  (defer (os/rm path)
         (def db (sql/open path))
    (defer (sql/close db)
           (sql/eval  db   "CREATE TABLE bulk (id INTEGER, name TEXT, score REAL, flag INTEGER);
                            CREATE TABLE rows (id INTEGER, name TEXT, score REAL, flag INTEGER);")
      (let [[insert-a _]    (timed (sql/eval-many db "INSERT INTO bulk VALUES (?, ?, ?, ?);"
                                                  (map tuple ids names scores flags)))
            [read-a df-a]   (timed (sql/eval-to-dataframe db "SELECT * FROM bulk ORDER BY id;"))
            [insert-b _]    (timed
                             (sql/eval db "BEGIN;") # extremely slow without this
                             (loop [i :range [0 n]]
                               (sql/eval db "INSERT INTO rows VALUES (:id, :name, :score, :flag);"
                                         {:id    (in ids    i) :name (in names i)
                                          :score (in scores i) :flag (in flags i)}))
                             (sql/eval db "COMMIT;"))
            [read-b rows-b] (timed (sql/eval db "SELECT * FROM rows ORDER BY id;"))] 
        (assert (= n (length rows-b) (length (df-a :name))))
        (printf "a eval-many insert: %.4f s" insert-a)
        (printf "b per-row insert:   %.4f s  (%.1fx)" insert-b (/ insert-b insert-a))
        (printf "a dataframe read:   %.4f s" read-a)
        (printf "b row-seq read:     %.4f s  (%.1fx)" read-b   (/ read-b read-a))))))