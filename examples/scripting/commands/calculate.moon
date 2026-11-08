-- Does sums: /calculate (5*(4+12))/6.
-- trigger: command  { name = "calculate" }
--
-- Reads the arithmetic character by character rather than running it, because
-- scripts cannot execute text somebody typed. So it can only ever produce a
-- number.

source = rubotty.args!
pos = 1

skip_space = ->
  _, stop = string.find source, "^%s*", pos
  pos = stop + 1

peek = ->
  skip_space!
  string.sub source, pos, pos

parse_expression = nil

parse_atom = ->
  skip_space!
  if peek! == "("
    pos += 1
    value = parse_expression!
    error "missing a closing bracket", 0 if peek! != ")"
    pos += 1
    return value

  -- A leading minus belongs to the number, so -3 and 4 - 3 both work.
  literal = string.match source, "^%-?%d+%.?%d*", pos
  error "expected a number near position #{pos}", 0 unless literal
  pos += string.len literal
  -- tonumber, because a capture is always a string and "2" + 2 is an error.
  tonumber literal

parse_term = ->
  value = parse_atom!
  while true
    operator = peek!
    return value if operator != "*" and operator != "/" and operator != "%"
    pos += 1
    right = parse_atom!
    if (operator == "/" or operator == "%") and right == 0
      error "division by zero", 0
    switch operator
      when "*" then value = value * right
      when "/" then value = value / right
      else value = value % right

parse_expression = ->
  value = parse_term!
  while true
    operator = peek!
    return value if operator != "+" and operator != "-"
    pos += 1
    right = parse_term!
    value = if operator == "+" then value + right else value - right

return "Usage: /calculate (5*(4+12))/6" if source == ""

-- Anything outside this set is refused before parsing, so an error message can
-- never quote arbitrary text back into the room.
if string.find source, "[^%d%s%.%+%-%*/%%%(%)]"
  return "I only do numbers and + - * / % and brackets."

ok, result = pcall parse_expression
return "I could not read that: #{result}" unless ok
return "I could not read that: trailing input at position #{pos}" if peek! != ""
if result != result or result == math.huge or result == -math.huge
  return "That does not come out to a number I can show."

-- Whole results read better without a decimal tail.
if result == math.floor(result) and math.abs(result) < 1e15
  "#{source} = #{string.format '%d', result}"
else
  "#{source} = #{string.format '%.6g', result}"
