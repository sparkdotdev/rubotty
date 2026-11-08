;; Tells the operators when one person is dominating a room.
;; trigger: author_repeat  { window = 8, count = 4 }
;;
;; A monologue is usually somebody upset rather than somebody spamming, so
;; this alerts quietly and deletes nothing.

;; Tell the operators, without the room seeing it.
(rubotty.alert (.. (rubotty.author) " has sent " (rubotty.count) " of the last " (rubotty.window)
                   " messages in " (rubotty.room_key) "."))
{:action "allow"}
