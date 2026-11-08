-- Runs a quiz from its own question list: /trivia start, answer, next, scores, stop.
-- trigger: command  { name = "trivia" }
--
-- Rubotty keeps the session and the round: a deadline, who to wake, and
-- whatever data the round is opened with. Everything about the quiz itself,
-- who answered and who is winning, is this script's own business, kept in
-- the "scores" bucket rubotty.add and rubotty.entries share with
-- round_close and /scoreboard.
--
-- Setting close_after in the data file books the round_close callback,
-- which is what puts a clock on a question. Leave it out and a round stays
-- open until somebody types /trivia next.
data = rubotty.yaml_data! or {}
questions = data.questions or {}
verb = string.lower(string.match(rubotty.args! or "", "^(%S+)") or "")
rest = string.match(rubotty.args! or "", "^%S+%s+(.*)$") or ""

-- Read on every invocation rather than inside one branch, so "a quiz is
-- running" and "nothing is running" are both ordinary paths through this
-- script and the save check reaches each of them.
running = rubotty.session!

ask = (number) ->
  question = questions[number]
  if not question
    return "That was the last one. /trivia stop for the final scores."

  ok, err = rubotty.open_round { close_after: data.close_after, on_close: "round_close",
                                 data: { prompt: question.prompt, answer: question.answer,
                                        points: data.points } }
  if not ok
    return "I could not ask that one: " .. err
  "Question " .. number .. ". " .. question.prompt

scoreboard = ->
  lines = {}
  for entry in *rubotty.entries "scores", "", 200
    table.insert lines, entry.key .. ": " .. entry.value
  lines

if verb == "start"
  ok, err = rubotty.open_session { kind: "trivia", label: data.label or "Trivia" }
  if not ok
    return "I could not start one: " .. err
  return ask 1

if not running
  return "No quiz is running here. /trivia start begins one."

if verb == "answer"
  round = rubotty.round!
  if not round
    return "No question is open right now."

  given = string.match(rest, "^%s*(.-)%s*$") or rest
  rubotty.add { bucket: "scores", key: rubotty.author!, by: 0 }
  if string.lower(given) == string.lower(round.data.answer or "")
    rubotty.add { bucket: "round-" .. round.id, key: rubotty.author!, by: 1, ceiling: 1 }
  return "Answer noted. Nobody sees it until the round closes."

-- rounds is how many questions have been asked, so the next one is the one
-- after that. This is why a closed round does not have to be remembered.
if verb == "next"
  return ask running.rounds + 1

if verb == "stop"
  lines = scoreboard!
  rubotty.close_session!
  return "Quiz over, and nobody played." if #lines == 0
  return "Final scores.\n" .. table.concat lines, "\n"

if verb == "scores"
  lines = scoreboard!
  return "Nobody has answered yet." if #lines == 0
  return table.concat lines, "\n"

"Question " .. running.rounds .. ", " .. #rubotty.entries("scores", "", 200) ..
  " playing. Try /trivia answer, /trivia next, /trivia scores or /trivia stop."
