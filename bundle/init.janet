(defn build [&]
  (os/mkdir "build")
  (os/execute ["cc" "-O2" "-fPIC" "-shared" (string "-I" (dyn *syspath*) "/../../include")
               "sqlite3.c" "main.c" "-o" "build/sqlite3.so"] :px))

(defn install [manifest &]
  (bundle/add-file manifest "build/sqlite3.so" "sqlite3.so"))

(defn check [&]
  (each f (os/dir "test")
    (os/execute [(dyn *executable*) (string "test/" f)] :px)))

(defn clean [&]  (os/rm "build/sqlite3.so"))