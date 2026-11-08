;; Runs a poll anybody can vote in: /poll ask, vote, close.
;; trigger: command  { name = "poll" }
;;
;; The same session and round a quiz uses, with the question and choices kept
;; in the round's own data instead of an answer to score against, which is
;; the whole difference between a poll and a question somebody is scored on.
;; Each choice's tally lives in a kept bucket named for the round, so closing
;; needs no per-voter walk; who voted for what is remembered per person, so a
;; second vote moves their count rather than adding a second one.
(local verb (string.lower (or (string.match (or (rubotty.args) "") "^(%S+)") "")))
(local rest (or (string.match (or (rubotty.args) "") "^%S+%s+(.*)$") ""))

(local open (rubotty.round))

;; The question and its choices, written as one line separated by pipes.
(fn split [text]
  (let [parts []]
    (each [piece (string.gmatch text "[^|]+")]
      (let [trimmed (string.match piece "^%s*(.-)%s*$")]
        (when (not= trimmed "")
          (table.insert parts trimmed))))
    parts))

(if (= verb "ask")
    (let [parts (split rest)
          question (table.remove parts 1)]
      (if (or (not question) (< (length parts) 2))
          "Usage: /poll ask Which night? | Tuesday | Wednesday"
          (let [(ok err) (rubotty.open_session {:kind "poll" :label question})]
            (if (not ok)
                (.. "I could not start one: " err)
                (do
                  (rubotty.open_round {:data {:prompt question :options parts}})
                  (.. question "\n" (table.concat parts " / ")
                      "\nVote with /poll vote <choice>."))))))

    (not open)
    "No poll is running here. /poll ask starts one."

    ;; A poll is open: everything below shares the round's own buckets.
    (let [tallies (.. "poll-" open.id)
          voters (.. "poll-voters-" open.id)]
      (if (= verb "vote")
          (let [choice (string.lower rest)
                previous (rubotty.recall {:bucket voters :key (rubotty.author)})]
            (when (not= previous choice)
              (when previous
                (rubotty.add {:bucket tallies :key previous :by -1 :floor 0}))
              (rubotty.add {:bucket tallies :key choice :by 1})
              (rubotty.remember {:bucket voters :key (rubotty.author) :value choice :ttl 3600}))
            "Vote recorded. Change it by voting again.")

          ;; A round's data is opaque to rubotty, so a poll started some other
          ;; way, or nothing at all, leaves neither field here: fall back
          ;; rather than index into what open_round never set.
          (let [payload (or open.data {})
                counts {}]
            (each [_ entry (ipairs (rubotty.entries tallies "" 200))]
              (tset counts entry.key entry.value))
            (let [lines (icollect [_ option (ipairs (or payload.options []))]
                          (.. option ": " (or (. counts (string.lower option)) 0)))
                  prompt (or payload.prompt "")]
              (if (= verb "close")
                  (do
                    (rubotty.close_session)
                    (.. "Poll closed. " prompt "\n" (table.concat lines "\n")))
                  (.. prompt "\n" (table.concat lines "\n"))))))))
