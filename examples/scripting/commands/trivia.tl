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
-- Annotated rather than inferred: `x or {}` on its own leaves Teal with the
-- empty table's type, and every field read off it is then an unknown field.
local data: {string:any} = rubotty.yaml_data() or {}
local questions = (data.questions or {}) as {{string:any}}
local verb = string.lower(string.match(rubotty.args() or "", "^(%S+)") or "")
local rest = string.match(rubotty.args() or "", "^%S+%s+(.*)$") or ""

-- Read on every invocation rather than inside one branch, so "a quiz is
-- running" and "nothing is running" are both ordinary paths through this
-- script and the save check reaches each of them.
local running = rubotty.session()

local function ask(number: integer): string
  local question = questions[number]
  if not question then
    return "That was the last one. /trivia stop for the final scores."
  end

  local ok, err = rubotty.open_round({ close_after = data.close_after, on_close = "round_close",
                                       data = { prompt = question.prompt, answer = question.answer,
                                               points = data.points } })
  if not ok then
    return "I could not ask that one: " .. err
  end
  return "Question " .. number .. ". " .. (question.prompt as string)
end

if verb == "start" then
  local ok, err = rubotty.open_session({ kind = "trivia", label = data.label or "Trivia" })
  if not ok then
    return "I could not start one: " .. err
  end
  return ask(1)
end

if not running then
  return "No quiz is running here. /trivia start begins one."
end

if verb == "answer" then
  local round = rubotty.round()
  if not round then
    return "No question is open right now."
  end

  local given = string.match(rest, "^%s*(.-)%s*$") or rest
  rubotty.add({ bucket = "scores", key = rubotty.author(), by = 0 })
  if string.lower(given) == string.lower((round.data.answer as string) or "") then
    rubotty.add({ bucket = "round-" .. round.id, key = rubotty.author(), by = 1, ceiling = 1 })
  end
  return "Answer noted. Nobody sees it until the round closes."
end

-- rounds is how many questions have been asked, so the next one is the one
-- after that. This is why a closed round does not have to be remembered.
if verb == "next" then
  return ask(running.rounds + 1)
end

if verb == "scores" or verb == "stop" then
  local lines: {string} = {}
  for _, entry in ipairs(rubotty.entries("scores", "", 200)) do
    table.insert(lines, entry.key .. ": " .. entry.value)
  end

  if verb == "stop" then
    rubotty.close_session()
    if #lines == 0 then
      return "Quiz over, and nobody played."
    end
    return "Final scores.\n" .. table.concat(lines, "\n")
  end

  if #lines == 0 then
    return "Nobody has answered yet."
  end
  return table.concat(lines, "\n")
end

return "Question " .. running.rounds .. ", " .. #rubotty.entries("scores", "", 200) ..
  " playing. Try /trivia answer, /trivia next, /trivia scores or /trivia stop."
