;; Mentions today's events when somebody asks what is on.
;; trigger: contains  { words = {"what's on", "whats on", "any events"} }
;;
;; Only answers when something is actually close, because replying "nothing
;; scheduled" every time is noise.
(local hour 3600)
;; Ask for the upcoming events.
(local soon (icollect [_ event (ipairs (rubotty.events))]
              (when (and (> event.starts_in 0) (< event.starts_in (* 24 hour)))
                event.title)))

(when (> (length soon) 0)
  ;; Post a message into this room, as the bot.
  (rubotty.notify (.. "Coming up today: " (rubotty.bold (table.concat soon ", ")))))
{:action "allow"}
