# frozen_string_literal: true

module Rubotty
  module Adapters
    module Irc
      # The pure part of IRC: parsing a line off the wire and splitting an
      # outbound message to fit the protocol's limits. No socket, no state.
      module Protocol
        # RFC 1459: a line is at most 512 bytes INCLUDING the trailing CR LF. The
        # server prepends our own "nick!user@host" prefix, of unknown length, when
        # it relays our PRIVMSG, so the payload budget leaves room for it.
        MAX_MESSAGE_BYTES = 400

        # Channels begin with one of these sigils.
        CHANNEL_SIGILS = %w[# & + !].freeze

        # Numeric replies a server sends instead of admitting us to a channel,
        # mapped to a human reason. There is deliberately no retry: repeating a
        # JOIN the server just refused would only spam it.
        JOIN_ERRORS = {
          "471" => "the channel is full (+l)",
          "473" => "invite only (+i); the bot needs an invite, or an op to /invite it",
          "474" => "the bot is banned from this channel",
          "475" => "wrong or missing channel key (+k)"
        }.freeze

        Line = Struct.new(:prefix, :nick, :command, :params, :trailing, :tags, keyword_init: true) do
          # The source nick, taken from the prefix "nick!user@host".
          def sender = nick

          def channel? = !params.empty? && Protocol.channel?(params.first)

          def target = params.first

          # A message tag's value, +true+ for IRCv3's valueless boolean form, or
          # nil when absent. {Protocol.parse} always sets +tags+ to a Hash, never
          # nil, so this is safe on every line, CAP negotiated or not.
          def tag(name) = tags[name.to_s]
        end

        # Escape sequences a tag VALUE may contain (IRCv3 message-tags), keyed by
        # the character following the backslash on the wire. Anything not in the
        # table loses just its backslash, per the spec's fallback.
        TAG_UNESCAPES = { ":" => ";", "s" => " ", "\\" => "\\", "r" => "\r", "n" => "\n" }.freeze

        # The reverse mapping, for a value going onto the wire. Semicolon and
        # space cannot appear literally in a tag value at all: they would be read
        # as the next tag, or the end of the tag list.
        TAG_ESCAPES = { "\\" => "\\\\", ";" => "\\:", " " => "\\s", "\r" => "\\r", "\n" => "\\n" }.freeze

        module_function

        def channel?(name) = CHANNEL_SIGILS.include?(name.to_s[0])

        # The one-line reason a JOIN was refused, or nil when +line+ is not one
        # of the numerics in {JOIN_ERRORS}.
        def join_failure(line)
          reason = JOIN_ERRORS[line.command]
          return nil unless reason

          channel = line.params[1] || "?"
          "IRC could not join #{channel}: #{reason}"
        end

        # Parse one raw line (without CR LF) into its parts; the message-tags prefix,
        # when present, comes before the source prefix ("@tags :prefix COMMAND ..."),
        # so it is peeled off first. A line with no tags gets an empty Hash, never nil.
        #
        #   ":ada!u@h PRIVMSG #room :hello world"
        #     -> prefix "ada!u@h", nick "ada", command "PRIVMSG",
        #        params ["#room"], trailing "hello world", tags {}
        def parse(raw)
          rest = raw.to_s.chomp
          tags = {}

          if rest.start_with?("@")
            tag_str, rest = rest[1..].split(" ", 2)
            tags = parse_tags(tag_str)
            rest = rest.to_s
          end

          prefix = nil
          nick = nil

          if rest.start_with?(":")
            prefix, rest = rest[1..].split(" ", 2)
            nick = prefix.to_s[/\A([^!@ ]+)/, 1]
          end

          command, rest = rest.to_s.split(" ", 2)
          trailing = nil
          params = []

          if rest
            if rest.start_with?(":")
              trailing = rest[1..]
            elsif (index = rest.index(" :"))
              params = rest[0...index].split(" ")
              trailing = rest[(index + 2)..]
            else
              params = rest.split(" ")
            end
          end

          Line.new(prefix: prefix, nick: nick, command: command.to_s.upcase, params: params,
                    trailing: trailing, tags: tags)
        end

        # Parse a raw "@k=v;k2=v2;flag" tag string (without the leading "@")
        # into a Hash. A tag with no "=value" is IRCv3's boolean form and
        # gets the value +true+; every other value is unescaped.
        def parse_tags(tag_str)
          tag_str.to_s.split(";").each_with_object({}) do |tag, tags|
            key, raw_value = tag.split("=", 2)
            next if key.to_s.empty?

            tags[key] = raw_value.nil? ? true : unescape_tag_value(raw_value)
          end
        end

        # Undo a tag value's wire escaping. An unrecognised escape sequence loses
        # only its backslash, and a malformed trailing backslash is dropped
        # rather than raising: a hostile peer must not crash the read loop.
        def unescape_tag_value(value)
          chars = value.to_s.each_char
          out = +""
          loop do
            char = chars.next
            if char == "\\"
              begin
                escaped = chars.next
              rescue StopIteration
                break
              end
              out << (TAG_UNESCAPES[escaped] || escaped)
            else
              out << char
            end
          end
          out
        end

        # Escape a value this adapter is about to SEND as a tag, the inverse of
        # {.unescape_tag_value}: semicolon ends a tag, space ends the tag list,
        # backslash starts an escape.
        def escape_tag_value(value)
          value.to_s.each_char.map { |char| TAG_ESCAPES[char] || char }.join
        end

        # Render a Hash of tags as the "@k=v;k2=v2 " wire prefix, including the
        # trailing space that separates it from the rest of the line. Empty or
        # nil input renders to "", so a caller can prepend it unconditionally.
        def render_tags(tags)
          return "" if tags.nil? || tags.empty?

          rendered = tags.map do |key, value|
            value == true || value.nil? ? key.to_s : "#{key}=#{escape_tag_value(value)}"
          end.join(";")
          "@#{rendered} "
        end

        # Parse one "CAP ... LS[ *] :cap1 cap2=value cap3" line's capability list
        # into a Hash of name to value (nil where the server advertised none).
        def parse_cap_list(trailing)
          trailing.to_s.split(" ").each_with_object({}) do |token, caps|
            name, value = token.split("=", 2)
            caps[name] = value
          end
        end

        # Whether more pages of a multiline "CAP ... LS" response follow: the
        # literal "*" parameter right after the LS subcommand, as in
        # "CAP * LS * :page one caps" then "CAP * LS :final page caps".
        def cap_continuation?(line) = line.params[2] == "*"

        # CTCP ACTION ("/me waves") is wrapped in \x01. Returns [text, action?].
        def strip_ctcp(text)
          match = text.to_s.match(/\A\x01ACTION (.*)\x01\z/)
          return [match[1], true] if match

          [text.to_s.delete("\x01"), false]
        end

        # Split a message into wire ready lines: hard newlines become separate
        # lines (IRC has no multi line message), and an over long line is
        # wrapped, preferring to break on a space so words stay whole.
        def split_message(text, max_bytes: MAX_MESSAGE_BYTES)
          text.to_s.split("\n", -1).flat_map { |line| wrap(line, max_bytes) }.reject(&:empty?)
        end

        def wrap(line, max_bytes)
          return [line] if line.bytesize <= max_bytes

          out = []
          current = +""
          line.split(" ").each do |word|
            candidate = current.empty? ? word : "#{current} #{word}"
            if candidate.bytesize <= max_bytes
              current = candidate
            else
              out << current unless current.empty?
              # Split on character boundaries so a multi byte character is never
              # cut in half.
              if word.bytesize <= max_bytes
                current = word
              else
                chunks = char_chunks(word, max_bytes)
                out.concat(chunks[0...-1])
                current = chunks.last || +""
              end
            end
          end
          out << current unless current.empty?
          out
        end

        # Break an over long unbreakable token into pieces that each fit the byte
        # budget, splitting between characters.
        def char_chunks(word, max_bytes)
          chunks = []
          current = +""
          word.each_char do |char|
            if (current.bytesize + char.bytesize) > max_bytes
              chunks << current unless current.empty?
              current = +""
            end
            current << char
          end
          chunks << current unless current.empty?
          chunks
        end
      end
    end
  end
end
