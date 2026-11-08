;; Rolls dice: /roll 2d6.
;; trigger: command  { name = "roll" }
;;
;; Whatever a command returns is what rubotty posts. This one only does
;; arithmetic on its own argument.
(local (count-text sides-text) (string.match (rubotty.args) "^(%d*)d(%d+)$"))

(fn roll-them [count sides]
  ;; One call for the whole handful. The host seeds it, so a test can repeat it,
  ;; and asking for one number at a time would spend the call budget on a big
  ;; roll. This example used to derive the numbers from the message text, which
  ;; made every result predictable from the message that asked for it.
  (let [rolls (rubotty.random {:count count :min 1 :max sides})
        parts []]
    (var total 0)
    (each [_ roll (ipairs rolls)]
      (set total (+ total roll))
      (table.insert parts (tostring roll)))
    (.. (rubotty.author) " rolled " (table.concat parts ", ") "  (total " total ")")))

(if (not sides-text)
    "Usage: /roll 2d6"
    (let [count (or (tonumber count-text) 1)
          sides (tonumber sides-text)]
      (if (or (< count 1) (> count 20) (< sides 2) (> sides 1000))
          "I roll between 1 and 20 dice, of 2 to 1000 sides."
          (roll-them count sides))))
