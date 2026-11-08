# frozen_string_literal: true

module Rubotty
  module Features
    # Relay a Telegram sender's own profile photo, so a message crossing into
    # a room that puppets its senders arrives with the right face as well as
    # the right name. Telegram serves the photo from a URL with the bot token
    # in its path, which {Util::SafeUrl} refuses to hand out, so the picture
    # is copied into {Storage::ObjectStore} and the public download link goes
    # out instead. Observes nothing: the Telegram adapter checks this itself
    # rather than through the pipeline, and it defaults off since it stores a
    # member's picture on rubotty's own disk.
    class TelegramAvatars < Base
      def self.feature_name = "telegram_avatars"

      def self.description
        "Relay a Telegram sender's real profile photo, by keeping a copy rubotty can serve."
      end

      def self.default_enabled? = false

      def self.observes = [].freeze

      def self.config_schema
        Config::Schema.define do
          field :retention_days, :integer, default: ControlPlane::RehostedFiles::DEFAULT_AVATAR_TTL_DAYS,
                desc: "how long a copied profile photo is kept before its bytes are deleted, in " \
                      "days (default #{ControlPlane::RehostedFiles::DEFAULT_AVATAR_TTL_DAYS}, " \
                      "capped at #{ControlPlane::RehostedFiles::MAX_TTL_DAYS}). " \
                      "A copy is remade well before it lapses, for as long as the person keeps " \
                      "talking."
        end
      end

      # Shown on the dashboard page where an operator ticks this on.
      def self.retention_notice
        "Switching this on makes rubotty keep a copy of a Telegram sender's PROFILE PHOTO: the " \
          "picture is written to rubotty's own disk, compressed and encrypted, and the link to it " \
          "is what the other platforms show beside their messages. Only senders in this " \
          "community's Telegram rooms, only the photo Telegram already shows to the room, and " \
          "nothing else about them. A Telegram-only room has nowhere to show the picture, so " \
          "nothing is fetched or stored there even with this on; it only does something once a " \
          "second platform puppets that room. A copy is kept for " \
          "#{ControlPlane::RehostedFiles::DEFAULT_AVATAR_TTL_DAYS} days by default (retention_days, at " \
          "most #{ControlPlane::RehostedFiles::MAX_TTL_DAYS}), after which the same daily job that " \
          "clears rehosted files deletes the bytes and the row. Anyone holding a link can fetch " \
          "the picture until then, with no account and no membership check. Switching the feature " \
          "off stops new copies being kept and returns senders to the bot's own avatar; anything " \
          "already held expires on the retention it was stored under."
      end

      # This community's retention, in days, from the resolved feature config.
      def self.retention_days(config)
        value = config_value(config, :retention_days)
        value.nil? ? ControlPlane::RehostedFiles::DEFAULT_AVATAR_TTL_DAYS : value.to_i
      end

      # Feature config arrives with string keys from the database and symbol keys
      # from a code default, so both are tried.
      def self.config_value(config, key)
        return nil unless config.respond_to?(:[])

        value = config[key.to_s]
        value.nil? ? config[key.to_sym] : value
      end
    end
  end
end
