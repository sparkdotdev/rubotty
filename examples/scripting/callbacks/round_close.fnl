;; Closes whichever round is open, pays for it, and posts the result.
;; trigger: always
;;
;; Booked by trivia's own open_round, so this wakes with no message behind
;; it: no author, no text. What a right answer is worth travelled here in
;; the round's own data, so this never has to go read a data file of its
;; own. Whoever got it right was already added to a bucket named for this
;; very round while they were answering, so paying and reporting cost the
;; same five host calls whatever the room holds.
(local round (rubotty.round))

(if (not round)
    {:action "allow"}
    (let [right (rubotty.entries (.. "round-" round.id) "" 200)
          awards {}
          names []]
      (each [_ entry (ipairs right)]
        (tset awards entry.key (or round.data.points 10))
        (table.insert names entry.key))
      (when (> (length names) 0)
        (rubotty.add {:bucket "scores" :by awards}))
      (rubotty.close_round)
      (let [lines [(.. "Round " round.position " is closed.")]
            leader (. (rubotty.top "scores" 1) 1)]
        (table.insert lines
                      (if (= (length names) 0)
                          "Nobody got that one."
                          (.. "Right: " (table.concat names ", "))))
        (when leader
          (table.insert lines (.. "Leading: " leader.key " on " leader.value ".")))
        ;; Any action can carry a reply, and a woken script's reply is posted
        ;; into the room it was booked from.
        {:action "allow" :reply (table.concat lines "\n")})))
