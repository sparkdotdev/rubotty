-- Says who you are and where you are: /whoami.
-- trigger: command  { name = "whoami" }
--
-- Everything it asks for came with the message, so none of these costs a
-- lookup. A script cannot tell which of them do and which do not, which is
-- the point: that is rubotty's problem rather than yours.
local role = rubotty.author_is_operator() and "an operator" or "a member"

return rubotty.bold(rubotty.author()) .. " is " .. role ..
  ", writing from " .. rubotty.italic(rubotty.origin_platform()) ..
  " in " .. rubotty.code(rubotty.room_key()) .. "."
