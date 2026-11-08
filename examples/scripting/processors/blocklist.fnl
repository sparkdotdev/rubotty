;; Rejects a message holding any phrase from this script's own data file.
;; trigger: always
;;
;; The list lives under Data beside this code rather than inside it. That is
;; the whole point: somebody who wants to add a phrase edits a YAML file, and
;; the Fennel never changes. It is read with (rubotty.yaml_data), which hands
;; back the parsed document, and a script can only read it.
;;
;; Written to survive having no data at all, because that is what it gets
;; before anybody fills the Data tab in, and a rule that fell over there could
;; never pass its check.
(local data (or (rubotty.yaml_data) {}))
(local words data.words)

(if (not words)
    {:action "allow"}
    (let [text (string.lower (or (rubotty.text) ""))
          hit (accumulate [found nil _ word (ipairs words)]
                (or found
                    (and (string.find text (string.lower word) 1 true) word)))]
      (if hit
          {:action "reject" :reason (or data.reason "That is not allowed here.")}
          {:action "allow"})))
