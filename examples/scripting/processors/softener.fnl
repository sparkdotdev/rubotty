;; Swaps a few blunt phrases for gentler ones.
;; trigger: always  {}
;;
;; A rewrite replaces the message everywhere it was relayed, so the room only
;; ever sees the softened version.

(local pairings
  [["shut up" "let us hear them out"]
   ["that's stupid" "I do not follow that"]
   ["nobody cares" "I am not sure that lands"]])

(var out (rubotty.text))
(each [_ pairing (ipairs pairings)]
  (set out (string.gsub out (. pairing 1) (. pairing 2))))

(if (= out (rubotty.text))
    {:action "allow"}
    {:action "rewrite" :text out})
