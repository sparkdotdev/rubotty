-- Holds a link posted as somebody's first message.
-- trigger: new_voice  { window = 200 }
--
-- A first message that is just a link is the classic spam shape. Anything
-- else from a newcomer goes through untouched.
if not string.find rubotty.text!, "https?://"
  return { action: "allow" }

{
  action: "reject"
  reason: "Links from a first message are held automatically. Say hello first and an operator will let it through."
}
