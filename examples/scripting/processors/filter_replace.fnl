;; The same idea as company_of_heroes, in its simplest form.
;; trigger: always  {}
;;
;; Asks rubotty what matched and where, then slices those words out of its own
;; copy of the message. The word list never reaches the script.

(local text (rubotty.text))

;; Ask rubotty whether the room's word filter minds this text.
(local verdict (rubotty.classify text))
(local replacements ["pudding" "bicycle" "deep fried" "kerfuffle"])

(fn swapped []
  (var out "")
  (var last 1)
  (var index 0)
  ;; Ask where the matches are, so we can cut them out ourselves.
  (each [_ span (ipairs (rubotty.offending_spans text))]
    (set index (+ index 1))
    (let [swap (. replacements (+ (% (- index 1) (length replacements)) 1))]
      (set out (.. out (string.sub text last span.from) swap))
      (set last (+ span.to 1))))
  ;; Write a line to the bot log, for debugging.
  (rubotty.log (.. "filter_replace swapped " index " word(s)"))
  {:action "rewrite" :text (.. out (string.sub text last))})

(if (= verdict "clean")
    {:action "allow"}
    ;; A slur is not something to make a joke out of. Everything else is swapped.
    (= verdict "slur")
    {:action "reject" :reason "That one is not up for a rewrite."}
    (swapped))
