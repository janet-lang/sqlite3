(declare-project
  :name "sqlite3"
  :author "Calvin Rose"
  :license "MIT"
  :url "https://github.com/janet-lang/sqlite3"
  :repo "git+https://github.com/janet-lang/sqlite3.git")

(declare-native
    :name "sqlite3"
    :source @["sqlite3.c" "main.c"])

(sh-phony "update-sqlite3" []
    (print "updating sqlite3 local libs ...")
    (os/shell "janet dl-sqlite3"))
