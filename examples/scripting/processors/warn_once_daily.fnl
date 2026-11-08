;; Warns somebody for shouting, but only once a day.
;; trigger: always
;;
;; Without the memory it would warn on every message in a bad afternoon, which
;; is how a warning ladder stops meaning anything.
(local letters (string.gsub (rubotty.text) "[^%a]" ""))
;; Keyed per person, so one member having a bad day does not use up everybody
;; else's quiet.
(local key (.. "warned:" (rubotty.author)))

(if (or (< (length letters) 12) (not= letters (string.upper letters)))
    {:action "allow"}
    ;; Read back what we kept, or nil if it has gone.
    (rubotty.recall {:key key})
    {:action "allow"}
    (do
      ;; Record a warning against this person.
      (rubotty.warn (.. "Shouting in " (rubotty.room_key)))
      ;; Keep this until it expires.
      (rubotty.remember {:key key :value true :ttl (* 24 60 60)})
      {:action "allow"}))
