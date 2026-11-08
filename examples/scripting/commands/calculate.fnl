;; Does sums: /calculate (5*(4+12))/6.
;; trigger: command  { name = "calculate" }
;;
;; Reads the arithmetic character by character rather than running it, because
;; scripts cannot execute text somebody typed. So it can only ever produce a
;; number.

(local source (rubotty.args))
(var pos 1)

(fn skip-space []
  (let [(_ stop) (string.find source "^%s*" pos)]
    (set pos (+ stop 1))))

(fn peek []
  (skip-space)
  (string.sub source pos pos))

;; Declared before the mutually recursive pair below, since parse-atom calls
;; back into the expression parser for a bracketed group.
(var parse-expression nil)

(fn parse-atom []
  (skip-space)
  (if (= (peek) "(")
      (do
        (set pos (+ pos 1))
        (let [value (parse-expression)]
          (when (not= (peek) ")") (error "missing a closing bracket" 0))
          (set pos (+ pos 1))
          value))
      ;; A leading minus is part of the number, so -3 and 4 - 3 both work.
      (let [literal (string.match source "^%-?%d+%.?%d*" pos)]
        (when (not literal) (error (.. "expected a number near position " pos) 0))
        (set pos (+ pos (string.len literal)))
        ;; tonumber, because a capture is always a string and "2" + 2 is an error.
        (tonumber literal))))

(fn parse-term []
  (var value (parse-atom))
  (var running true)
  (while running
    (let [operator (peek)]
      (if (or (= operator "*") (= operator "/") (= operator "%"))
          (do
            (set pos (+ pos 1))
            (let [right (parse-atom)]
              (when (and (or (= operator "/") (= operator "%")) (= right 0))
                (error "division by zero" 0))
              (set value (if (= operator "*") (* value right)
                             (= operator "/") (/ value right)
                             (% value right)))))
          (set running false))))
  value)

(set parse-expression
     (fn []
       (var value (parse-term))
       (var running true)
       (while running
         (let [operator (peek)]
           (if (or (= operator "+") (= operator "-"))
               (do
                 (set pos (+ pos 1))
                 (let [right (parse-term)]
                   (set value (if (= operator "+") (+ value right) (- value right)))))
               (set running false))))
       value))

(fn answer []
  (let [(ok result) (pcall parse-expression)]
    (if (not ok)
        (.. "I could not read that: " (tostring result))
        (not= (peek) "")
        (.. "I could not read that: trailing input at position " pos)
        (or (not= result result) (= result math.huge) (= result (- math.huge)))
        "That does not come out to a number I can show."
        ;; Whole results read better without a decimal tail, and Lua gives 2.0
        ;; for something like 4/2 whether or not anybody wanted a float.
        (and (= result (math.floor result)) (< (math.abs result) 1e15))
        (.. source " = " (string.format "%d" result))
        (.. source " = " (string.format "%.6g" result)))))

(if (= source "")
    "Usage: /calculate (5*(4+12))/6"
    ;; Anything outside this set is rejected before parsing, so an error message
    ;; can never quote arbitrary text back into the room.
    (string.find source "[^%d%s%.%+%-%*/%%%(%)]")
    "I only do numbers and + - * / % and brackets."
    (answer))
