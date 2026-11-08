-- Says which rubotty is running: /version.
-- trigger: command  { name = "version" }
--
-- Useful when a room reports something odd and you need to know what is
-- actually deployed.

-- Ask which version of rubotty is running.
local build = rubotty.build()

return "rubotty " .. rubotty.code(build.version) ..
  " at commit " .. rubotty.code(string.sub(build.commit as string, 1, 7))
