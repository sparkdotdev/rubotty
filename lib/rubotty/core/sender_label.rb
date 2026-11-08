# frozen_string_literal: true

module Rubotty
  module Core
    # The cross platform label that identifies who sent a relayed message:
    # `<b>display name</b> [username@platform]`, or `<b>username</b>@platform`
    # when there is no distinct display name. It stays a value object since
    # bold is expressed differently on every platform and only the target
    # adapter knows which; a federated adapter's `protocol` prefixes the
    # handle with a double colon (`matrix::ada@example.org`). Free text a
    # member controls has any run of two or more colons collapsed to one on
    # the way in (see `#guard`), so it can never forge the `::` separator.
    class SenderLabel
      # The fixed pseudo-platform a guest-portal sender is tagged with, so their
      # label reads "<b>Nickname</b>@guest-user".
      GUEST_DOMAIN = "guest-user"

      # The fixed pseudo-platform a message posted through the REST admin API is
      # tagged with. Distinct from {GUEST_DOMAIN} so a moderator reading the room
      # can tell a person somebody invited from a credential somebody issued.
      API_DOMAIN = "api-client"

      # Matches a run of two or more colons, which `#guard` collapses onto one.
      IMPERSONATION_GUARD = /:{2,}/

      # Three literal dots, never the single character ellipsis: that glyph is a
      # different width in every font a target platform might render {.shorten}'s
      # result in.
      ELLIPSIS = "..."

      attr_reader :username, :platform, :display_name, :name, :guest, :api, :protocol

      # @param name [String, nil] a guaranteed non empty last resort identifier,
      #   used only when there is neither a username nor a display name
      # @param guest [Boolean] a guest-portal sender, always rendered as
      #   "<b>primary</b>@guest-user" whatever the other fields hold
      # @param api [Boolean] a REST-API sender, the same fixed-domain treatment
      #   under {API_DOMAIN}; kept separate from +guest+ for moderation and audit.
      # @param protocol [String, nil] the federated protocol qualifier, supplied
      #   by a federated origin adapter only; nil for a centralized platform.
      def initialize(username: nil, platform: nil, display_name: nil, name: nil, guest: false,
                     api: false, protocol: nil)
        @username = guard(username)
        @platform = presence(platform)
        @display_name = guard(display_name)
        @name = guard(name)
        @guest = !!guest
        @api = !!api
        @protocol = presence(protocol)
        freeze
      end

      # Build the label for a guest-portal sender. The inviter-set nickname takes
      # the bold identity position.
      def self.guest(nickname:)
        new(username: nickname, platform: GUEST_DOMAIN, guest: true)
      end

      def guest? = @guest

      # Builds the label for someone who chose the name they are bridged as:
      # the nickname leads, in the position a real display name takes, and
      # the handle still follows in brackets, since choosing a name says
      # what to call somebody, never who they are. With no handle to
      # attribute it to, the nickname carries the platform on its own.
      def self.nickname(nickname:, platform:, username: nil, protocol: nil)
        new(username: username, display_name: nickname, platform: platform, protocol: protocol)
      end

      # Build the label for a message posted through the REST admin API, from the
      # key's operator-set label (or its public id when that is blank).
      def self.api(label:)
        new(username: label, platform: API_DOMAIN, api: true)
      end

      def api? = @api

      # Build a label from an author, the origin platform label and, for a
      # federated platform, its protocol qualifier.
      def self.for(author:, platform:, protocol: nil)
        new(
          username: author&.username,
          platform: platform,
          display_name: author&.profile_name,
          name: author&.any_name,
          protocol: protocol
        )
      end

      # The identifier that gets the bold treatment, nil only for an empty label.
      def primary
        username || display_name || name
      end

      def empty? = primary.nil?

      # Render as target platform markup. The two callables localise the only
      # platform specific parts; the shape is decided here.
      #
      # @param escape [#call] String to String, escapes plain text for the target
      # @param bold [#call] String to String, wraps ALREADY ESCAPED text in the
      #   target platform's bold markup
      # @return [String] may be empty when the label carries nothing
      def render(escape:, bold:)
        return "" if empty?

        # A guest or API sender never takes the "display [handle]" form: the
        # primary leads, bold, and the fixed domain always follows.
        fixed = fixed_domain
        if fixed
          lead = bold.call(escape.call(primary))
          return "#{lead}@#{escape.call(fixed)}"
        end

        if display_name && username && display_name != username
          # A distinct human name leads and is bold, the precise handle follows in
          # brackets: "Ada L [matrix::ada@example.org]".
          "#{bold.call(escape.call(display_name))} [#{handle_tag(escape)}]"
        else
          # No distinct display name, or no username: the handle itself is the
          # identity, with the protocol qualifier (plain) leading the whole thing
          # when there is one, "matrix::<b>ada</b>@example.org".
          lead = bold.call(escape.call(username || display_name || name))
          platform ? "#{qualifier_prefix(escape)}#{lead}@#{escape.call(platform)}" : lead
        end
      end

      # The bracketed handle: "protocol::username@platform", "username@platform",
      # or bare "username". Only called where a username is present.
      def handle_tag(escape)
        tagged = platform ? "#{escape.call(username)}@#{escape.call(platform)}" : escape.call(username)
        "#{qualifier_prefix(escape)}#{tagged}"
      end
      private :handle_tag

      # The "protocol::" prefix, or "" for a label with no protocol. Always plain
      # text: the qualifier decorates the handle and never joins the bold identity.
      def qualifier_prefix(escape)
        protocol ? "#{escape.call(protocol)}::" : ""
      end
      private :qualifier_prefix

      # A plain text rendering with no markup, for places that carry the sender
      # identity out of band: a Discord webhook username, an embed author, logs.
      def to_s
        render(escape: ->(text) { text }, bold: ->(text) { text })
      end

      # Where the bold falls in an ALREADY RENDERED plain label. The inverse of
      # {#render}: the parts render as `#{prefix}<b>#{lead}</b>#{rest}` and rejoin
      # to exactly the string passed in.
      #
      # @return [Array(String, String, String)] prefix, lead, rest
      def self.split(label)
        text = label.to_s
        return ["", "", ""] if text.empty?

        # "Display Name [handle@platform]", matched from the END: a display name
        # is free text and only the last bracket can be the one this class added.
        if text.end_with?("]") && (open = text.rindex(" ["))
          return ["", text[0, open], text[open..]]
        end

        # "protocol::lead@platform", "lead@platform", or a bare identity, at the
        # LAST @. The protocol qualifier is the only "::" that survives the guard.
        head, at, tail = text.rpartition("@")
        head, at, tail = [text, "", ""] if at.empty?
        prefix, colons, lead = head.rpartition("::")

        ["#{prefix}#{colons}", lead, "#{at}#{tail}"]
      end

      # Shortens an already rendered label to fit a hard character cap a
      # target platform enforces, eating into the bold identity but leaving
      # the bracketed handle whole, since the handle is what tells a reader
      # where a puppeted speaker is actually posting from and cannot survive
      # being cut in half the way the identity can.
      #
      # @return [String] +text+ unchanged, or a copy no longer than +limit+
      def self.shorten(text, limit)
        string = text.to_s
        return string if string.length <= limit

        prefix, lead, rest = split(string)
        room = limit - prefix.length - rest.length - ELLIPSIS.length
        return string[0, limit] if room.negative?

        "#{prefix}#{lead[0, room]}#{ELLIPSIS}#{rest}"
      end

      def ==(other)
        other.is_a?(SenderLabel) &&
          other.username == username &&
          other.platform == platform &&
          other.display_name == display_name &&
          other.name == name &&
          other.guest == guest &&
          other.api == api &&
          other.protocol == protocol
      end
      alias eql? ==

      def hash = [username, platform, display_name, name, guest, api, protocol].hash

      def inspect = "#<SenderLabel #{to_s.inspect}>"

      private

      # The pseudo-platform this label is pinned to, or nil for an ordinary
      # sender. Guest wins over api, which neither factory can produce anyway.
      def fixed_domain
        return GUEST_DOMAIN if guest?
        return API_DOMAIN if api?

        nil
      end

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end

      # Collapses any run of two or more colons down to one, so free text a member
      # controls can never contain the literal "::" the protocol qualifier depends
      # on. A regex, since a plain `gsub("::", ":")` leaves "::" behind on "::::".
      def guard(value)
        text = presence(value)
        text&.gsub(IMPERSONATION_GUARD, ":")
      end
    end
  end
end
