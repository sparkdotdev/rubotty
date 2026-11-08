;; Reminds you later: /remind 30 stand up.
;; trigger: command  { name = "remind" }
;;
;; Runs twice: once when you type it, and again when the timer fires. The
;; second run has no message behind it, so check (rubotty.kind) to tell them
;; apart.
(local (minutes what) (string.match (or (rubotty.args) "") "^(%d+)%s+(.+)$"))

(fn book []
  (let [who (rubotty.author)]
    ;; Come back and run this again later.
    (rubotty.schedule {:after (* (tonumber minutes) 60)
                       :data {:who who :what what}})
    ;; Turn a name into a real ping.
    (.. "Right you are, " (rubotty.mention who) ", in " minutes " minutes.")))

(if (= (rubotty.kind) "scheduled_function")
    ;; A wake, rather than somebody typing the command. Read once, because a
    ;; getter that answers a table hands back a fresh copy.
    (let [booked (rubotty.invocation_data)]
      (.. (rubotty.mention booked.who) ", you asked me to remind you: " booked.what))
    (not minutes)
    "Usage: /remind <minutes> <what>"
    (book))
