# SQLite bindings

This native module proves sqlite bindings for janet.

## Install

```
jpm install sqlite3
```

## Building

To build, use the `jpm` tool and make sure you have janet installed.

```
jpm build
```
## Using the System's SQLite library

Usually, a Linux system has a package for SQLite installed globally.
This packages will usually have many plugins for SQlite enabled (e.g
JSON1, FTS3 etc.). The [Debian package][1] or [Gentoo ebuild][2] are good examples.

This package allows one to use it instead of the SQLite sources included with the package.
To do this use:

```
export JANET_SYSTEM_SQLITE=1
jpm build
```

Note, if you intead to install the package globally, use:

```
sudo -E jpm build
```

## Update the embedded SQLite version

You can use the jpm rule to update the version of SQLite included.
```
jpm run update-sqlite3
```

You can find the latest version https://sqlite.org/index.html.

## Example Usage

Next, enter the repl and create a database and a table.
By default, the generated module will be in the build folder.

```
janet:1:> (import build/sqlite3 :as sql)
nil
janet:2:> (def db (sql/open "test.db"))
<sqlite3.connection 0x5561A138C470>
janet:3:> (sql/eval db `CREATE TABLE customers(id INTEGER PRIMARY KEY, name TEXT);`)
@[]
janet:4:> (sql/eval db `INSERT INTO customers VALUES(:id, :name);` {:name "John" :id 12345})
@[]
janet:5:> (sql/eval db `SELECT * FROM customers;`)
@[{"id" 12345 "name" "John"}]
```

Load and use SQLite extensions.

```
janet:6:> (sql/allow-loading-extensions db)
false
janet:7:> (sql/load-extension db "/tmp/base64")
error: not authorized
  in sqlite3/load-extension
  in _thunk [janet] (tailcall) on line 4, column 1
janet:8:> (sql/allow-loading-extensions db true)
true
janet:9:> (sql/load-extension db "/tmp/base64")
"/tmp/base64"
janet:10:> (sql/eval db "select base64('YWJjMTIz') as b64")
@[{:b64 @"abc123"}]
```

Finally, close the database connection when done with it.

```
janet:11:> (sql/close db)
nil
```

[1]: https://git.launchpad.net/ubuntu/+source/sqlite3/tree/debian/rules?h=debian/sid#n41
[2]: https://github.com/gentoo/gentoo/blob/653b190ffe5f4433112ad6786d1bfd2e26143711/dev-db/sqlite/sqlite-3.34.0.ebuild

## Dataframe Example

2x faster than `eval` for reads, `eval-to-dataframe` returns a dataframe (e.g. `{:name ["Bob" "Janet" "Jack"] :age [25 22 31]}`). For bulk writes, `eval-many` runs a single SQL statement in a transaction, (4x faster than `eval` with a transaction.)

```janet
(sqlite3/eval-many db "INSERT INTO f VALUES (?, ?, ?);"
  @[["a.c" "c" 120]
    ["b.h" "h" 40]
    ["Makefile" "" 300]])

(sqlite3/eval-many db "INSERT INTO f VALUES (:path, :ext, :size);"
  @[{:path "a.c" :ext "c" :size 120}
    {:path "b.h" :ext "h" :size 40}
    {:path "Makefile" :ext "" :size 300}])
```
Here is a cute, self-contained program printing number of files ordered by size (use like `janet a.janet my-dir`):

```janet
(import sqlite3)

(defn walk-dir
  "Return [path ext size] for every regular file under dir, recursing."
  [dir]
  (mapcat
    (fn [name]
      (let [path (string dir "/" name)
            st   (os/lstat path)]
        (case (get st :mode)
          :file      [[path
                       (if-let [i (string/find-all "." name)
                                j (last i)]
                         (string/slice name (inc j)) "")
                       (in st :size)]]
          :directory (walk-dir path)
          [])))
    (os/dir dir)))

(let [root  (get (dyn :args) 1 ".")
      path  "usage.db"
      files (walk-dir root)]
  (when   (os/stat path) (os/rm path))
  (os/execute ["sqlite3" path "CREATE TABLE f (path TEXT, ext TEXT, size INTEGER);"] :px)
  (def db (sqlite3/open path))
  (defer   (os/rm path)
    (defer (sqlite3/close db)
      (sqlite3/eval-many db "INSERT INTO f VALUES (?, ?, ?);" files)
      (let [agg (sqlite3/eval-to-dataframe db
                  "SELECT ext, count(*) AS n, sum(size) AS bytes
                   FROM f GROUP BY ext ORDER BY bytes DESC;")
            # sqlite struggles, but columns excel at cumulative share
            total (sum (in agg :bytes))
            cum (accumulate + 0 (map |(/ $ total) (in agg :bytes)))]
        (printf "%d files, %.1f MB under %s" (length files) (/ total 1e6) root)
        (eachp [i ext] (in agg :ext)
          (printf "%10s %7d files %10.2f MB  %5.1f%% cum"
                  (if (empty? ext) "<none>" ext)
                  (in (in agg :n) i)
                  (/ (in (in agg :bytes) i) 1e6)
                  (* 100 (in cum i))))))))
```