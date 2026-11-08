;; A shared note for the room: /note, /note <text>, /note clear.
;; trigger: command  { name = "note" }
;;
;; Shows how a script remembers something between messages. Anything it keeps
;; expires on its own, a day from now unless you say otherwise.
(local key (.. "note:" (rubotty.room_key)))
(local week (* 7 24 60 60))

(if (= (rubotty.args) "")
    ;; Read back what we kept, or nil if it has gone.
    (let [existing (rubotty.recall {:key key})]
      (if existing (.. "Note: " existing) "No note set. Try /note <something>."))

    (= (rubotty.args) "clear")
    ;; Drop what we kept.
    (do (rubotty.forget {:key key}) "Note cleared.")

    ;; remember returns false at the key cap rather than evicting something
    ;; older, so a rule can see the write failed instead of silently losing it.
    (rubotty.remember {:key key :value (rubotty.args) :ttl week})
    "Noted, for a week."

    "I am holding as many notes as I can. Clear one first.")
