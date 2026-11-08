# frozen_string_literal: true

module Rubotty
  module Scripting
    # The Teal declaration file every Teal script is checked against. Without
    # it the checker reports "unknown variable: rubotty" on every script and
    # nothing else, so the annotations become decorative. Generated from the
    # same CATALOG the registry and the editor read, so a function added
    # there is type checked here, getters included, without anybody
    # remembering.
    module TealDefinitions
      # Host functions whose argument and return types are worth stating. The
      # rest fall back to a permissive signature, because a wrong guess here
      # would refuse a script that is actually fine, which is worse than not
      # checking it.
      SIGNATURES = {
        # What the invocation was handed. Declared as the type it has when
        # answered at all; Teal lets nil stand in for any type, which is what
        # makes `if not rubotty.text() then` read correctly on a woken run,
        # where there is no message.
        "text" => "function(): string",
        "author" => "function(): string",
        "author_is_operator" => "function(): boolean",
        "origin_platform" => "function(): string",
        "attachments" => "function(): {Attachment}",
        "reply_to" => "function(): ReplyTo",
        "handle" => "function(): string",
        "room_key" => "function(): string",
        "now" => "function(): Now",
        "kind" => "function(): string",
        "trigger" => "function(): string",
        "command" => "function(): string",
        "args" => "function(): string",
        "matched" => "function(): {string}",
        "hits" => "function(): integer",
        "window" => "function(): integer",
        "count" => "function(): integer",
        "minutes" => "function(): integer",
        "present" => "function(): {string}",
        # A wake's data and an endpoint's answer are both shapes the script
        # decides, so the map is declared and a script casts what it reaches
        # inside it, the same bargain yaml_data makes.
        "invocation_data" => "function(): {string:any}",
        "response" => "function(): Response",
        "wake_reason" => "function(): string",
        "classify" => "function(string): string",
        "link_verdict" => "function(string): string",
        "feature_enabled" => "function(string): boolean",
        "may" => "function(string): boolean",
        "rooms" => "function(): {string}",
        "platforms" => "function(): {string}",
        "features" => "function(): {string}",
        "notify" => "function(string): boolean",
        # The mode is optional and defaults to quiet, so both alert(text) and
        # alert(text, "loud") have to type check. An unknown mode is refused at
        # run time, which is where the answer can name what was wrong.
        "alert" => "function(string, ...: string): (boolean, string)",
        "warn" => "function(string): boolean",
        "log" => "function(string): boolean",
        # Folding and splitting are pure text work with fixed shapes.
        "fold" => "function(string): string",
        "chars" => "function(string): {string}",
        # random(1, 6) is one number and random{count = 5, ...} is a list, so
        # neither a fixed argument list nor a single return type covers both.
        # `any` is what lets a script write either and cast the one it meant,
        # the same bargain yaml_data already makes.
        "random" => "function(...: any): any",
        "shuffle" => "function({any}): {any}",
        # The step is optional, and one row of a stat is often just counted.
        "increment_stat" => "function(string, string, ...: integer): (boolean, string)",
        "record_stat" => "function({string:any}): (boolean, string)",
        "community_stats" => "function(): {string:any}",
        # A data file is a set of keys or a list, and Teal has no way to say
        # "either": the map is declared since it's the shape most data files
        # have, and a list is reached with `rubotty.yaml_data() as {string}`,
        # which is what the docs teach.
        "yaml_data" => "function(): {string:any}",
        "truncate" => "function(string): string",
        "escape" => "function(string): string",
        "mention" => "function(string): string",
        "mention_participant" => "function(string): string",
        "name_participants" => "function({string}): {string:string}",
        # Both answer nil for "nobody, or too many to be sure", which Teal has
        # no way to say. A record type is what lets `who.id` type check at all,
        # and the nil case is a runtime check the docs teach.
        "participant" => "function(): Participant",
        "resolve_participant" => "function(string): Participant",
        "whisper" => "function({string:any}): (boolean, string)",
        # post answers a handle, or false and a reason. Declared as the shape
        # it has when it worked, since a Teal script that could not hold the
        # handle in a string could not use the function at all; `if not h then`
        # still type checks, which is the check the docs teach.
        "post" => "function({string:any}): (string, string)",
        "edit" => "function(string, string): (boolean, string)",
        "delete" => "function(string): (boolean, string)",
        "react" => "function(string, string): (boolean, string)",
        # The store. Everything that names a bucket, a key and something else
        # takes one table, so all three declare the same way; remember
        # answers false and a reason on a refusal, which `if not ok then`
        # reads correctly against the boolean declared here.
        "remember" => "function({string:any}): (boolean, string)",
        "recall" => "function({string:any}): any",
        "forget" => "function({string:any}): boolean",
        # add answers the new total, or false and a reason. Declared as the
        # shape it has when it worked, the same bargain post makes: a Teal
        # script that could not hold the total in a number could not use the
        # function at all, and `if not total then` still type checks.
        "add" => "function({string:any}): (integer, string)",
        "move" => "function({string:any}): (boolean, string)",
        # The limit and the prefix are both optional, so both of these take one
        # name or two.
        "top" => "function(string, ...: integer): {Tally}",
        "keys" => "function(string, ...: string): {string}",
        # entries takes a prefix and a limit, a string then an integer, so
        # unlike top and keys the trailing pair cannot share one vararg type.
        "entries" => "function(string, string, integer): {Tally}",
        "count_keys" => "function(...: string): integer",
        "unschedule" => "function(string): integer",
        "room_capabilities" => "function(): RoomCapabilities",
        # A round: session and round answer records so a field name is
        # checked; the writers take a table or nothing and answer the same
        # (worked, why not) pair every other refusal uses.
        "session" => "function(): Session",
        "open_session" => "function({string:any}): (boolean, string)",
        "close_session" => "function(): (boolean, string)",
        "round" => "function(): Round",
        "open_round" => "function({string:any}): (boolean, string)",
        "close_round" => "function({string:any}): (boolean, string)"
      }.freeze

      STYLE = %w[bold italic underline strikethrough spoiler code pre blockquote].freeze

      module_function

      # The shapes a getter or a host function hands back: records rather
      # than maps wherever the keys are ours, since that is what lets
      # `who.id` type check at all. There is no Message record any more:
      # every field a script was once handed on a vararg table is now its
      # own call, typed beside it in SIGNATURES above.
      def payload_records
        <<~TEAL
          global record Now
            epoch: integer
            hour: integer
            minute: integer
            wday: integer
            day: integer
            month: integer
            year: integer
            iso: string
            tz: string
          end

          global record Span
            from: integer
            to: integer
            category: string
            part_of_speech: string
          end

          global record Event
            title: string
            starts_at: string
            starts_in: integer
            room: string
            rsvp_count: integer
          end

          global record Attachment
            kind: string
            filename: string
            bytes: integer
            content_type: string
            ref: string
          end

          global record ReplyTo
            handle: string
            author: string
            text: string
          end

          global record Participant
            id: string
            display: string
            platform: string
            is_operator: boolean
          end

          global record Response
            status: integer
            ok: boolean
            body: string
            data: {string:any}
            format: string
          end

          global record Verdict
            action: string
            reason: string
            text: string
            reply: string
          end

          global record Tally
            key: string
            value: integer
          end

          global record RoomCapabilities
            reactions: boolean
            edit: boolean
            delete: boolean
            reply: boolean
            threads: boolean
            private_message: boolean
            longest_message: integer
          end

          global record Session
            kind: string
            label: string
            state: string
            opened_at: integer
            rounds: integer
          end

          global record Round
            id: integer
            position: integer
            opened_at: integer
            closes_at: integer
            data: {string:any}
          end
        TEAL
      end

      def rubotty_record
        lines = ["global record Rubotty"]
        STYLE.each { |name| lines << "  #{name}: function(string): string" }
        lines << "  format: function(string, {string:boolean}): string"
        lines << "  offending_spans: function(string): {Span}"
        lines << "  events: function(): {Event}"
        lines << "  build: function(): {string:string}"
        # schedule answers the booking's tag, which unschedule then takes, so it
        # is declared as a string rather than a boolean. A refusal answers false
        # and a reason, and `if not tag then` reads that correctly either way.
        lines << "  schedule: function({string:any}): (string, string)"
        lines << "  async_http: function({string:any}): (boolean, string)"
        SIGNATURES.each { |name, signature| lines << "  #{name}: #{signature}" }
        lines << "end"
        lines.join("\n")
      end

      # What is written next to a script before `tl check` runs.
      def to_s
        [payload_records, rubotty_record, "", "global rubotty: Rubotty", ""].join("\n")
      end

      # Names the declaration mentions, so a spec can hold it to the catalog.
      # Matched on "function(" so a payload record's own field never counts.
      def declared
        to_s.scan(/^ {2}([a-z_]+): function\(/).flatten.uniq
      end
    end
  end
end
