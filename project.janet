(declare-project
  :name "sqlite3"
  :author "Calvin Rose"
  :license "MIT"
  :url "https://github.com/janet-lang/sqlite3"
  :repo "git+https://github.com/janet-lang/sqlite3.git")


(def use-system-lib (= "1" (os/getenv "USE_SYSTEM_SQLITE" 0)))

(defn pkg-config [what]
  (def f (file/popen (string "pkg-config " what)))
  (def v (->>
           (file/read f :all)
           (string/trim)
           (string/split " ")))
  (unless (zero? (file/close f))
    (error "pkg-config failed!"))
  v)

(if use-system-lib
  (declare-native
    :name "sqlite3"
    :cflags (pkg-config "--keep-system-cflags sqlite3 --cflags")
    :lflags (pkg-config "sqlite3 --libs")
    :source @["main.c"]
    :defines {"USE_SYSTEM_SQLITE" use-system-lib})
  (declare-native
    :name "sqlite3"
    :source @["sqlite3.c" "main.c"])
)

(sh-phony "update-sqlite3" []
    (print "updating sqlite3 local libs ...")
    (os/shell "janet dl-sqlite3"))
