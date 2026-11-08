;; Strips invisible characters people use to sneak past word filters.
;; trigger: always  {}
;;
;; Removes zero width spaces and the stacked accents that make text unreadable.
;; A message that was nothing but those is removed instead.

;; Zero width space, ZWNJ, ZWJ, word joiner, and the RTL/LTR overrides.
(local invisible ["\226\128\139" "\226\128\140" "\226\128\141" "\226\129\160"
                  "\226\128\174" "\226\128\173"])

(var out (rubotty.text))
(each [_ seq (ipairs invisible)]
  (set out (string.gsub out seq "")))

;; Combining marks stacked more than twice on one base character are the zalgo
;; shape. Anything legitimate (accents, most Indic scripts) stays well under it.
(local stripped
  (string.gsub out "([\204\205][\128-\191])([\204\205][\128-\191])([\204\205][\128-\191])+" "%1%2"))

(if (= stripped (rubotty.text))
    {:action "allow"}
    (= (string.gsub stripped "%s" "") "")
    {:action "reject" :reason "That message was only invisible characters."}
    {:action "rewrite" :text stripped})
