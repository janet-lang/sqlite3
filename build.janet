(import cook)

(cook/make-native
    :name "sqlite3"
    :source @["sqlite3.c" "main.c"])
