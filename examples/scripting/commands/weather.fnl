;; Looks up the weather: /weather Lisbon.
;; trigger: command  { name = "weather" }
;;
;; Posts twice: once to say it is asking, once when the answer arrives. The
;; call never blocks, so a slow service cannot hold up the room.

(fn answered []
  ;; Read once, because a getter that answers a table hands back a fresh copy.
  ;; ok is false for a refusal or a timeout, so this branch is what stops a
  ;; dead endpoint being silence.
  (let [answer (rubotty.response)]
    (if (and answer.ok answer.data)
        (.. (rubotty.bold (rubotty.invocation_data).city) ": " (tostring answer.data.summary))
        "I could not reach the weather service just now.")))

(fn ask [city]
  ;; Call the endpoint, and wake this script with the answer.
  (rubotty.async_http {:endpoint "weather"
                       :query {:city city}
                       :then_call "weather"
                       :data {:city city}})
  (.. "Asking about " city "..."))

(if (= (rubotty.kind) "http_callback") (answered)
    (= (rubotty.args) "") "Usage: /weather <city>"
    (ask (rubotty.args)))
