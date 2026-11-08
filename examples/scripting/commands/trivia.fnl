;; Runs a quiz from its own question list: /trivia start, answer, next, scores, stop.
;; trigger: command  { name = "trivia" }
;;
;; Rubotty keeps the session and the round: a deadline, who to wake, and
;; whatever data the round is opened with. Everything about the quiz itself,
;; who answered and who is winning, is this script's own business, kept in
;; the "scores" bucket rubotty.add and rubotty.entries share with
;; round_close and /scoreboard.
;;
;; Setting close_after in the data file books the round_close callback,
;; which is what puts a clock on a question. Leave it out and a round stays
;; open until somebody types /trivia next.
(local data (or (rubotty.yaml_data) {}))
(local questions (or data.questions []))
(local verb (string.lower (or (string.match (or (rubotty.args) "") "^(%S+)") "")))
(local rest (or (string.match (or (rubotty.args) "") "^%S+%s+(.*)$") ""))

;; Read on every invocation rather than inside one branch, so "a quiz is
;; running" and "nothing is running" are both ordinary paths through this
;; script and the save check reaches each of them.
(local running (rubotty.session))

(fn ask [number]
  (let [question (. questions number)]
    (if (not question)
        "That was the last one. /trivia stop for the final scores."
        (let [(ok err) (rubotty.open_round {:close_after data.close_after
                                            :on_close "round_close"
                                            :data {:prompt question.prompt
                                                  :answer question.answer
                                                  :points data.points}})]
          (if (not ok)
              (.. "I could not ask that one: " err)
              (.. "Question " number ". " question.prompt))))))

(fn scoreboard []
  (icollect [_ entry (ipairs (rubotty.entries "scores" "" 200))]
    (.. entry.key ": " entry.value)))

(if (= verb "start")
    (let [(ok err) (rubotty.open_session {:kind "trivia" :label (or data.label "Trivia")})]
      (if (not ok)
          (.. "I could not start one: " err)
          (ask 1)))

    (not running)
    "No quiz is running here. /trivia start begins one."

    (= verb "answer")
    (let [round (rubotty.round)]
      (if (not round)
          "No question is open right now."
          (let [given (or (string.match rest "^%s*(.-)%s*$") rest)]
            (rubotty.add {:bucket "scores" :key (rubotty.author) :by 0})
            (when (= (string.lower given) (string.lower (or round.data.answer "")))
              (rubotty.add {:bucket (.. "round-" round.id) :key (rubotty.author) :by 1 :ceiling 1}))
            "Answer noted. Nobody sees it until the round closes.")))

    ;; rounds is how many questions have been asked, so the next one is the one
    ;; after that. This is why a closed round does not have to be remembered.
    (= verb "next")
    (ask (+ running.rounds 1))

    (= verb "stop")
    (let [lines (scoreboard)]
      (rubotty.close_session)
      (if (= (length lines) 0)
          "Quiz over, and nobody played."
          (.. "Final scores.\n" (table.concat lines "\n"))))

    (= verb "scores")
    (let [lines (scoreboard)]
      (if (= (length lines) 0)
          "Nobody has answered yet."
          (table.concat lines "\n")))

    (.. "Question " running.rounds ", " (length (rubotty.entries "scores" "" 200))
        " playing. Try /trivia answer, /trivia next, /trivia scores or /trivia stop."))
