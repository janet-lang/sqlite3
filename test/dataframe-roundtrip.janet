(import ../build/sqlite3 :as sql)

(let [path    "roundtrip.db"
      _       (when (os/stat path) (os/rm path))
      tracks @{:title @["axiom" "briar" "cinder" "dune" "ember" "fjord"]
               :bpm @[122 98 140 87 133 104]
               :gain_db @[-6.5 -3.25 0.0 -12.75 2.5 -0.125]}
      db      (sql/open path)]

  (defer (os/rm path)
         (defer (sql/close db)
                (sql/eval db "CREATE TABLE tracks (title TEXT, bpm INTEGER, gain_db REAL);
              CREATE TABLE mirror (title TEXT, bpm INTEGER, gain_db REAL);")

                # to and from tracks
                (sql/eval-many db "INSERT INTO tracks VALUES (?, ?, ?);"
                               (map tuple (in tracks :title) (in tracks :bpm) (in tracks :gain_db)))
                (def once (sql/eval-to-dataframe db "SELECT * FROM tracks ORDER BY title;"))
                # to and from mirroir
                (sql/eval-many db "INSERT INTO mirror VALUES (?, ?, ?);"
                               (map tuple (in once :title) (in once :bpm) (in once :gain_db)))
                (def twice (sql/eval-to-dataframe db "SELECT * FROM mirror ORDER BY title;"))

                (assert (deep= once twice)) # both are identical
                (assert (deep= twice @{:title @["axiom" "briar" "cinder" "dune" "ember" "fjord"]
                                       :bpm @[122 98 140 87 133 104]
                                       :gain_db @[-6.5 -3.25 0.0 -12.75 2.5 -0.125]}))
                (assert (deep= once tracks)) # the actual round trip, tracks defined in top let
                )))