;; Says what this room is connected to: /here.
;; trigger: command  { name = "here" }
;;
;; Handy for checking whether a room really does bridge the platforms you
;; think it does.

;; Ask which platforms this room is bridged to.
(local platforms (rubotty.platforms))
;; Ask which features are on in this room.
(local features (rubotty.features))

(var answer (.. (rubotty.bold (rubotty.room_key)) " bridges " (table.concat platforms ", ")
                "\nRunning: " (table.concat features ", ")))

;; feature_enabled answers for one feature without reading the whole list, which
;; is what a rule branching on a single feature should use.
(when (rubotty.feature_enabled "word_filter")
  (set answer (.. answer "\nThe word filter is on in here.")))

answer
