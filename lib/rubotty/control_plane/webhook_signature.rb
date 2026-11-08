# frozen_string_literal: true

require "openssl"
require "base64"
require "securerandom"

module Rubotty
  module ControlPlane
    # Signs and verifies a webhook per the Standard Webhooks specification;
    # the header names below are the spec's, not choices made here.
    # webhook-id doubles as the dedup key, webhook-timestamp is unix seconds
    # as text, webhook-signature is one or more space-delimited "v1,<base64>"
    # entries. The signed content is "#{id}.#{timestamp}.#{payload}", so
    # neither a replayed id/timestamp nor a rewritten body verifies; the
    # header carries a list so {.header_value} can sign with an old and a
    # new secret during a rotation overlap window.
    module WebhookSignature
      # The scheme identifier the format puts before each signature.
      VERSION = "v1"

      # The spec's prefix for a symmetric signing secret.
      PREFIX = "whsec_"

      # Bytes of entropy behind a generated secret, what the reference
      # implementations mint.
      SECRET_BYTES = 24

      # How far a delivery's timestamp may be from the verifier's clock. Five
      # minutes each way is the spec's recommendation.
      TOLERANCE = 5 * 60

      ID_HEADER = "webhook-id"
      TIMESTAMP_HEADER = "webhook-timestamp"
      SIGNATURE_HEADER = "webhook-signature"

      module_function

      # A fresh signing secret in the spec's own format.
      def generate_secret = "#{PREFIX}#{Base64.strict_encode64(SecureRandom.bytes(SECRET_BYTES))}"

      # The bytes actually used as the HMAC key. A prefixed secret is decoded;
      # anything else is used as-is, and a prefixed value that is not valid base64
      # falls back to the literal text rather than raising.
      def key_bytes(secret)
        text = secret.to_s
        return text unless text.start_with?(PREFIX)

        body = text.delete_prefix(PREFIX)
        begin
          Base64.strict_decode64(body)
        rescue ArgumentError
          text
        end
      end

      # The content the HMAC covers.
      def signed_content(id:, timestamp:, payload:) = "#{id}.#{timestamp}.#{payload}"

      # One "v1,<base64>" entry for one secret.
      def sign(secret:, id:, timestamp:, payload:)
        digest = OpenSSL::HMAC.digest(
          "SHA256", key_bytes(secret), signed_content(id: id, timestamp: timestamp, payload: payload)
        )
        "#{VERSION},#{Base64.strict_encode64(digest)}"
      end

      # The whole webhook-signature header: one entry per secret, space delimited,
      # in the order given. A blank secret is dropped rather than signed with.
      def header_value(secrets:, id:, timestamp:, payload:)
        Array(secrets).map(&:to_s).reject(&:empty?).uniq
                      .map { |secret| sign(secret: secret, id: id, timestamp: timestamp, payload: payload) }
                      .join(" ")
      end

      # The three headers a delivery carries, ready to set on a request.
      def headers(secrets:, id:, timestamp:, payload:)
        {
          ID_HEADER => id.to_s,
          TIMESTAMP_HEADER => timestamp.to_i.to_s,
          SIGNATURE_HEADER => header_value(secrets: secrets, id: id, timestamp: timestamp, payload: payload)
        }
      end

      # Verify a delivery the way a subscriber would; not used on any send path.
      # Passes when ANY entry in the header matches the expected signature for
      # +secret+, which is what makes an overlap window work from the
      # receiving end.
      #
      # @param now [Time] the verifier's clock, for the staleness bound
      # @return [Boolean]
      def verify(secret:, id:, timestamp:, payload:, header:, now: Time.now)
        return false if (now.to_i - timestamp.to_i).abs > TOLERANCE

        expected = sign(secret: secret, id: id, timestamp: timestamp, payload: payload)
        header.to_s.split(/\s+/).reject(&:empty?).any? do |candidate|
          # Constant time, so a verifier built from this cannot be turned into an
          # oracle that leaks the expected signature a byte at a time.
          candidate.bytesize == expected.bytesize && OpenSSL.secure_compare(candidate, expected)
        end
      end
    end
  end
end
