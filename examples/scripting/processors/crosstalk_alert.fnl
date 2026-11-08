;; Warns the operators when two particular people are both active.
;; trigger: recent_senders  { names = {"ada", "grace"}, window = 12 }
;;
;; Change the names to people in your own community, or it will never fire.
;; Nothing is blocked; it is just a heads up.

;; Tell the operators, without the room seeing it.
(rubotty.alert (.. "Both " (table.concat (rubotty.present) " and ")
                   " are active in " (rubotty.room_key) " right now."))
{:action "allow"}
