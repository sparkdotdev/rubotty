# frozen_string_literal: true

require "base64"

module Rubotty
  module Scripting
    # An opaque token naming one logical message: every platform copy of it.
    # Encoded as a string since the only place a script can hold anything
    # between invocations is a memo, which holds strings; it carries raw
    # (endpoint, native id) pairs rather than a stored row, since the
    # platform's own ids already survive a restart on their own. Base64 is
    # not secrecy, just escaping for ids with awkward characters. It is NOT
    # a capability: forging one is trivial, so every call that takes a
    # handle checks its endpoints belong to the room the script is running in.
    module Handle
      # Stamped inside the token so a later format can be told apart from this
      # one rather than being misread as a corrupt version of it.
      VERSION = "r1"

      # Between one ref's endpoint and its native id, and between refs. Both
      # are control characters, which is what makes them safe against ids that
      # contain punctuation.
      FIELD = "\t"
      RECORD = "\n"

      # How many copies one handle may name. A room spanning more platforms
      # than this does not exist, and the cap is what stops a forged handle
      # naming ten thousand messages for one call to walk.
      MAX_REFS = 32

      # One copy, as this module reads and writes one. Deliberately not
      # Core::MessageRef, so encoding a handle needs nothing from Core and
      # this namespace stays loadable and tested on its own; a caller that
      # wants a real MessageRef builds one from these two fields.
      Ref = Data.define(:endpoint_id, :native_id)

      module_function

      # @param refs [Array<#endpoint_id, #native_id>, #endpoint_id, nil] a
      #   Core::MessageRef, a {Ref}, or a list of either
      # @return [String] "" when there is nothing to name, which is what a post
      #   that reached no platform answers
      def of(refs)
        # Not Array(), which asks a ref for #to_a and gets its two fields as
        # two entries, so one ref arrived here as two broken ones.
        given = refs.is_a?(Array) ? refs : [refs]
        pairs = given.compact.first(MAX_REFS).map do |ref|
          "#{ref.endpoint_id}#{FIELD}#{ref.native_id}"
        end
        return "" if pairs.empty?

        Base64.urlsafe_encode64([VERSION, *pairs].join(RECORD), padding: false)
      end

      # The refs a handle names, or [] for anything this does not recognise.
      # Empty rather than raising, since a handle from a script may have been
      # typed, truncated by a memo, or kept from a build with a different
      # version, and every caller already has to handle "names nothing" anyway.
      #
      # @param handle [String, nil]
      # @return [Array<Ref>]
      def refs(handle)
        text = handle.to_s
        return [] if text.empty?

        decoded = Base64.urlsafe_decode64(text)
        version, *pairs = decoded.split(RECORD)
        return [] unless version == VERSION

        pairs.first(MAX_REFS).filter_map { |pair| ref_from(pair) }
      rescue ArgumentError
        []
      end

      def ref_from(pair)
        endpoint_id, native_id = pair.split(FIELD, 2)
        return nil if endpoint_id.to_s.empty? || native_id.to_s.empty?

        Ref.new(endpoint_id: endpoint_id, native_id: native_id)
      end
    end
  end
end
