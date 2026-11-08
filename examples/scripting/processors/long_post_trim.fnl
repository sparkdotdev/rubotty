;; Shortens a wall of text to what the smallest platform here accepts.
;; trigger: always
;;
;; A room bridging IRC has 400 characters while Telegram has 4096, so a message
;; that fits on one side gets cut on the other.

;; Shorten this to what the smallest platform here allows.
(local shortened (rubotty.truncate (rubotty.text)))

(if (= shortened (rubotty.text))
    {:action "allow"}
    {:action "rewrite" :text shortened})
