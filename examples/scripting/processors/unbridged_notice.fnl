;; Warns that a screenshot will not reach every platform.
;; trigger: contains  { words = {"screenshot", "see the image", "as attached"} }
;;
;; Only says anything in a room that bridges IRC, which carries no images.

;; Ask which platforms this room is bridged to.
(local platforms (rubotty.platforms))

;; IRC carries no images, so a room bridging it is the case worth mentioning.
(fn bridges-irc? []
  (accumulate [found false _ platform (ipairs platforms)]
    (or found (= platform "irc"))))

(when (and (>= (length platforms) 2) (bridges-irc?))
  ;; Post a message into this room, as the bot.
  (rubotty.notify
    (rubotty.italic "Heads up: this room bridges IRC, so images do not cross. Describe it in words too.")))
{:action "allow"}
