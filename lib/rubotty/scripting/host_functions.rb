# frozen_string_literal: true

require "rubotty/features/text_fold"

module Rubotty
  module Scripting
    # The catalog of things a script can call under the `rubotty` namespace,
    # declared once here so {Registry}, the editor and docs/scripting.md agree:
    # a function not declared here is not offered, documented, or callable. An
    # {Entry} carries typed {Form}s so all four stay in sync. Each entry marks
    # itself as a getter, answered inside the child at no cost, or a handler
    # that costs a call over the pipe. `classify` and `offending_spans` answer
    # a verdict or offsets rather than the word list, so nothing crosses the
    # pipe the script didn't already hold.
    module HostFunctions
      # One argument of one call form. The unit is held apart from the type
      # because "a number" and "a number of seconds" send an operator to two
      # different places, and a ttl written in milliseconds is the mistake
      # this field exists to stop; anything that is not a bare count carries one.
      Argument = Data.define(:name, :type, :unit, :optional, :note) do
        def initialize(name:, type:, unit: nil, optional: false, note: nil) = super

        # Everything except the name: "number (seconds), optional, 1 day by
        # default". Kept apart from #described so a renderer that wants to style
        # the name differently does not have to pull the string back apart.
        def qualified
          parts = [unit ? "#{type} (#{unit})" : type]
          parts << "optional" if optional
          parts << note if note
          parts.join(", ")
        end

        # "ttl: number (seconds), optional, 1 day by default"
        def described = "#{name}: #{qualified}"
      end

      # One way a function may be called. A list rather than a single
      # signature because some functions take more than one shape (remember
      # writes to a store that expires or one that doesn't, and the ttl
      # decides which); an optional trailing argument stays inside one form
      # rather than getting a form of its own.
      Form = Data.define(:args, :braces, :sample) do
        def initialize(args:, sample:, braces: false) = super

        # classify(text), or schedule{script, after, at, data} for the ones
        # written with a table.
        def signature(name)
          written = args.map(&:name).join(", ")
          braces ? "#{name}{#{written}}" : "#{name}(#{written})"
        end
      end

      # What a script may call: what it does, what comes back, every call
      # shape it accepts, and a line that really runs. +getter+ marks the
      # ones served inside the child from its own payload rather than by a
      # handler over the pipe; kept on the entry itself so the reference, the
      # editor, {Child}'s sandbox spec and {.registry} all agree on which is
      # which.
      Entry = Data.define(:name, :summary, :returns, :forms, :getter) do
        # A getter takes nothing, and its sample is its own signature, so the
        # one form it has is built here rather than written out for each of
        # them and then kept in step with the name on the left of the catalog.
        def initialize(name:, summary:, returns:, forms: nil, getter: false)
          super(name: name, summary: summary, returns: returns, getter: getter,
                forms: forms || [Form.new(args: [], sample: "rubotty.#{name}()")])
        end

        def signatures = forms.map { |form| form.signature(name) }

        def samples = forms.map(&:sample)

        # Every argument across every form, first mention winning, so a bucket
        # that only appears on the second form is still described exactly once.
        def arguments = forms.flat_map(&:args).uniq(&:name)

        def described_arguments = arguments.map(&:described)
      end

      # Most numbers one `random{}` call draws: a hand of cards or a deck's
      # worth, with the ceiling set by what a game needs rather than by the
      # pipe's frame limit.
      MAX_RANDOM_COUNT = 500

      # Longest list `shuffle` will reorder. A longer one comes back untouched
      # rather than truncated: quietly dropping half a list is worse than a
      # script noticing nothing was shuffled.
      MAX_SHUFFLE_LENGTH = 1000

      # Compact constructors, so the catalog below reads as a table rather than
      # as a hundred lines of Data.new.
      def self.arg(name, type, unit: nil, optional: false, note: nil)
        Argument.new(name: name, type: type, unit: unit, optional: optional, note: note)
      end

      def self.call_form(sample, *args) = Form.new(args: args, sample: sample)

      def self.table_form(sample, *args) = Form.new(args: args, sample: sample, braces: true)

      # Every styling helper takes the same argument and answers the same way,
      # so the eight of them are built rather than written out eight times.
      def self.style_entry(summary, sample)
        { summary: summary,
          returns: "the text, styled",
          forms: [call_form(sample, arg("text", "string"))] }
      end

      # One thing this invocation was handed, read back out of the payload
      # inside the child. Takes nothing, so {Entry} builds the single form
      # from the name.
      def self.getter_entry(summary, returns)
        { summary: summary, returns: returns, getter: true }
      end

      # name => Entry. The name is written once, on the left, and threaded into
      # the entry, so a key and the signature it renders cannot disagree.
      CATALOG = {
        # What this invocation was handed, served inside the child from the
        # payload it already has at no cost, but presented as an ordinary
        # call so a script can never tell which of these rides the payload.
        # Fields specific to a woken run come back `nil`, not an empty table.
        "text" => getter_entry("The text of the message", "a string, or `nil` on a woken run"),
        "author" => getter_entry("The author's display name, as the room shows it today",
                                 "a string, or `nil` on a woken run"),
        "author_is_operator" => getter_entry("Whether the author is an operator of this community",
                                             "`true` or `false`, or `nil` on a woken run"),
        "origin_platform" => getter_entry("Which platform the message arrived on",
                                          %(a string, such as `"telegram"`, or `nil` on a woken run)),
        "attachments" => getter_entry(
          "The files attached to the message",
          "a list of tables, each `{kind, filename, bytes, content_type, ref}`, and an empty list " \
          "when nothing was attached"
        ),
        "reply_to" => getter_entry("The message this one replied to",
                                   "a table of `{handle, author, text}`, or `nil` when it answers nothing"),
        "handle" => getter_entry("A handle for this message, which `react` and `post` take",
                                 "a string, or `nil` on a woken run"),
        "room_key" => getter_entry("The key of the room this ran in", "a string"),
        "now" => getter_entry(
          "The current time, read once at the start of the run and frozen for the rest of it",
          "a table of `{epoch, hour, minute, wday, day, month, year, iso, tz}`, always UTC"
        ),
        "kind" => getter_entry(
          "Why this ran",
          %(`"message"`, `"message_edit"`, `"command_invocation"`, `"scheduled_function"` or ) +
          %(`"http_callback"`. Always answered)
        ),
        "trigger" => getter_entry(
          "Which of this script's conditions woke it",
          "the condition's type name, or `nil` when no condition was behind the run"
        ),
        "command" => getter_entry("Which command was typed, without the slash",
                                  "a string, and `nil` unless a command condition matched"),
        "args" => getter_entry("Everything after the command name, already trimmed",
                               "a string, which is empty when nothing followed the command"),
        "matched" => getter_entry("Which of the condition's words matched",
                                  "a list of strings, and `nil` unless a word condition matched"),
        "hits" => getter_entry("How many times those words appeared in the window",
                               "a whole number, and `nil` unless `recent_contains` matched"),
        "window" => getter_entry("How many messages the condition counted over",
                                 "a whole number, and `nil` unless a windowed condition matched"),
        "count" => getter_entry("How many the condition counted",
                                "a whole number, and `nil` unless a counting condition matched"),
        "minutes" => getter_entry("How many minutes the condition counted over",
                                  "a whole number, and `nil` unless `contains_rate` matched"),
        "present" => getter_entry("Which of the named people are active in this room",
                                  "a list of strings, and `nil` unless `recent_senders` matched"),
        "invocation_data" => getter_entry(
          "The data table passed to the `schedule` or `async_http` that booked this run",
          "a table, or `nil` when nothing was passed"
        ),
        "response" => getter_entry(
          "The endpoint's answer, on a run `async_http` woke",
          "a table of `{status, ok, body, data, format}`, or `nil` on any other kind of run"
        ),
        "wake_reason" => getter_entry(
          "Why this run is happening, on a woken run",
          %(`"round_close"` when a round's own close_after deadline fired, or `nil` on any other kind ) +
          "of run, including a schedule() wake the script booked itself"
        ),
        "classify" => {
          summary: "Runs this room's word filter over a piece of text",
          returns: %(`"clean"`, `"slur"`, `"profanity"` or `"community"`),
          forms: [call_form("rubotty.classify(rubotty.text())", arg("text", "string"))]
        },
        "offending_spans" => {
          summary: "Finds where the word filter matched in a piece of text",
          returns: "a list of tables, each `{from, to, category, part_of_speech}`, where `from` and " \
                   "`to` are byte offsets counted the way `string.sub` counts",
          forms: [call_form("rubotty.offending_spans(rubotty.text())", arg("text", "string"))]
        },
        "link_verdict" => {
          summary: "Runs this room's link filter over any address in the text",
          returns: %(`"clean"`, `"blocked"` or `"unknown_domain"`),
          forms: [call_form("rubotty.link_verdict(rubotty.text())", arg("text", "string"))]
        },
        "fold" => {
          summary: "Casefolds text and strips its accents, the same folding the word filter uses",
          returns: "the text folded, so two spellings of the same word come out identical",
          forms: [call_form("rubotty.fold(rubotty.text())", arg("text", "string"))]
        },
        "chars" => {
          summary: "Splits text into characters, which the byte counting `string` library cannot do",
          returns: "a list of strings, one per character",
          forms: [call_form("rubotty.chars(rubotty.text())",
                            arg("text", "string", unit: "up to 20,000 characters answered"))]
        },
        "may" => {
          summary: "Whether the author may carry out one moderation action in this room",
          returns: "`true` or `false`, and `false` on a woken run, where there is no author to ask about",
          forms: [call_form(%(rubotty.may("mute")),
                            arg("action", "string",
                                note: "one of delete, ban, unban, kick, mute, unmute, pin, unpin, " \
                                      "unpinall, clean, lock, unlock. Anything else answers false"))]
        },
        "feature_enabled" => {
          summary: "Whether one feature is switched on for this room",
          returns: "`true` or `false`",
          forms: [call_form(%(rubotty.feature_enabled("word_filter")),
                            arg("name", "string", note: "the feature's name, as the dashboard lists it"))]
        },
        "rooms" => {
          summary: "The room labels in this community",
          returns: "a list of strings",
          forms: [call_form("rubotty.rooms()")]
        },
        "platforms" => {
          summary: "The platforms this community bridges",
          returns: %(a list of strings, such as `"telegram"` or `"discord"`),
          forms: [call_form("rubotty.platforms()")]
        },
        "room_capabilities" => {
          summary: "What this room can do, folded across every platform it bridges",
          returns: "a table of `{reactions, edit, delete, reply, threads, private_message, " \
                   "longest_message}`, the first six booleans and the last a number of characters. " \
                   "A boolean is true only when EVERY platform in this room can do it",
          forms: [call_form("rubotty.room_capabilities()")]
        },
        "features" => {
          summary: "The features switched on for this room",
          returns: "a list of strings",
          forms: [call_form("rubotty.features()")]
        },
        "events" => {
          summary: "The events coming up in this community",
          returns: "a list of tables, each `{title, starts_at, starts_in, room, rsvp_count}`, where " \
                   "`starts_in` is a number of seconds from now",
          forms: [call_form("rubotty.events()")]
        },
        "build" => {
          summary: "The build of rubotty running this",
          returns: "a table of `{version, commit}`, both strings",
          forms: [call_form("rubotty.build()")]
        },
        "community_stats" => {
          summary: "The community's dashboard aggregates, read only",
          returns: "a table of name to number, the analytics page's own aggregates. It does NOT " \
                   "carry what `increment_stat` and `record_stat` wrote, which no script can read back",
          forms: [call_form("rubotty.community_stats()")]
        },
        "yaml_data" => {
          summary: "This script's own data file, parsed",
          returns: "the document as a table, or `nil` when the script has no data file",
          forms: [call_form("rubotty.yaml_data()")]
        },
        "notify" => {
          summary: "Posts a message into this room as the bot",
          returns: "`false` when there is no room to post into",
          forms: [call_form(%(rubotty.notify("Back in five minutes.")), arg("text", "string"))]
        },
        # The five that follow all PUT SOMETHING IN FRONT OF PEOPLE. post,
        # react and whisper are the three that reach people and are charged
        # :broadcast in {BY_COST}; edit and delete change something already in
        # front of them and stay :read.
        "post" => {
          summary: "Posts a message into this room and answers a handle for it",
          returns: "a handle, as a string, or `false` and a reason when there is no room to post into",
          forms: [table_form(
            %(rubotty.post{ text = "Round one. Sixty seconds.", reply_to = rubotty.handle() }),
            arg("text", "string"),
            arg("reply_to", "string", optional: true,
                note: "a handle to answer, `rubotty.handle()` being the message in hand")
          )]
        },
        "edit" => {
          summary: "Rewrites something this bot posted",
          returns: "`true` when a platform took the edit, or `false` and a reason when none could",
          forms: [call_form(
            %(rubotty.edit(rubotty.recall{ key = "scoreboard" }, "Final scores")),
            arg("handle", "string", note: "what `post` answered with"),
            arg("text", "string")
          )]
        },
        "delete" => {
          summary: "Removes something this bot posted",
          returns: "`true` when a platform removed it, or `false` and a reason when none could",
          forms: [call_form(%(rubotty.delete(rubotty.recall{ key = "scoreboard" })),
                            arg("handle", "string", note: "what `post` answered with"))]
        },
        "react" => {
          summary: "Puts one reaction on a message",
          returns: "`true` when a platform took it, or `false` and a reason when none could",
          # Written as Lua's own escape rather than as the character, so the
          # reference this renders into stays ASCII. Pasting the emoji itself
          # works exactly the same and is what most scripts do.
          forms: [call_form(
            %(rubotty.react(rubotty.handle(), "👍")),
            arg("handle", "string", note: "`rubotty.handle()` for the message in hand, or what `post` answered"),
            arg("name", "string", note: "the emoji itself; a `:shortcode:` is never looked up")
          )]
        },
        "whisper" => {
          summary: "Sends a private message to one member, or to up to 25",
          returns: "`true` when every recipient was reached privately, or `false` and a reason when " \
                   "one of them had no private route",
          forms: [table_form(
            %(rubotty.whisper{ to = rubotty.participant().id, text = "You have already voted." }),
            arg("to", "string, or a list of strings", unit: "up to 25 recipients",
                note: "participant ids, never display names"),
            arg("text", "string"),
            arg("fallback", "string", optional: true,
                note: %(`"drop"`, the default, says nothing where there is no private route; ) +
                      %(`"room"` says it in the room instead))
          )]
        },
        "participant" => {
          summary: "The author as a participant record, with an id that survives a rename",
          returns: "a table of `{id, display, platform, is_operator}`, or `nil` on a woken run, " \
                   "where nobody sent anything",
          forms: [call_form("rubotty.participant()")]
        },
        "resolve_participant" => {
          summary: "Looks up a participant by a name somebody typed",
          returns: "a table of `{id, display}`, or `nil` when the name matches nobody at all, " \
                   "or more than one person",
          forms: [call_form("rubotty.resolve_participant(rubotty.args())",
                            arg("name", "string", note: "a display name or a handle, with or without the @"))]
        },
        "mention_participant" => {
          summary: "Pings somebody by their participant id, which survives a rename",
          returns: "the ping, or their name as plain text where the platform cannot ping them, " \
                   "or an empty string for an id naming nobody here",
          forms: [call_form("rubotty.mention_participant(rubotty.invocation_data().winner)",
                            arg("id", "string", note: "an id from `participant` or `resolve_participant`"))]
        },
        "warn" => {
          summary: "Records a warning against the author, counting towards the warning ladder",
          returns: "`true` once it is recorded, or `false` on a woken run, where there is no author to warn",
          forms: [call_form(%(rubotty.warn("Shouting in " .. rubotty.room_key())),
                            arg("reason", "string", note: "what the warning is for"))]
        },
        "alert" => {
          summary: "Records an alert on the community's Alerts page. The room never sees it",
          returns: "`true`, or `false` and a reason when the mode is neither of the two",
          forms: [
            call_form(%(rubotty.alert("Three links from a new account in " .. rubotty.room_key() .. ".")),
                      arg("text", "string")),
            call_form(%(rubotty.alert(rubotty.author() .. " is posting a wallet address.", "loud")),
                      arg("text", "string"),
                      arg("mode", "string",
                          note: %(`"quiet"`, which only writes it down, or `"loud"`, which also DMs ) +
                                "this community's operators"))
          ]
        },
        "log" => {
          summary: "Writes a line to the bot log, shown under admin debug logs",
          returns: "`true`",
          forms: [call_form(%(rubotty.log("nothing matched in " .. rubotty.room_key())), arg("text", "string"))]
        },
        "random" => {
          summary: "Draws whole numbers in a range, from a generator the host seeds once per invocation",
          returns: "a whole number, or a list of them for the table form, `min` and `max` both included",
          forms: [
            call_form("rubotty.random(1, 6)",
                      arg("min", "whole number"), arg("max", "whole number")),
            table_form(%(rubotty.random{ count = 5, min = 1, max = 52, unique = true }),
                       arg("count", "whole number", unit: "count",
                           note: "how many to draw, 1 by default and #{MAX_RANDOM_COUNT} at most"),
                       arg("min", "whole number"), arg("max", "whole number"),
                       arg("unique", "boolean", optional: true,
                           note: "draws without replacement, and a `count` wider than the range " \
                                 "is cut to the range"))
          ]
        },
        "shuffle" => {
          summary: "Reorders a list, from the same host seeded generator",
          returns: "a new list, the original untouched",
          forms: [call_form("rubotty.shuffle({ \"ada\", \"grace\", \"alan\" })",
                            arg("list", "table", unit: "up to #{MAX_SHUFFLE_LENGTH} entries"))]
        },
        "truncate" => {
          summary: "Shortens text to what the narrowest platform in this room accepts",
          returns: "the text, cut on a word boundary where one is close",
          forms: [call_form("rubotty.truncate(rubotty.text())", arg("text", "string"))]
        },
        "mention" => {
          summary: "Turns a name into a ping on each platform",
          returns: %(the name written as `@handle` and marked as a ping, or an empty string when ) +
                   "the name was blank",
          forms: [call_form("rubotty.mention(rubotty.author())",
                            arg("name", "string", note: "a display name or a handle"))]
        },
        "escape" => {
          summary: "Strips the styling sentinels out of text a member typed, so it is safe inside a styled reply",
          returns: "the text with the styling sentinels stripped out",
          forms: [call_form("rubotty.escape(rubotty.text())", arg("text", "string"))]
        },
        "bold" => style_entry("Styles the text bold", %(rubotty.bold("careful"))),
        "italic" => style_entry("Styles the text italic", %(rubotty.italic("considered"))),
        "underline" => style_entry("Styles the text underlined", %(rubotty.underline("read this"))),
        "strikethrough" => style_entry("Styles the text struck through", %(rubotty.strikethrough("cancelled"))),
        "spoiler" => style_entry("Hides the text behind a spoiler, where the platform has them",
                                 %(rubotty.spoiler("the butler did it"))),
        "code" => style_entry("Styles the text as inline code", %(rubotty.code("/rules"))),
        "pre" => style_entry("Styles the text as a code block", %(rubotty.pre(rubotty.text()))),
        "blockquote" => style_entry("Styles the text as a quote",
                                    %(rubotty.blockquote(rubotty.escape(rubotty.text())))),
        "format" => {
          summary: "Applies several styles at once",
          returns: "the text with every style you asked for, nested in a stable order",
          forms: [call_form(%(rubotty.format("both at once", { bold = true, italic = true })),
                            arg("text", "string"),
                            arg("styles", "table",
                                note: "style name to `true`, eg `{ bold = true, italic = true }`"))]
        },
        # The store, in one vocabulary over two different places to put
        # something. What the ttl says decides which: a number or nothing is
        # working state that expires; "never" is a kept total, restricted to
        # whole numbers as a deliberate privacy design.
        "remember" => {
          summary: "Stores a value in the database for a later run to read. Pass a bucket to share " \
                   "the key with the other scripts in this community",
          returns: "`true`, or `false` and a reason when the key cap, the value size, the bucket " \
                   "name or a kept value's type refuses it",
          forms: [
            table_form(%(rubotty.remember{ bucket = "cards", key = rubotty.author(), value = card, ttl = 3600 }),
                       arg("bucket", "string", optional: true,
                           note: "shared by every script in this community, within this room, and may " \
                                 "not contain a colon. Left out, the key is private to this script"),
                       arg("key", "string", unit: "up to #{Memory::MAX_KEY_LENGTH} characters"),
                       arg("value", "any scalar, or a table",
                           unit: "up to #{Memory::MAX_VALUE_BYTES / 1024} KB once written down"),
                       arg("ttl", "number", unit: "seconds", optional: true,
                           note: "1 day by default, 30 days at most, and anything longer is clamped")),
            table_form(%(rubotty.remember{ bucket = "wallet", key = "ada", value = 100, ttl = "never" }),
                       arg("bucket", "string",
                           note: "required for a kept value, and shared across the whole community, " \
                                 "every room included"),
                       arg("key", "string"),
                       arg("value", "whole number",
                           note: "up to a billion either way"),
                       # Written out with its value, because the word IS what
                       # picks the store and a form named plainly "ttl" would
                       # render the same signature as the one above it.
                       arg(%(ttl = "never"), "the word itself",
                           note: "puts the value in the kept store, which has no expiry"))
          ]
        },
        "recall" => {
          summary: "Reads a value back out of the database, from whichever store `remember` put it in",
          returns: "the value, or `nil` when it expired or was never written",
          forms: [table_form(%(rubotty.recall{ bucket = "wallet", key = "ada" }),
                             arg("bucket", "string", optional: true), arg("key", "string"))]
        },
        "forget" => {
          summary: "Deletes a key from the database, whichever store holds it",
          returns: "`true` when a key was dropped, `false` when there was nothing there",
          forms: [table_form(%(rubotty.forget{ bucket = "wallet", key = "ada" }),
                             arg("bucket", "string", optional: true), arg("key", "string"))]
        },
        "add" => {
          summary: "Adds a whole number to a kept total, in one atomic database update. Give `by` a " \
                   "table instead of a number to credit several keys in one call, all of them moving " \
                   "or none",
          returns: "the total it is now for a single key, or `true` for a batch, or `false` and a " \
                   "reason when a bound, the key cap or the bucket name refuses it",
          forms: [
            table_form(
              %(rubotty.add{ bucket = "wallet", key = rubotty.author(), by = 5, floor = 0 }),
              arg("bucket", "string"),
              arg("key", "string", note: "opened at zero the first time you touch it"),
              arg("by", "whole number", unit: "count", optional: true,
                  note: "1 by default, and negative to take away"),
              arg("floor", "whole number", optional: true,
                  note: "refuses a change that would go below this"),
              arg("ceiling", "whole number", optional: true, note: "the same, going up")
            ),
            table_form(
              %(rubotty.add{ bucket = "scores", by = { [winner] = 10, [runner_up] = 5 }, floor = 0 }),
              arg("bucket", "string"),
              arg("by", "table", note: "key to whole number, every one credited together or not at all"),
              arg("floor", "whole number", optional: true,
                  note: "refuses the whole batch if any key would go below this"),
              arg("ceiling", "whole number", optional: true, note: "the same, going up")
            )
          ]
        },
        "move" => {
          summary: "Moves a whole number from one kept total to another, both sides in one transaction",
          returns: "`true`, or `false` and a reason when the giving side would go below the floor",
          forms: [table_form(
            %(rubotty.move{ bucket = "wallet", from = rubotty.author(), to = "pot", amount = 10 }),
            arg("bucket", "string"),
            arg("from", "string"), arg("to", "string"),
            arg("amount", "whole number", unit: "count"),
            arg("floor", "whole number", optional: true,
                note: "how low the giving side may go, 0 by default")
          )]
        },
        "top" => {
          summary: "The highest kept totals in a bucket, sorted by the database",
          returns: "a list of tables, each `{key, value}`, highest first",
          forms: [call_form(%(rubotty.top("wallet", 10)),
                            arg("bucket", "string"),
                            arg("limit", "whole number", unit: "count", optional: true,
                                note: "#{Memory::DEFAULT_TOP_LIMIT} by default, " \
                                      "#{Memory::MAX_TOP_LIMIT} at most"))]
        },
        "keys" => {
          summary: "The key names in a kept bucket",
          returns: "a list of strings, in order",
          forms: [call_form(%(rubotty.keys("wallet", "team:")),
                            arg("bucket", "string"),
                            arg("prefix", "string", optional: true,
                                note: "an empty prefix reads as the whole bucket"))]
        },
        "entries" => {
          summary: "A kept bucket's keys and their values together, key order rather than highest first",
          returns: "a list of tables, each `{key, value}`",
          forms: [call_form(%(rubotty.entries("trivia:5", "", 200)),
                            arg("bucket", "string"),
                            arg("prefix", "string", optional: true,
                                note: "an empty prefix reads as the whole bucket"),
                            arg("limit", "whole number", unit: "count", optional: true,
                                note: "#{Memory::DEFAULT_KEYS_LIMIT} by default, " \
                                      "#{Memory::MAX_KEYS_LIMIT} at most"))]
        },
        "count_keys" => {
          summary: "How many kept totals exist, for a script checking the cap",
          returns: "a whole number",
          forms: [call_form(%(rubotty.count_keys("wallet")),
                            arg("bucket", "string", optional: true,
                                note: "one bucket, or the whole community's kept totals when " \
                                      "you leave it out, which is what the cap counts"))]
        },
        "schedule" => {
          summary: "Runs a script in this community later, once or on a repeat",
          returns: "the booking's tag, which is a string, or `false` and a reason when the script is " \
                   "unknown, the repeat is out of shape, or the chain is out of hops",
          forms: [table_form(
            %(rubotty.schedule{ after = 60, data = { who = rubotty.author() } }),
            arg("script", "string", optional: true, note: "defaults to the script calling"),
            arg("after", "number", unit: "seconds from now", optional: true,
                note: "clamped to between 10 seconds and 30 days"),
            arg("at", "number", unit: "Unix epoch seconds", optional: true,
                note: "`rubotty.now().epoch` is the clock to add to"),
            arg("every", "number", unit: "seconds", optional: true,
                note: "books a wake every so often instead of one, and needs `until_at`. " \
                      "At least 10 seconds"),
            arg("until_at", "number", unit: "Unix epoch seconds", optional: true,
                note: "when the repeat stops, required with `every`, at most 30 days out"),
            arg("tag", "string", optional: true,
                note: "what to call this booking, so `unschedule` can find it. " \
                      "Made up for you when you leave it out"),
            arg("data", "table", optional: true, note: "read with `rubotty.invocation_data()` on the woken run")
          )]
        },
        "unschedule" => {
          summary: "Cancels the bookings this script made under a tag, before they come due",
          returns: "how many bookings were dropped, and `0` when the tag names nothing",
          forms: [call_form(%(rubotty.unschedule("round-timer")),
                            arg("tag", "string", note: "the tag `schedule` answered with"))]
        },
        "async_http" => {
          summary: "Calls an endpoint an administrator configured, then wakes a script with the answer",
          returns: "`true`, or `false` and a reason when the endpoint or the callback is unknown",
          forms: [table_form(
            %(rubotty.async_http{ endpoint = "weather", query = { city = rubotty.args() }, ) +
            %(then_call = "weather" }),
            arg("endpoint", "string", note: "the name on the Endpoints page, never a URL"),
            arg("query", "table", optional: true,
                note: "fills the endpoint's placeholders, and whatever is left over becomes the query string"),
            arg("body", "table", optional: true, note: "POST endpoints only, sent as YAML exactly as it stands"),
            arg("then_call", "string", optional: true, note: "the script to wake with the answer"),
            arg("data", "table", optional: true, note: "read with `rubotty.invocation_data()` on the woken run")
          )]
        },
        "increment_stat" => {
          summary: "Adds to one row of a stat shown on the scripts page. A script can write a stat " \
                   "and cannot read one back",
          returns: "`true`, or `false` and a reason when the stat is already at its row limit",
          forms: [call_form(
            %(rubotty.increment_stat("commands", "roll")),
            arg("stat", "string", note: "shared across the community, and no script can read it back"),
            arg("row", "string", unit: "up to 120 characters"),
            arg("step", "number", unit: "count", optional: true,
                note: "1 by default, and up to a million either way")
          )]
        },
        "record_stat" => {
          summary: "Sets one row of a stat to a value. A script can write a stat and cannot read one back",
          returns: "`true`, or `false` and a reason when the value is not a whole number or the stat is full",
          forms: [table_form(
            %(rubotty.record_stat{ stat = "queue", row = "waiting", value = 12 }),
            arg("stat", "string", note: "shared across the community, and no script can read it back"),
            arg("row", "string", unit: "up to 120 characters"),
            arg("value", "whole number", unit: "count", note: "up to a million either way")
          )]
        },
        "session" => {
          summary: "What the room is taking part in, if anything",
          returns: "a table of `{kind, label, state, opened_at, rounds}`, or `nil` when nothing is " \
                   "running here",
          forms: [call_form("rubotty.session()")]
        },
        "open_session" => {
          summary: "Starts a run of something the room joins in with",
          returns: "`true`, or `false` and a reason when something is already running in this room",
          forms: [table_form(
            %(rubotty.open_session{ kind = "trivia", label = "Friday quiz" }),
            arg("kind", "string",
                note: %(what it is, such as `"trivia"`, `"poll"`, `"survey"` or `"qa"`)),
            arg("label", "string", optional: true, note: "what to call it in the room")
          )]
        },
        "close_session" => {
          summary: "Ends the run, and whatever round is still open inside it",
          returns: "`true`, or `false` and a reason when nothing is running in this room",
          forms: [call_form("rubotty.close_session()")]
        },
        "round" => {
          summary: "The round the room is taking part in right now",
          returns: "a table of `{id, position, opened_at, closes_at, data}`, where `closes_at` is " \
                   "absent unless `open_round`'s `close_after` booked one, or `nil` when no round is open",
          forms: [call_form("rubotty.round()")]
        },
        "open_round" => {
          summary: "Opens the next round, closing the one before it. A round carries no concept of a " \
                   "prompt, an answer or who has replied; keep that in `data` and in your own bucket " \
                   "through `remember`, `add` and `entries`",
          returns: "`true`, or `false` and a reason when nothing is running, the session is out of " \
                   "rounds, or `close_after` is given with no `on_close` to wake",
          forms: [table_form(
            %(rubotty.open_round{ close_after = 45, on_close = "round_close", ) +
            %(data = { prompt = "Capital of Portugal?" } }),
            arg("close_after", "number", unit: "seconds", optional: true,
                note: "books the round's own close; leave it out and the round stays open until " \
                      "something else closes it"),
            arg("on_close", "string", optional: true,
                note: "the script `close_after` wakes, required whenever `close_after` is given"),
            arg("data", "table", optional: true,
                note: "read back from `rubotty.round().data`, and again on the `on_close` wake")
          )]
        },
        "close_round" => {
          summary: "Stops taking answers. Scoring and announcing are the script's own job against its " \
                   "own bucket, this only shuts the round",
          returns: "`true`, or `false` and a reason when no round is open",
          forms: [table_form(
            %(rubotty.close_round{ data = { winner = rubotty.args() } }),
            arg("data", "table", optional: true, note: "replaces the round's payload before it closes")
          )]
        },
        "name_participants" => {
          summary: "Display names for a list of participant ids, in one call, the way a round's own " \
                   "close reports several winners without a lookup per name",
          returns: "a table of id to display name, an id naming nobody here left out entirely",
          forms: [call_form(
            %(rubotty.name_participants{ ada_id, grace_id }),
            arg("ids", "table", note: "a plain list of ids, from `participant` or `resolve_participant`")
          )]
        }
      }.to_h { |name, spec| [name, Entry.new(name: name, **spec)] }.freeze

      # The ones served inside the child rather than over the pipe. Read off the
      # catalog rather than kept as a second list, so a getter added above is
      # one everywhere at once.
      GETTER_NAMES = CATALOG.select { |_name, entry| entry.getter }.keys.freeze

      # Everything else: what a {Registry} may actually be asked to serve.
      CALLABLE_NAMES = (CATALOG.keys - GETTER_NAMES).freeze

      # Everything in Markup::KINDS that is purely presentational. Mention is the
      # exception: it names somebody, so it is not offered to format().
      STYLE_KINDS = (Markup::KINDS.keys - ["mention"]).freeze

      # What each call is charged against the invocation's budget, decided
      # by the HANDLER so this lives beside rather than inside the catalog:
      # :free touches no service (string ops only), :broadcast reaches a
      # person (notify, post, whisper, react, warn, alert), and edit/delete
      # stay :read since they change something already in front of people
      # rather than adding something new. Anything unclassified defaults to :read.
      BY_COST = {
        free: %w[bold italic underline strikethrough spoiler code pre blockquote format
                 escape truncate mention] + GETTER_NAMES,
        broadcast: %w[notify post whisper react warn alert]
      }.freeze

      # name => cost, built once from the two lists above so a lookup is a hash
      # hit rather than two scans on every host call.
      COST_OF = BY_COST.flat_map { |cost, names| names.map { |name| [name, cost] } }.to_h.freeze

      # The catalog, arranged by what somebody is trying to do, for the editor
      # panel that explains these to a person who does not write Ruby.
      #
      # Grouped here rather than in the template so the page cannot list a
      # function the runtime does not have, or quietly omit a new one: anything
      # in CATALOG and not named below lands in "Everything else" rather than
      # disappearing.
      GROUPS = {
        "What you were handed" => %w[kind trigger text author author_is_operator origin_platform
                                     handle attachments reply_to room_key now command args
                                     matched hits window count minutes present invocation_data response wake_reason],
        "Reading a message" => %w[classify offending_spans link_verdict fold chars],
        "Knowing who somebody is" => %w[participant resolve_participant mention_participant name_participants],
        "Saying something" => %w[notify post edit delete react whisper warn alert mention truncate escape],
        "Styling a reply" => %w[bold italic underline strikethrough spoiler code pre blockquote format],
        "Remembering between messages" => %w[remember recall forget add move top keys entries count_keys],
        "Reading your own data file" => %w[yaml_data],
        "Reaching out, and coming back later" => %w[async_http schedule unschedule],
        "Asking about this community" => %w[rooms platforms room_capabilities features events
                                            feature_enabled community_stats],
        "Recording your own numbers" => %w[increment_stat record_stat],
        "Running a round" => %w[session open_session close_session round open_round close_round],
        "Odds and ends" => %w[random shuffle log build]
      }.freeze

      # What bounds the generated block in docs/scripting.md. Held here so the
      # rake task that writes the file and the spec that checks it read the same
      # two lines instead of each keeping a copy.
      DOC_BEGIN = "<!-- Generated from Scripting::HostFunctions::CATALOG. " \
                  "Run `bundle exec rake docs:scripting` after changing it. -->"
      DOC_END = "<!-- End of the generated host function reference. -->"

      module_function

      def names = CATALOG.keys

      # The names a {Registry} can be asked for. Everything else in the catalog
      # is a getter, which the child builds for itself out of the payload and
      # which therefore must never be offered as a host function: a name in both
      # lists would cross the pipe for an answer already sitting in the child.
      def callable_names = CALLABLE_NAMES

      # What the child builds locally. Sent with the sandbox spec, so this side
      # decides what a getter is and the child only assembles it.
      def getter_names = GETTER_NAMES

      def getter?(name) = GETTER_NAMES.include?(name.to_s)

      # GROUPS with the entries filled in and anything ungrouped swept up, so
      # the editor and the reference both render without knowing the
      # catalog's shape. The editor always calls this unnarrowed: a
      # deployment that runs scripts at all serves the whole catalog, and
      # spec/core/runtime_script_stats_wiring_spec.rb holds it to that.
      def grouped(available: names)
        offered = available.map(&:to_s)
        placed = GROUPS.values.flatten
        groups = GROUPS.to_h do |heading, entries|
          [heading, entries.select { |name| offered.include?(name) }.map { |name| CATALOG[name] }]
        end
        leftovers = offered.reject { |name| placed.include?(name) }.map { |name| CATALOG[name] }
        groups["Everything else"] = leftovers unless leftovers.empty?
        groups.reject { |_heading, entries| entries.empty? }
      end

      # The styling helpers, which need no services and are therefore always
      # available. Each returns an ordinary string, so a script concatenates and
      # nests them exactly as it would any other text; Ruby turns the sentinels
      # into RichText spans on the way out (see Scripting::Markup).
      def markup_handlers
        handlers = STYLE_KINDS.to_h do |kind|
          [kind, ->(text) { Markup.wrap(kind, text.to_s) }]
        end
        # A mention is a lookup rather than a style, so it normalises the handle
        # instead of wrapping whatever it was handed.
        handlers["mention"] = ->(name) { Markup.mention(name) }
        handlers["format"] = lambda do |text, styles = {}|
          styles = {} unless styles.is_a?(Hash)
          # Applied outermost first so the result nests in a stable order
          # whatever order the table happened to be written in.
          STYLE_KINDS.reverse.reduce(text.to_s) do |carried, kind|
            styles[kind] ? Markup.wrap(kind, carried) : carried
          end
        end
        handlers
      end

      def describe(name) = CATALOG[name.to_s]

      # Build a Registry serving whichever functions the caller can actually
      # back. A handler that is not supplied is simply not registered, so it is
      # not offered to the script and calling it is an ordinary nil error rather
      # than a stub that silently does nothing.
      #
      # @param handlers [Hash{String=>#call}] name to implementation
      # @param max_calls [Integer]
      # @param max_broadcasts [Integer]
      def registry(handlers:, max_calls: Registry::DEFAULT_MAX_CALLS,
                   max_broadcasts: Registry::DEFAULT_MAX_BROADCASTS)
        registry = Registry.new(max_calls: max_calls, max_broadcasts: max_broadcasts)
        handlers.each do |name, handler|
          # A getter is refused even with a handler behind it. The child builds
          # its own out of the payload, so one registered here would put the
          # same name in the sandbox twice and send a frame down the pipe for
          # something the child already had.
          next unless CATALOG.key?(name.to_s) && !getter?(name)

          registry.register(name.to_s, cost: cost_of(name)) { |*args| handler.call(*args) }
        end
        registry
      end

      # What one call of +name+ costs. Read from {COST_OF} so that every place a
      # registry is built agrees, including the save-time smoke test, which has
      # to charge the way production charges or the gate would pass a script
      # that runs out of broadcasts on its first real message.
      def cost_of(name) = COST_OF.fetch(name.to_s, :read)

      # Randomness comes from the host because math.random is absent from
      # the sandbox: a script that seeds its own generator is one the smoke
      # test cannot reproduce, and the generator is injected so production
      # hands over a real Random and the smoke test a seeded one. random(1,
      # 6) answers one number; random{count = ...} answers a list, since one
      # number per host call made drawing a hand cost more calls than an invocation is allowed.
      def random_handler(generator: Random.new)
        lambda do |*args|
          return random_batch(args.first, generator) if args.length == 1 && args.first.is_a?(Hash)

          low, high = bounds(args[0], args[1])
          generator.rand(low..high)
        end
      end

      # A list of whole numbers in range. `unique` draws without replacement,
      # and a count wider than the range is cut to the range rather than
      # refused: this answers a list, so it has no second return value to carry
      # a reason, and a hand of five from a range of three is a script's
      # arithmetic rather than an attack.
      def random_batch(spec, generator)
        low, high = bounds(spec["min"], spec["max"])
        count = (Integer(spec["count"], exception: false) || 1).clamp(1, MAX_RANDOM_COUNT)
        return unique_sample(low, high, count, generator) if spec["unique"]

        Array.new(count) { generator.rand(low..high) }
      end

      # A range no wider than MAX_RANDOM_COUNT is cheap to materialize and sample
      # from directly. Past that, a script's min/max is what decides how much
      # memory this allocates rather than the count it actually asked for, so a
      # wide range draws by rejection instead: count is already capped at
      # MAX_RANDOM_COUNT and the range here is wider than that, so a handful of
      # collisions before this finishes is the worst case, not a growing array.
      def unique_sample(low, high, count, generator)
        span = high - low + 1
        return (low..high).to_a.sample(count, random: generator) if span <= MAX_RANDOM_COUNT

        drawn = {}
        drawn[generator.rand(low..high)] = true while drawn.size < count
        drawn.keys
      end

      # min and max as whole numbers, the wrong way round accepted, since a
      # script computing a range from its own data should not have to sort it.
      def bounds(min, max)
        low = Integer(min, exception: false) || 0
        high = Integer(max, exception: false) || 0
        low > high ? [high, low] : [low, high]
      end

      # A new list in a new order, from the same host seeded generator. A Lua
      # sequence packs as a MessagePack array, and anything with a gap packs
      # as a map whose keys arrive as whatever type Lua used; either way
      # sequence() below reads it back in numeric key order, the only
      # reading of "shuffle this" a script can use.
      def shuffle_handler(generator: Random.new)
        lambda do |list|
          entries = sequence(list)
          entries.length > MAX_SHUFFLE_LENGTH ? entries : entries.shuffle(random: generator)
        end
      end

      def sequence(list)
        return list.dup if list.is_a?(Array)
        return [] unless list.is_a?(Hash)

        list.keys.sort_by { |key| Integer(key, exception: false) || Float::INFINITY }.map { |key| list[key] }
      end

      # Folding and splitting are pure text work with no services behind them,
      # so they are served everywhere the catalog is, including during a probe.
      # Both go through Features::TextFold, which is also what the word filter
      # compares with, so a script and the filter cannot disagree about whether
      # two spellings are the same word.
      def fold_handler = ->(text) { Features::TextFold.fold(text) }

      def chars_handler = ->(text) { Features::TextFold.chars(text) }

      # Debugging a script without this means guessing: there is no print, no io,
      # and the only other feedback is whether the whole invocation survived.
      def log_handler(logger:, script_name:)
        lambda do |text|
          logger&.info { "script #{script_name}: #{text}" }
          true
        end
      end

      # What the editor offers: same catalog, so autocomplete can never
      # suggest something the runtime does not serve. Two strings per
      # function, because CodeMirror shows them in two places: the detail
      # sits on the row itself and has to stay one line, while the info
      # panel opens beside the highlighted row, where the argument types and worked example fit without crowding the list.
      def completions(available: names)
        offered = available.map(&:to_s)
        Sandbox.completions(
          host_functions: CATALOG.select { |name, _| offered.include?(name) }
                                 .transform_values { |entry| { detail: detail(entry), info: info(entry) } }
        )
      end

      # "classify(text) -> "clean", "slur", "profanity" or "community""
      def detail(entry) = plain(%(#{entry.signatures.join(" or ")} -> #{entry.returns}))

      # The whole reference for one function, as plain text: what it does, its
      # arguments and their types, and a line that would really run.
      def info(entry)
        arguments = entry.described_arguments.empty? ? ["takes nothing"] : entry.described_arguments
        plain(["#{entry.summary}.", *arguments,
               "answers #{entry.returns}", "eg #{entry.samples.join("\n   ")}"].join("\n"))
      end

      # Markdown is the reference's native form, so the catalog is written with
      # backticks in it. The editor renders neither markdown nor HTML in these
      # two fields, so they come out bare.
      def plain(text) = text.delete("`")

      # The reference with its markers, which is exactly what sits in
      # docs/scripting.md between them.
      def reference = [DOC_BEGIN, "", markdown, DOC_END].join("\n")

      # +document+ with its generated block replaced. Both `rake docs:scripting`
      # and spec/scripting/documentation_spec.rb go through here, so the writer
      # and the check cannot disagree about what belongs between the markers.
      def rewrite(document)
        pattern = /#{Regexp.escape(DOC_BEGIN)}.*?#{Regexp.escape(DOC_END)}/m
        raise ArgumentError, "the document has no generated block to replace" unless document.match?(pattern)

        document.sub(pattern, reference)
      end

      # The generated half of docs/scripting.md: one table per group, then
      # the samples for that group as a block somebody can copy out.
      # Generated rather than written by hand because the reference drifted
      # from the catalog twice before anybody noticed: `rake docs:scripting`
      # rewrites it and spec/scripting/documentation_spec.rb fails while the
      # file and the catalog disagree, so a function cannot ship with a stale description.
      def markdown
        grouped.map { |heading, entries| markdown_group(heading, entries) }.join("\n")
      end

      def markdown_group(heading, entries)
        rows = entries.flat_map do |entry|
          entry.forms.map do |form|
            "| `#{form.signature(entry.name)}` | #{markdown_arguments(form)} | " \
              "#{entry.summary} | #{entry.returns} |"
          end
        end
        ["### #{heading}", "",
         "| Call | Arguments | What it does | Answers |", "| --- | --- | --- | --- |",
         *rows, "", "```lua", *entries.flat_map(&:samples), "```", ""].join("\n")
      end

      def markdown_arguments(form)
        return "none" if form.args.empty?

        form.args.map { |argument| "`#{argument.name}`: #{argument.qualified}" }.join("; ")
      end
    end
  end
end
