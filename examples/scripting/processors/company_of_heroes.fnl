;; Replaces swearing with something daft instead of deleting the message.
;; trigger: always
;;
;; Named after the Company of Heroes 2 chat filter. It swaps words using the
;; room's own word list, and picks a replacement that fits the sentence, so a
;; noun becomes a noun. Slurs are removed rather than made funny.

;; Grouped by part of speech, so the sentence still parses. Swapping a verb for
;; a noun would produce word salad.
(local swaps
  {:noun ["pudding" "bicycle" "hedgehog" "kerfuffle" "trombone" "biscuit"]
   :plural ["puddings" "bicycles" "hedgehogs" "trombones" "biscuits"]
   :verb ["frolic" "yodel" "juggle" "bake"]
   :gerund ["frolicking" "yodelling" "juggling" "baking"]
   :past ["frolicked" "yodelled" "juggled" "baked"]
   :adjective ["delightful" "splendid" "fluffy" "marvellous"]})

;; Match the shape of what was written, so a word that opened a sentence still
;; opens it with a capital.
(fn like [original replacement]
  (let [first (string.sub original 1 1)]
    (if (not= first (string.upper first))
        replacement
        (.. (string.upper (string.sub replacement 1 1))
            (string.sub replacement 2)))))

(fn has-slur? [spans]
  (accumulate [found false _ span (ipairs spans)]
    (or found (= span.category "slur"))))

(local text (rubotty.text))

;; Ask where the matches are, so we can cut them out ourselves.
(local spans (rubotty.offending_spans text))

(if (= (length spans) 0)
    {:action "allow"}
    ;; A slur is not funny, so it is removed rather than dressed up.
    (has-slur? spans)
    {:action "reject" :reason "That word is not welcome here."}
    ;; Right to left, because replacing a word moves every offset after it. The
    ;; offsets are bytes, which is what string.sub counts.
    (let [out (do
                (var carried text)
                (for [i (length spans) 1 -1]
                  (let [span (. spans i)
                        pool (or (. swaps span.part_of_speech) swaps.noun)
                        original (string.sub carried (+ span.from 1) span.to)
                        ;; Ask rubotty for a random number, so a test can repeat it.
                        picked (. pool (rubotty.random 1 (length pool)))]
                    (set carried (.. (string.sub carried 1 span.from)
                                     (like original picked)
                                     (string.sub carried (+ span.to 1))))))
                carried)]
      (if (= out text)
          {:action "allow"}
          {:action "rewrite" :text out})))
