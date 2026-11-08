# frozen_string_literal: true

module Rubotty
  module Features
    # Rehost a file the target platform will not take: the file goes into
    # {Storage::ObjectStore} and a download link is posted to that target
    # instead. Observes nothing, so the pipeline never runs it directly;
    # {Features::Bridge} and {Features::UploadCommand} check it themselves.
    # Off by default because it stores member file content on rubotty's own
    # disk.
    class FileRehosting < Base
      # What to do with a file the target will not take. A photo and a contract
      # want different answers, so the community picks.
      STRATEGIES = %i[link shrink shrink_then_link].freeze

      # Linking is what this feature has always done, so a community that never
      # touches the setting sees exactly what it saw before the setting existed.
      DEFAULT_STRATEGY = :link

      def self.feature_name = "file_rehosting"

      def self.description
        "Mirror a file too big for a platform into rubotty's store and post a link instead, for any " \
          "file rubotty can actually fetch: a platform draws its own ceiling on what a bot may " \
          "download, separate from what it may keep, and one file past that ceiling never had bytes " \
          "to rehost."
      end

      def self.default_enabled? = false

      def self.observes = [].freeze

      def self.config_schema
        Config::Schema.define do
          field :strategy, :symbol, default: DEFAULT_STRATEGY, one_of: STRATEGIES,
                desc: "what to do with a file the target platform will not take: link it " \
                      "(the default), shrink it to fit, or shrink it and link it when it will " \
                      "not come down far enough. Shrinking re encodes an image, which drops " \
                      "its EXIF metadata including any GPS fix. See PRIVACY.md."
          field :rehost_inbound, :boolean, default: true,
                desc: "whether an oversized inbound file the bridge sees is mirrored " \
                      "automatically. Off leaves it alone; the /upload command is unaffected."
          field :enable_upload_command, :boolean, default: true,
                desc: "whether a member's own /upload command is available. Off refuses it; " \
                      "automatic inbound mirroring is unaffected."
          field :retention_days, :integer, default: ControlPlane::RehostedFiles::DEFAULT_TTL_DAYS,
                desc: "how long a rehosted file is kept before its bytes are deleted, in days " \
                      "(default #{ControlPlane::RehostedFiles::DEFAULT_TTL_DAYS}, capped at " \
                      "#{ControlPlane::RehostedFiles::MAX_TTL_DAYS})"
          field :max_bytes, :integer, default: ControlPlane::RehostedFiles::DEFAULT_MAX_BYTES,
                desc: "the largest file this community will rehost, in bytes. A file over the " \
                      "cap is left alone and the relay behaves as it does with this feature off."
          field :quota_bytes, :integer, default: ControlPlane::RehostedFiles::DEFAULT_QUOTA_BYTES,
                desc: "the most this community may have stored in rehosted files at once, in " \
                      "bytes (default #{FileRehosting.gib(ControlPlane::RehostedFiles::DEFAULT_QUOTA_BYTES)}). " \
                      "A file that would push the total over this quota is refused even when it " \
                      "is under max_bytes on its own; see the Files page for current usage."
          field :max_batch_files, :integer, default: ControlPlane::RehostedFiles::DEFAULT_MAX_BATCH_FILES,
                desc: "the most files one /upload selection may carry at once (default " \
                      "#{ControlPlane::RehostedFiles::DEFAULT_MAX_BATCH_FILES})"
          field :max_batch_bytes, :integer, default: 0,
                desc: "the most total bytes one /upload selection may carry across every file in " \
                      "it. 0 means #{ControlPlane::RehostedFiles::DEFAULT_BATCH_BYTES_MULTIPLIER} " \
                      "times max_bytes, so one file at the per file cap always fits but a full " \
                      "batch of files at that cap does not."
          field Core::CommandAck::TTL_FIELD, :integer, default: Core::CommandAck::DEFAULT_TTL_SECONDS,
                                                       desc: "seconds a /upload reply lives before it " \
                                                             "self-deletes. 0 leaves it in place."
          field Core::CommandAck::DELETE_COMMAND_FIELD, :boolean,
                default: Core::CommandAck::DELETE_COMMAND_DEFAULT,
                desc: "whether the /upload invocation itself is removed together with its reply"
        end
      end

      # This community's answer, defended against a stored value nothing in the
      # schema ever produced: an unrecognised one reads as the default rather
      # than turning into a strategy nobody chose.
      def self.strategy(config)
        value = config_value(config, :strategy)
        candidate = value.nil? ? nil : value.to_s.strip.downcase.to_sym
        STRATEGIES.include?(candidate) ? candidate : DEFAULT_STRATEGY
      end

      # Whether the bridge mirrors an oversized inbound file automatically.
      # Defaults true: before this split, one enabled flag meant both halves
      # ran, and an unset key must keep meaning exactly that.
      def self.rehost_inbound?(config)
        truthy(config_value(config, :rehost_inbound), default: true)
      end

      # Whether a member's own /upload command is available. Same default-true
      # reasoning as {.rehost_inbound?}.
      def self.upload_command_enabled?(config)
        truthy(config_value(config, :enable_upload_command), default: true)
      end

      # Shown on the dashboard page where an operator ticks this on.
      def self.retention_notice
        "Switching this on makes rubotty keep member-uploaded FILES: a file too big for one of the " \
          "room's platforms is written to rubotty's own disk, compressed and encrypted, and a " \
          "download link is posted in its place. This only covers a file rubotty can actually " \
          "fetch from its source platform, which draws its own separate ceiling on what a bot may " \
          "download: Telegram's cloud Bot API stops a bot at 20 MB even though the same bot may " \
          "upload 50, and a self hosted Bot API server (the account's api_base setting) is the " \
          "supported way to raise that. See the Platforms page for the exact ceiling in force. " \
          "Files are kept for #{ControlPlane::RehostedFiles::DEFAULT_TTL_DAYS} " \
          "days by default (retention_days, at most #{ControlPlane::RehostedFiles::MAX_TTL_DAYS}), after which a " \
          "daily job deletes the bytes and the row. Anyone holding a link can download the file " \
          "until then, with no account and no membership check, so treat a link as the file itself. " \
          "Each link also stops answering once it has been served its own ceiling of times, the " \
          "community's summed platform membership or #{ControlPlane::RehostedFiles::SERVE_LIMIT_FLAT}, " \
          "whichever is smaller, never below #{ControlPlane::RehostedFiles::SERVE_LIMIT_FLOOR}. That " \
          "bounds how far a leaked link can spread; it does not stop whoever already holds it from " \
          "downloading the file and putting it somewhere else. " \
          "Setting strategy to shrink or shrink_then_link keeps a re encoded copy of a picture " \
          "instead of the original, on the same disk and the same retention, and that re encode " \
          "drops the picture's EXIF metadata including any GPS fix it was carrying. This community " \
          "may also hold at most #{gib(ControlPlane::RehostedFiles::DEFAULT_QUOTA_BYTES)} of " \
          "rehosted files at once by default (quota_bytes); a file that would push the total over " \
          "that is refused, distinctly from one refused for being over max_bytes on its own. " \
          "Switching the feature off stops new files being kept; anything already held expires on " \
          "the retention it was stored under."
      end

      # This community's retention, in days, from the resolved feature config.
      def self.retention_days(config)
        value = config_value(config, :retention_days)
        value.nil? ? ControlPlane::RehostedFiles::DEFAULT_TTL_DAYS : value.to_i
      end

      # This community's per-file ceiling, in bytes.
      def self.max_bytes(config)
        value = config_value(config, :max_bytes)
        size = value.nil? ? ControlPlane::RehostedFiles::DEFAULT_MAX_BYTES : value.to_i
        size.positive? ? size : ControlPlane::RehostedFiles::DEFAULT_MAX_BYTES
      end

      # This community's total-storage ceiling, in bytes: distinct from
      # {.max_bytes}, which bounds one file rather than everything held at once.
      def self.quota_bytes(config)
        value = config_value(config, :quota_bytes)
        size = value.nil? ? ControlPlane::RehostedFiles::DEFAULT_QUOTA_BYTES : value.to_i
        size.positive? ? size : ControlPlane::RehostedFiles::DEFAULT_QUOTA_BYTES
      end

      # A round gibibyte count for a schema description or notice; every byte
      # constant this feature quotes in prose is a clean multiple of one.
      def self.gib(bytes) = "#{bytes / (1024 * 1024 * 1024)} GB"

      # The most files one /upload selection may carry, from the resolved config.
      def self.max_batch_files(config)
        value = config_value(config, :max_batch_files)
        size = value.nil? ? ControlPlane::RehostedFiles::DEFAULT_MAX_BATCH_FILES : value.to_i
        size.positive? ? size : ControlPlane::RehostedFiles::DEFAULT_MAX_BATCH_FILES
      end

      # This community's whole-batch ceiling, in bytes. A stored 0 (the schema
      # default) means nobody has picked one, so it is derived from this same
      # config's own {.max_bytes} rather than the DEFAULT_MAX_BYTES constant,
      # which keeps the derived ceiling in step with a per file cap the
      # community has already raised or lowered.
      def self.max_batch_bytes(config)
        value = config_value(config, :max_batch_bytes)
        size = value.to_i
        return size if size.positive?

        max_bytes(config) * ControlPlane::RehostedFiles::DEFAULT_BATCH_BYTES_MULTIPLIER
      end

      # Feature config arrives with string keys from the database and symbol keys
      # from a code default, so both are tried.
      def self.config_value(config, key)
        return nil unless config.respond_to?(:[])

        value = config[key.to_s]
        value.nil? ? config[key.to_sym] : value
      end

      # A boolean config value, string-coerced the way a form post arrives:
      # nil reads as +default+, true/false pass through, anything else is
      # matched case-insensitively against a short truthy word list.
      def self.truthy(value, default:)
        return default if value.nil?
        return value if value == true || value == false

        %w[true yes on 1].include?(value.to_s.strip.downcase)
      end
    end
  end
end
