# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Config::Loader do
  let(:env) { { "TG_TOKEN" => "123:abc", "DC_TOKEN" => "discord-token" } }

  def load(yaml, environment: env)
    described_class.load_string(yaml, source: "test.yaml", env: environment)
  end

  def problems_from(yaml, environment: env)
    load(yaml, environment: environment)
    raise "expected the configuration to be rejected"
  rescue Rubotty::ConfigError => e
    e.problems
  end

  let(:valid) do
    <<~YAML
      name: test bridge
      accounts:
        tg:
          adapter: telegram
          token_env: TG_TOKEN
      rooms:
        - id: general
          endpoints:
            - id: tg-general
              adapter: telegram
              account: tg
              chat_id: "-1008000000001"
              thread_id: 142483
            - id: tg-mirror
              adapter: telegram
              account: tg
              chat_id: "-1008000000001"
              thread_id: 142565
    YAML
  end

  describe "a valid configuration" do
    it "loads" do
      config = load(valid)
      expect(config.name).to eq("test bridge")
      expect(config.rooms.size).to eq(1)
      expect(config.endpoints.map(&:id)).to contain_exactly("tg-general", "tg-mirror")
    end

    it "resolves secrets from the environment and never from the file" do
      config = load(valid)
      expect(config.accounts["tg"].settings[:token]).to eq("123:abc")
      expect(valid).not_to include("123:abc")
    end

    it "applies defaults" do
      config = load(valid)
      expect(config.message_ttl).to eq(86_400)
      expect(config.storage_driver).to eq(:sqlite)
      expect(config.endpoints.first.receives?).to be(true)
    end

    it "parses a duration written in words" do
      config = load(valid.sub("name: test bridge", "name: t\nbehaviour:\n  message_ttl: 6 hours"))
      expect(config.message_ttl).to eq(21_600)
    end

    it "keeps adapter specific keys out of the core endpoint model" do
      endpoint = load(valid).endpoints.first
      expect(endpoint.settings[:chat_id]).to eq("-1008000000001")
      expect(endpoint.settings[:thread_id]).to eq(142_483)
    end

    it "accepts a guest_retention at the one hour cap" do
      config = load(valid.sub("name: test bridge", "name: t\nbehaviour:\n  guest_retention: 1 hour"))
      expect(config.guest_retention).to eq(3600)
    end
  end

  # The dashboard header's drift check. Unset it must stay off, since a
  # deployment with no upstream to compare against has nothing to warn about.
  describe "the deploy drift settings" do
    it "leaves the check off and the grace at its default when nothing is configured" do
      config = load(valid)
      expect(config.deploy_head_url).to be_nil
      expect(config.deploy_head_token_env).to be_nil
      expect(config.deploy_drift_grace).to eq(Rubotty::Core::DeployDrift::DEFAULT_GRACE)
    end

    it "reads the upstream, the token variable NAME and the grace period" do
      yaml = valid.sub(
        "name: test bridge",
        "name: t\nbehaviour:\n" \
        "  deploy_head_url: https://upstream.example/head\n" \
        "  deploy_head_token_env: RUBOTTY_DEPLOY_HEAD_TOKEN\n" \
        "  deploy_drift_grace: 20 minutes"
      )
      config = load(yaml)

      expect(config.deploy_head_url).to eq("https://upstream.example/head")
      expect(config.deploy_head_token_env).to eq("RUBOTTY_DEPLOY_HEAD_TOKEN")
      expect(config.deploy_drift_grace).to eq(1200)
    end
  end

  # Privacy guarantee, not a tunable default: captured guest-portal message
  # content is never kept more than an hour past a session ending, whatever an
  # operator asks for. See ControlPlane::GuestRetention::MAX_GRACE.
  describe "the guest_retention cap" do
    it "rejects a value over one hour" do
      problems = problems_from(valid.sub("name: test bridge", "name: t\nbehaviour:\n  guest_retention: 2 hours"))
      expect(problems.join).to include("behaviour.guest_retention: must be at most 3600 seconds")
    end
  end

  describe "error reporting" do
    it "names the file, the line and the problem for malformed YAML" do
      problems = problems_from("rooms:\n  - id: x\n   bad indent\n")
      expect(problems.first).to include("test.yaml:")
    end

    it "reports a missing required key with its path" do
      problems = problems_from(valid.sub("  - id: general\n", "  - label: no id here\n"))
      expect(problems.join).to include("rooms[0].id: is required")
    end

    it "reports every problem at once rather than stopping at the first" do
      broken = <<~YAML
        accounts:
          tg:
            adapter: telegram
            token_env: TG_TOKEN
        rooms:
          - id: r
            endpoints:
              - id: a
                adapter: telegram
                account: tg
                chat_id: not-a-number
              - id: b
                adapter: telegram
                account: nonexistent
                chat_id: "-100123"
      YAML
      problems = problems_from(broken)
      expect(problems.size).to be >= 2
      expect(problems.join).to include("chat_id")
      expect(problems.join).to include("nonexistent")
    end

    # Every credentialed adapter opted into graceful dormancy (see the
    # "graceful gateway enablement" examples below): a missing token_env
    # leaves that account waiting rather than refusing the whole file. IRC has
    # not, so it still shows the original fail fast behaviour.
    it "explains an unset environment variable instead of failing later, for an adapter " \
       "that has not opted into graceful dormancy" do
      broken = <<~YAML
        accounts:
          net:
            adapter: irc
            server: irc.example.org
            nick: bridge
            password_env: IRC_PASSWORD
        rooms:
          - id: r
            endpoints:
              - id: a
                adapter: irc
                account: net
                channel: "#one"
              - id: b
                adapter: irc
                account: net
                channel: "#two"
      YAML
      problems = problems_from(broken, environment: {})
      expect(problems.join).to include("IRC_PASSWORD is not set")
    end

    it "rejects an unknown adapter and lists the known ones" do
      problems = problems_from(valid.gsub("adapter: telegram", "adapter: nonesuch"))
      expect(problems.join).to include("unknown adapter")
      expect(problems.join).to include("telegram")
    end

    # A guest endpoint is synthesised by SnapshotBuilder from a room's own
    # guest-access setting; its endpoint_schema has no required fields, so
    # nothing else here would catch one hand written into YAML.
    it "rejects a guest endpoint declared in configuration with a clear message" do
      broken = <<~YAML
        accounts:
          tg:
            adapter: telegram
            token_env: TG_TOKEN
          gp:
            adapter: guest
        rooms:
          - id: r
            endpoints:
              - id: a
                adapter: telegram
                account: tg
                chat_id: "-100123"
              - id: g
                adapter: guest
                account: gp
      YAML
      problems = problems_from(broken)
      expect(problems.join).to include("guest endpoints are created automatically")
    end

    it "rejects an unknown key and suggests the intended one" do
      problems = problems_from(valid.sub("  thread_id: 142483", "  thred_id: 142483"))
      expect(problems.join).to include("unknown key")
      expect(problems.join).to include("Did you mean thread_id?")
    end

    # #249 made a one-endpoint room first class on the dashboard's own path;
    # this format documents itself as "N endpoints per room, any adapter, any
    # mix", so the loader should not hold a static single-platform room to a
    # rule the rest of the system dropped.
    it "accepts a room with a single endpoint, for a single-platform community" do
      single = <<~YAML
        accounts:
          tg: { adapter: telegram, token_env: TG_TOKEN }
        rooms:
          - id: r
            endpoints:
              - id: a
                adapter: telegram
                account: tg
                chat_id: "-100123"
      YAML
      expect(load(single).rooms.first.endpoints.size).to eq(1)
    end

    it "rejects a room with no endpoints at all" do
      empty = <<~YAML
        accounts:
          tg: { adapter: telegram, token_env: TG_TOKEN }
        rooms:
          - id: r
            endpoints: []
      YAML
      expect(problems_from(empty).join).to include("at least one endpoint")
    end

    it "rejects a duplicate endpoint id within one room" do
      dup = valid.gsub("id: tg-mirror", "id: tg-general")
      expect(problems_from(dup).join).to include("appears 2 times in one room")
    end

    it "rejects an endpoint whose account belongs to a different adapter" do
      mixed = valid.sub("    adapter: telegram\n    token_env: TG_TOKEN",
                        "    adapter: discord\n    token_env: DC_TOKEN")
      expect(problems_from(mixed).join).to include("is for discord")
    end

    it "rejects a display name template with an unknown placeholder" do
      typo = valid + "display_name:\n  format: \"{frist_name}\"\n"
      problems = problems_from(typo)
      expect(problems.join).to include("unknown placeholder")
      expect(problems.join).to include("{first_name}")
    end

    it "rejects a chat id that is not numeric, with advice" do
      problems = problems_from(valid.sub('chat_id: "-1008000000001"', "chat_id: \"@mygroup\""))
      expect(problems.join).to include("not an @username")
    end

    it "rejects a thread id on a chat that cannot have forum topics" do
      problems = problems_from(valid.gsub('chat_id: "-1008000000001"', 'chat_id: "-42"'))
      expect(problems.join).to include("forum topics only exist in supergroups")
    end

    it "requires webhook_url when the telegram transport is webhook" do
      webhooked = valid.sub("    token_env: TG_TOKEN", "    token_env: TG_TOKEN\n    transport: webhook")
      expect(problems_from(webhooked).join).to include("webhook_url: required")
    end

    it "rejects an unknown storage driver by listing the valid ones" do
      problems = problems_from("#{valid}storage:\n  driver: mongodb\n")
      expect(problems.join).to include("sqlite")
    end

    it "still raises on a file that exists but fails validation" do
      broken = Tempfile.new(["bridge", ".yaml"])
      broken.write(valid.sub("adapter: telegram", "adapter: nonesuch"))
      broken.close
      expect { described_class.load_file(broken.path, env: env) }
        .to raise_error(Rubotty::ConfigError, /unknown adapter/)
    ensure
      broken&.unlink
    end
  end

  # A database-only deployment has no bridge.config.yaml at all once its
  # accounts and rooms live in the control plane instead.
  describe "a missing or empty file" do
    it "loads a missing file the same as an empty one, rather than raising" do
      model = described_class.load_file("/nonexistent/bridge.yaml", env: env)
      expect(model.accounts).to eq({})
      expect(model.rooms).to eq([])
    end

    it "loads an empty string with no accounts and no rooms" do
      model = load("")
      expect(model.accounts).to eq({})
      expect(model.rooms).to eq([])
      expect(model.name).to eq("rubotty")
    end

    it "loads a file that sets other keys but neither accounts nor rooms" do
      model = load("name: db-only bridge\n")
      expect(model.accounts).to eq({})
      expect(model.rooms).to eq([])
      expect(model.name).to eq("db-only bridge")
    end

    # The control plane reconciles a community's display name from this file on
    # every boot, so it has to be able to tell a name someone wrote from the
    # one the schema materialised.
    it "says whether the name was declared or came from the schema default" do
      expect(load("").name_declared?).to be(false)
      expect(load("name: db-only bridge\n").name_declared?).to be(true)
      expect(load(%(name: ""\n)).name_declared?).to be(false)
      expect(described_class.load_file("/nonexistent/bridge.yaml", env: env).name_declared?).to be(false)
    end

    it "loads explicit empty accounts and rooms the same way" do
      model = load("accounts: {}\nrooms: []\n")
      expect(model.accounts).to eq({})
      expect(model.rooms).to eq([])
    end

    it "still validates accounts and rooms when either is actually present" do
      expect(problems_from("accounts:\n  tg:\n    adapter: nonesuch\n").join).to include("unknown adapter")
    end
  end

  describe "N way rooms" do
    it "accepts a room with more than two endpoints" do
      three = <<~YAML
        accounts:
          tg: { adapter: telegram, token_env: TG_TOKEN }
        rooms:
          - id: r
            endpoints:
              - { id: a, adapter: telegram, account: tg, chat_id: "-100111" }
              - { id: b, adapter: telegram, account: tg, chat_id: "-100222" }
              - { id: c, adapter: telegram, account: tg, chat_id: "-100333" }
      YAML
      expect(load(three).rooms.first.endpoints.size).to eq(3)
    end

    it "accepts one endpoint appearing in several rooms" do
      hub = <<~YAML
        accounts:
          tg: { adapter: telegram, token_env: TG_TOKEN }
        rooms:
          - id: r1
            endpoints:
              - { id: hub, adapter: telegram, account: tg, chat_id: "-100111" }
              - { id: a, adapter: telegram, account: tg, chat_id: "-100222" }
          - id: r2
            endpoints:
              - { id: hub, adapter: telegram, account: tg, chat_id: "-100111" }
              - { id: b, adapter: telegram, account: tg, chat_id: "-100333" }
      YAML
      config = load(hub)
      expect(config.topology.rooms_for("hub").map(&:id)).to contain_exactly("r1", "r2")
    end

    it "rejects the same endpoint id used for two different destinations" do
      clash = <<~YAML
        accounts:
          tg: { adapter: telegram, token_env: TG_TOKEN }
        rooms:
          - id: r1
            endpoints:
              - { id: hub, adapter: telegram, account: tg, chat_id: "-100111" }
              - { id: a, adapter: telegram, account: tg, chat_id: "-100222" }
          - id: r2
            endpoints:
              - { id: hub, adapter: telegram, account: tg, chat_id: "-100999" }
              - { id: b, adapter: telegram, account: tg, chat_id: "-100333" }
      YAML
      expect(problems_from(clash).join).to include("different destinations")
    end
  end

  describe "operators" do
    let(:with_operators) do
      <<~YAML
        accounts:
          tg: { adapter: telegram, token_env: TG_TOKEN }
        rooms:
          - id: general
            endpoints:
              - { id: a, adapter: telegram, account: tg, chat_id: "-100111" }
              - { id: b, adapter: telegram, account: tg, chat_id: "-100222" }
        operators:
          - name: Alex
            identities:
              telegram: ["55"]
              discord: ["900"]
      YAML
    end

    it "builds a directory keyed by person, not by platform" do
      config = load(with_operators)
      expect(config.operators.resolve(:telegram, "55").name).to eq("Alex")
      expect(config.operators.resolve(:discord, "900").name).to eq("Alex")
    end

    it "enables moderation once at least one operator exists" do
      expect(load(with_operators).moderation_enabled?).to be(true)
    end

    it "leaves moderation disabled when nobody is listed" do
      expect(load(valid).moderation_enabled?).to be(false)
    end

    it "rejects an identity for an adapter that does not exist" do
      broken = with_operators.sub("      discord:", "      nonesuch:")
      expect(problems_from(broken).join).to include("unknown adapter")
    end

    it "rejects an unknown moderation action" do
      broken = "#{with_operators}    actions: [obliterate]\n"
      expect(problems_from(broken).join).to include("unknown moderation action")
    end

    it "rejects a room restriction naming a room that does not exist" do
      broken = "#{with_operators}    rooms: [nonexistent]\n"
      problems = problems_from(broken).join
      expect(problems).to include("no room named")
      expect(problems).to include("general")
    end

    it "accepts a restricted operator" do
      scoped = "#{with_operators}    actions: [delete]\n    rooms: [general]\n"
      operator = load(scoped).operators.resolve(:telegram, "55")
      # A config-file operator names no community, since a deployment reading
      # one has a single tenant with nothing to cross into.
      expect(operator.may?(:delete, "general", community_id: nil)).to be(true)
      expect(operator.may?(:ban, "general", community_id: nil)).to be(false)
    end
  end

  describe "reply quoting configuration" do
    it "defaults to a bounded preview" do
      config = load(valid)
      expect(config.reply_preview_chars).to eq(100)
      expect(config.reply_preview_lines).to eq(2)
    end

    it "can be turned off entirely" do
      off = valid.sub("name: test bridge", "name: t\nbehaviour:\n  reply_preview_chars: 0")
      expect(load(off).reply_preview_chars).to eq(0)
    end
  end

  # A secret pasted into an env var with surrounding quotes crash looped a real
  # deploy: the stray quote made the token an invalid URI whose error message
  # then leaked the whole token into the logs. The loader now trims the value.
  describe "env backed secret hygiene" do
    def token_for(env_value)
      load(valid, environment: env.merge("TG_TOKEN" => env_value)).accounts["tg"].settings[:token]
    end

    it "leaves a clean value untouched" do
      expect(token_for("123:abc")).to eq("123:abc")
    end

    it "strips a surrounding pair of single quotes" do
      expect(token_for("'123:abc'")).to eq("123:abc")
    end

    it "strips a surrounding pair of double quotes" do
      expect(token_for('"123:abc"')).to eq("123:abc")
    end

    it "strips leading and trailing whitespace" do
      expect(token_for("  123:abc\n")).to eq("123:abc")
    end

    # Only a genuinely wrapping pair is removed. A token that happens to contain
    # a quote must survive verbatim.
    it "does not mangle an inner quote" do
      expect(token_for("12'3:abc")).to eq("12'3:abc")
    end

    it "does not strip an unmatched surrounding quote" do
      expect(token_for("'123:abc")).to eq("'123:abc")
    end
  end

  # Declaring every platform up front and bringing each online as its key
  # arrives means a single missing secret must never take the whole config,
  # or the other declared gateways, down with it. Telegram and Discord are
  # both single identity adapters that opted into this.
  describe "graceful gateway enablement (issue #154)" do
    let(:two_accounts) do
      <<~YAML
        name: staged rollout
        accounts:
          tg:
            adapter: telegram
            token_env: TG_TOKEN
          dc:
            adapter: discord
            token_env: DC_TOKEN
        rooms:
          - id: r
            endpoints:
              - id: a
                adapter: telegram
                account: tg
                chat_id: "-1008000000001"
              - id: b
                adapter: discord
                account: dc
                channel_id: "800000000000000011"
      YAML
    end

    it "loads successfully and marks the account whose key is missing as dormant" do
      config = load(two_accounts, environment: { "DC_TOKEN" => "dc-token" })
      tg = config.accounts["tg"]
      expect(tg.dormant?).to be(true)
      expect(tg.dormant_reason).to eq("waiting for key (TG_TOKEN not set)")
    end

    it "still resolves the sibling account whose key IS present, unaffected" do
      config = load(two_accounts, environment: { "DC_TOKEN" => "dc-token" })
      dc = config.accounts["dc"]
      expect(dc.dormant?).to be(false)
      expect(dc.settings[:token]).to eq("dc-token")
    end

    it "connects exactly as before when every declared key is present" do
      config = load(two_accounts, environment: { "TG_TOKEN" => "123:abc", "DC_TOKEN" => "dc-token" })
      expect(config.accounts["tg"].dormant?).to be(false)
      expect(config.accounts["tg"].settings[:token]).to eq("123:abc")
    end

    it "still raises for a genuinely malformed config even when a secret is also missing" do
      # transport: webhook with no webhook_url is a missing REQUIRED, NON
      # secret field. That must stay fatal on top of, not instead of, the
      # token being allowed to stay unresolved.
      webhook_no_url = two_accounts.sub(
        "    token_env: TG_TOKEN\n", "    token_env: TG_TOKEN\n    transport: webhook\n"
      )
      problems = problems_from(webhook_no_url, environment: { "DC_TOKEN" => "dc-token" })
      expect(problems.join).to include("webhook_url: required")
      expect(problems.join).not_to include("TG_TOKEN is not set")
    end

    it "still raises for an unknown adapter name, unaffected by dormancy" do
      broken = two_accounts.gsub("adapter: telegram", "adapter: nonesuch")
      problems = problems_from(broken, environment: { "DC_TOKEN" => "dc-token" })
      expect(problems.join).to include("unknown adapter")
    end
  end

  describe "a realistic multi-room, multi-adapter configuration" do
    it "is valid" do
      path = File.expand_path("../fixtures/control_plane/sample.config.yaml", __dir__)
      config = described_class.load_file(
        path,
        env: { "TELEGRAM_BOT_TOKEN" => "t", "DISCORD_BOT_TOKEN" => "d", "DATABASE_URL" => "postgres://x/y" }
      )
      expect(config.rooms.size).to be >= 7
      expect(config.endpoints.map(&:adapter_name).uniq).to contain_exactly(:telegram, :discord)
    end
  end
end
