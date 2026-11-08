;; Posts the house rules when somebody types /rules.
;; trigger: command  { name = "rules" }
(table.concat
  ["House rules:"
   "1. Be kind. Disagree with the argument, not the person."
   "2. No unsolicited DMs to members you met here."
   "3. Ask before posting affiliate or referral links."
   "4. Portuguese and English both welcome in every room."]
  "\n")
