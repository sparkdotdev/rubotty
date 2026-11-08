;; Warns once, then involves a person on the third strike.
;; trigger: recent_contains  { words = {"scam", "airdrop", "dm me"}, window = 20, count = 3 }
;;
;; Counting per person needs a memory, because the trigger only knows the
;; phrase came up, not who kept saying it.
(local key (.. "strikes:" (rubotty.author)))
;; Read back what we kept, or nil if it has gone.
(local strikes (+ (or (tonumber (rubotty.recall {:key key})) 0) 1))

;; Keep this until it expires.
(rubotty.remember {:key key :value strikes :ttl (* 7 24 60 60)})
;; Record a warning against this person.
(rubotty.warn (.. "Repeated scam phrasing (" strikes ")"))

(if (< strikes 3)
    {:action "allow"}
    ;; Third time: hand it to somebody who can actually talk to them. A script
    ;; gets warn and nothing heavier, because it cannot undo a ban and a ban
    ;; wants a person who can be argued with.
    (do
      ;; Tell the operators, without the room seeing it.
      (rubotty.alert (.. (rubotty.author) " has hit " strikes
                         " strikes for scam phrasing in " (rubotty.room_key) "."))
      {:action "reject" :reason "This has come up before. An operator will pick it up."}))
