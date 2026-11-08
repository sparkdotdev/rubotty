-- Does sums: /calculate (5*(4+12))/6.
-- trigger: command  { name = "calculate" }
--
-- Reads the arithmetic character by character rather than running it, because
-- scripts cannot execute text somebody typed. So it can only ever produce a
-- number.

local source = rubotty.args()
local pos = 1

local function skip_space()
  local _, stop = string.find(source, "^%s*", pos)
  pos = stop + 1
end

local function peek(): string
  skip_space()
  return string.sub(source, pos, pos)
end

local parse_expression: function(): number

local function parse_atom(): number
  skip_space()
  if peek() == "(" then
    pos = pos + 1
    local value = parse_expression()
    if peek() ~= ")" then error("missing a closing bracket", 0) end
    pos = pos + 1
    return value
  end

  -- A leading minus belongs to the number, so -3 and 4 - 3 both work.
  local literal = string.match(source, "^%-?%d+%.?%d*", pos)
  if not literal then error("expected a number near position " .. pos, 0) end
  pos = pos + string.len(literal)
  -- A match is always text, so it has to be turned into a number first.
  return tonumber(literal)
end

local function parse_term(): number
  local value = parse_atom()
  while true do
    local operator = peek()
    if operator ~= "*" and operator ~= "/" and operator ~= "%" then return value end
    pos = pos + 1
    local right = parse_atom()
    if (operator == "/" or operator == "%") and right == 0 then error("division by zero", 0) end
    if operator == "*" then value = value * right
    elseif operator == "/" then value = value / right
    else value = value % right end
  end
end

parse_expression = function(): number
  local value = parse_term()
  while true do
    local operator = peek()
    if operator ~= "+" and operator ~= "-" then return value end
    pos = pos + 1
    local right = parse_term()
    if operator == "+" then value = value + right else value = value - right end
  end
end

if source == "" then
  return "Usage: /calculate (5*(4+12))/6"
end

-- Anything outside this set is refused before parsing, so an error can never
-- quote arbitrary text back into the room.
if string.find(source, "[^%d%s%.%+%-%*/%%%(%)]") then
  return "I only do numbers and + - * / % and brackets."
end

local ok, result = pcall(parse_expression)
if not ok then
  return "I could not read that: " .. tostring(result)
end
if peek() ~= "" then
  return "I could not read that: trailing input at position " .. pos
end
if result ~= result or result == math.huge or result == -math.huge then
  return "That does not come out to a number I can show."
end

-- Whole answers read better without a decimal tail.
if result == math.floor(result) and math.abs(result) < 1e15 then
  return source .. " = " .. string.format("%d", result)
end
return source .. " = " .. string.format("%.6g", result)
