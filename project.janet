(declare-project
  :name "sqlite3"
  :description "Janet bindings to SQLite."
  :author "Calvin Rose"
  :license "MIT"
  :url "https://github.com/janet-lang/sqlite3"
  :repo "git+https://github.com/janet-lang/sqlite3.git")


(def use-system-lib (= "1" (os/getenv "JANET_SYSTEM_SQLITE" 0)))

(defn pkg-config [what &opt env]
  (default env {})
  (def p (os/spawn ["pkg-config" ;what] :p (merge {:out :pipe} env)))
  (:wait p)
  (unless (zero? (p :return-code))
    (error "pkg-config failed!"))
  (def v (->>
           (:read (p :out) :all)
           (string/trim)
           (string/split " ")))
  v)

(if use-system-lib
  (declare-native
    :name "sqlite3"
    :cflags (pkg-config ["sqlite3" "--cflags"]
                        {"PKG_CONFIG_ALLOW_SYSTEM_CFLAGS" "1"})
    :lflags (pkg-config ["sqlite3" "--libs"])
    :source @["main.c"]
    :defines {"USE_SYSTEM_SQLITE" use-system-lib})
  (declare-native
    :name "sqlite3"
    :source @["sqlite3.c" "main.c"])
)

(sh-phony "update-sqlite3" []
    (print "updating sqlite3 local libs ...")
    (os/shell "janet dl-sqlite3"))
