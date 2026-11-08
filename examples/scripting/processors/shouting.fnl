;; Turns a long SHOUTED message down instead of removing it.
;; trigger: always  {}
;;
;; Counts capital letters and rewrites when most of them are. Short bursts
;; like "OK GREAT" are left alone.
(local text (rubotty.text))
(if (< (string.len text) 15)
    {:action "allow"}
    ;; Counted with a plain loop rather than a comprehension: the sandbox offers
    ;; no character iterator, and this stays closest to the Lua it becomes.
    (let [counted (do
                    (var letters 0)
                    (var capitals 0)
                    (for [i 1 (string.len text)]
                      (let [c (string.sub text i i)]
                        (when (string.match c "%a")
                          (set letters (+ letters 1))
                          (when (string.match c "%u")
                            (set capitals (+ capitals 1))))))
                    {: letters : capitals})]
      (if (or (= counted.letters 0) (< (/ counted.capitals counted.letters) 0.7))
          {:action "allow"}
          {:action "rewrite"
           :text (.. (string.upper (string.sub text 1 1))
                     (string.lower (string.sub text 2)))})))
