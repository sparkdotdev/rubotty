;; Finds a room by name: /whereis banking.
;; trigger: command  { name = "whereis" }
;;
;; Shows how to ask rubotty for something. The script never sees a database,
;; only the list it is handed back.
(local wanted (string.lower (rubotty.args)))

(if (= wanted "")
    "Usage: /whereis <topic>"
    ;; Ask rubotty for the rooms in this community.
    (let [matches (icollect [_ room (ipairs (rubotty.rooms))]
                    (when (string.find (string.lower room) wanted 1 true) room))]
      (if (= (length matches) 0)
          (.. "Nothing here matches " wanted ". Try /rules for the room list.")
          (.. "Try: " (table.concat matches ", ")))))
