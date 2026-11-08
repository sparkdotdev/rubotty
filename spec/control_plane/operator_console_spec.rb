# frozen_string_literal: true

require "spec_helper"

# Driven against the seeded SAMPLE control plane, so a real operator, real
# requests and the live Registry are in play.
RSpec.describe Rubotty::ControlPlane::OperatorConsole, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:accounts) { sample_model.accounts }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: accounts) }
  let(:flow) do
    Rubotty::ControlPlane::OperatorFlow.new(models: models, registry: registry, logger: Rubotty::Log.null)
  end
  let(:request_lane) do
    Rubotty::ControlPlane::ControlLane.new(operator_flow: flow, logger: Rubotty::Log.null)
  end

  subject(:console) do
    described_class.new(operator_flow: flow, request_lane: request_lane, logger: Rubotty::Log.null)
  end

  # The seeded bootstrap operator.
  def boss
    Rubotty::Core::Author.new(native_id: "80000012", username: "sample_owner")
  end

  def newcomer
    Rubotty::Core::Author.new(native_id: "999888", username: "newbie", first_name: "New")
  end

  # Somebody who operates nothing anywhere, so the console only answers them at
  # all once they read something.
  def viewer_only
    Rubotty::Core::Author.new(native_id: "424242", username: "onlooker", first_name: "Ona")
  end

  def dm(author, text)
    console.handle_dm(adapter: :telegram, account: "telegram", author: author, text: text)
  end

  # The Telegram adapter hands the lane a forwarded message alongside the text,
  # and the console is the lane a control-plane deployment wires. Not taking the
  # keyword raised ArgumentError out of every operator DM, so /vindicate,
  # web-login and the rest answered nothing at all in production.
  describe "the shape the adapter calls it with" do
    # Stands in for ControlLane, which owns the report store.
    class ReportingLane
      attr_reader :taken

      def initialize(answer = "Filed.")
        @answer = answer
        @taken = []
      end

      # The real lane answers nil for a DM that is not a report, and the console
      # leans on that to carry on to its own commands. Matched against
      # ControlLane's own pattern rather than a copy, so this fake cannot drift
      # from what it stands in for.
      def report_dm(adapter:, account:, author:, text:, subject: nil)
        return nil unless Rubotty::ControlPlane::ControlLane::REPORT.match?(text.to_s)

        @taken << { author: author&.native_id, text: text, subject: subject }
        @answer
      end

      def handle_dm(**) = nil
    end

    let(:reporting) { ReportingLane.new }
    def reporting_console
      described_class.new(operator_flow: flow, request_lane: reporting, logger: Rubotty::Log.null)
    end

    it "takes the subject keyword the adapter sends, rather than raising" do
      expect { console.handle_dm(adapter: :telegram, account: "telegram", author: boss, text: "help", subject: nil) }
        .not_to raise_error
    end

    it "still answers an ordinary operator command when a subject rides along" do
      reply = console.handle_dm(adapter: :telegram, account: "telegram", author: boss,
                                text: "help", quoted: nil, subject: nil)

      expect(reply).not_to be_nil
    end

    # Reporting is for everybody, so it is answered before the console resolves
    # any membership: an operator forwarding something files it like anyone else.
    it "hands a report to the lane that holds the store, whoever sent it" do
      subject = Rubotty::ControlPlane::ReportLane::Subject.new(author: newcomer, body: "bad", adapter: :telegram)
      reply = reporting_console.handle_dm(adapter: :telegram, account: "telegram", author: boss,
                                          text: "/report", subject: subject)

      expect(reply).to eq("Filed.")
      expect(reporting.taken.last[:subject]).to eq(subject)
    end

    it "answers a DM that is not a report as it always did" do
      expect(reporting_console.handle_dm(adapter: :telegram, account: "telegram", author: boss,
                                         text: "help", subject: nil)).not_to eq("Filed.")
    end
  end

  # Promote the seeded operator into a second community sharing the Telegram
  # account. +adapter+/+native_id+ are the identity the second community's
  # person row carries; pass a Discord one to exercise cross-platform
  # resolution instead of an account lookup.
  def add_second_community(adapter: "telegram", native_id: "80000012", username: "sample_owner")
    now = Time.now
    second = models.community.create(slug: "second", name: "Second Guild", status: "active",
                                     settings: "{}", created_at: now, updated_at: now)
    conn = models.platform_connection.create(community_id: second.id, adapter: "telegram",
                                              account: "telegram", external_id: "-100999",
                                              created_at: now, updated_at: now)
    models.channel.create(community_id: second.id, platform_connection_id: conn.id,
                          adapter: "telegram", account: "telegram", route_key: "-100999",
                          endpoint_key: "tg-second", label: "s", receives: true, sends: true,
                          relay: "{}", display_name: "{}", settings: '{"chat_id":"-100999"}',
                          created_at: now, updated_at: now)
    person = models.person.create(community_id: second.id, name: "Alex", created_at: now, updated_at: now)
    models.person_identity.create(person_id: person.id, adapter: adapter,
                                  native_id: native_id, username: username, created_at: now)
    models.operator.create(community_id: second.id, person_id: person.id,
                           actions: JSON.generate("all"), scope: JSON.generate("all"),
                           granted_at: now, granted_by: "test")
    registry.reload
    second
  end

  describe "authentication" do
    it "falls through to the request lane for a non-operator's request gesture" do
      reply = dm(newcomer, "operator request")
      expect(reply).to match(/request to become an operator/i)
      expect(flow.pending(community_id: models.community.first.id).size).to eq(1)
    end

    it "answers a non-operator's ordinary chatter with the #31 public-information notice" do
      expect(dm(newcomer, "hi bot")).to eq(Rubotty::ControlPlane::ControlLane::DEFAULT_NOTICE)
    end

    it "never shows an operator the #31 notice: their DM reaches the console" do
      reply = dm(boss, "help")
      expect(reply).to match(/Operator console/)
      expect(reply).not_to eq(Rubotty::ControlPlane::ControlLane::DEFAULT_NOTICE)
    end

    it "is inert without a control plane" do
      inert = described_class.new(operator_flow: nil, logger: Rubotty::Log.null)
      expect(inert.handle_dm(adapter: :telegram, account: "telegram", author: boss, text: "help")).to be_nil
    end

    it "stays silent when it cannot identify the author" do
      expect(dm(nil, "help")).to be_nil
    end
  end

  describe "informational commands" do
    it "greets a bare or prefix-only line with the help menu" do
      expect(dm(boss, "")).to match(/Operator console/)
      expect(dm(boss, "/")).to match(/Operator console/)
    end

    it "lists the commands on help, tolerating a leading slash" do
      expect(dm(boss, "/help")).to match(/whoami/)
      expect(dm(boss, "help")).to match(/approve <id>/)
    end

    it "reports the operator's identity and communities on whoami" do
      expect(dm(boss, "whoami")).to match(/operator of: sample/i)
    end

    it "lists the communities the operator runs, with run state" do
      reply = dm(boss, "communities")
      expect(reply).to match(/sample/)
      expect(reply).to match(/running/)
    end

    it "reports the current community's status" do
      expect(dm(boss, "status")).to match(/sample.*running.*0 open operator requests/i)
    end

    it "answers an unknown command with a hint" do
      expect(dm(boss, "frobnicate")).to match(/Unknown command "frobnicate"/)
    end
  end

  describe "request management" do
    before { flow.request(community_id: models.community.first.id, adapter: "telegram", native_id: "999888", username: "newbie", display: "New Bie") }

    it "lists open requests in the current community" do
      reply = dm(boss, "requests")
      expect(reply).to match(/New Bie/)
      expect(reply).to match(/approve <id>/)
    end

    it "approves a request, promoting the requester" do
      id = flow.pending(community_id: models.community.first.id).first.id
      reply = dm(boss, "approve #{id}")
      expect(reply).to match(/is now an operator of sample/i)
      expect(flow.resolve_operator(community_id: models.community.first.id, adapter: "telegram", native_id: "999888")).not_to be_nil
    end

    it "denies a request" do
      id = flow.pending(community_id: models.community.first.id).first.id
      reply = dm(boss, "deny #{id}")
      expect(reply).to match(/Denied ##{id}/)
      expect(flow.pending(community_id: models.community.first.id)).to be_empty
    end

    it "rejects an approve with no id" do
      expect(dm(boss, "approve")).to match(/Which request/)
    end

    it "reports an unknown request id" do
      expect(dm(boss, "approve 4242")).to match(/No request #4242/)
    end
  end

  describe "multi-community selection" do
    before { add_second_community }

    it "lists both communities on whoami" do
      expect(dm(boss, "whoami")).to match(/sample.*second|second.*sample/)
    end

    it "selects a community with use and remembers it for the next command" do
      expect(dm(boss, "use second")).to match(/Now working in second/)
      expect(dm(boss, "status")).to match(/second.*running/i)
    end

    it "refuses to select a community the operator does not run" do
      expect(dm(boss, "use nope")).to match(/do not run a community/i)
    end
  end

  # A mutating command against a guessed community is worse than a refusal, so
  # the console never guesses and always says which community it acted on.
  describe "multi-community disambiguation (#250)" do
    def open_request_in(community)
      flow.request(community_id: community.id, adapter: "telegram", native_id: "999888",
                   username: "newbie", display: "New Bie").request
    end

    context "when the operator runs exactly one community" do
      it "uses it without being asked, and NAMES it" do
        expect(dm(boss, "status")).to match(/sample \(SAMPLE\) is running/)
      end

      it "names the community in a mutating command's confirmation too" do
        request = open_request_in(models.community.first)
        expect(dm(boss, "approve #{request.id}")).to match(/Approved ##{request.id} in sample \(SAMPLE\)/)
      end

      it "names the community when denying" do
        request = open_request_in(models.community.first)
        expect(dm(boss, "deny #{request.id}")).to match(/Denied ##{request.id} in sample \(SAMPLE\)/)
      end
    end

    context "when the operator runs several" do
      let!(:second) { add_second_community }

      it "asks which one rather than guessing, and runs nothing" do
        reply = dm(boss, "status")

        expect(reply).to match(/will not guess/i)
        expect(reply).to match(/1\. sample \(SAMPLE\)/)
        expect(reply).to match(/2\. second \(Second Guild\)/)
      end

      it "refuses a MUTATION rather than applying it to an assumed community" do
        request = open_request_in(models.community.first)

        expect(dm(boss, "approve #{request.id}")).to match(/will not guess/i)
        expect(flow.find_request(community_id: models.community.first.id, id: request.id).state)
          .to eq("pending")
      end

      it "runs the held command where a one-word answer points, naming it" do
        request = open_request_in(second)
        dm(boss, "approve #{request.id}")

        reply = dm(boss, "2")

        expect(reply).to match(/Approved ##{request.id} in second \(Second Guild\)/)
        expect(flow.find_request(community_id: second.id, id: request.id).state).to eq("approved")
      end

      it "corrects an out-of-range answer and keeps the question open" do
        dm(boss, "status")
        expect(dm(boss, "9")).to match(/no 9 in that list.*1 to 2/i)
        expect(dm(boss, "2")).to match(/second \(Second Guild\) is running/)
      end

      it "takes a slug as the answer just as readily as a number" do
        dm(boss, "status")
        expect(dm(boss, "second")).to match(/second \(Second Guild\) is running/)
      end

      it "leaves the focus alone when a held command is answered: the answer scoped one command" do
        dm(boss, "status")
        dm(boss, "second")
        expect(dm(boss, "status")).to match(/will not guess/i)
      end

      # Every alert opens with the community it is about, so a reply to one
      # answers the question before it is asked. These carry no code at all,
      # which is what separates them from the vindicate and approve replies.
      context "when the operator replies to one of the bot's own alerts" do
        def reply_with(text, quoted:)
          console.handle_dm(adapter: :telegram, account: "telegram", author: boss,
                            text: text, quoted: quoted)
        end

        it "runs a scoped command in the community the alert opened with" do
          removal = "SAMPLE: a link was removed in General, posted by Ada. Reason: invite link."

          expect(reply_with("status", quoted: removal)).to match(/sample \(SAMPLE\) is running/)
        end

        it "reads the other community just as readily" do
          expect(reply_with("status", quoted: "Second Guild: a link was removed in General."))
            .to match(/second \(Second Guild\) is running/)
        end

        it "still asks when the opening names no community this operator runs" do
          expect(reply_with("status", quoted: "Someone Else: a link was removed."))
            .to match(/will not guess/i)
        end

        # The quoted alert carries a member's own message, which may name
        # another community; only the opening is allowed to decide.
        it "is not swayed by a community named inside the quoted message" do
          quoted = "SAMPLE: Ada posted. Message: \"is there a Second Guild: group?\""

          expect(reply_with("status", quoted: quoted)).to match(/sample \(SAMPLE\) is running/)
        end

        it "still asks about a reply to something that is not an alert at all" do
          expect(reply_with("status", quoted: "Now working in sample (SAMPLE).")).to match(/will not guess/i)
        end
      end

      it "remembers the focus across messages once it is set" do
        dm(boss, "use second")
        expect(dm(boss, "status")).to match(/second \(Second Guild\) is running/)
        expect(dm(boss, "requests")).to match(/No open operator requests in second \(Second Guild\)/)
      end

      it "names the community a mutation applied to, in focus as much as out of it" do
        request = open_request_in(second)
        dm(boss, "use second")
        expect(dm(boss, "approve #{request.id}")).to match(/Approved ##{request.id} in second \(Second Guild\)/)
      end

      it "runs a one-off in another community with @slug, without moving the focus" do
        dm(boss, "use sample")
        request = open_request_in(second)

        expect(dm(boss, "approve #{request.id} @second"))
          .to match(/Approved ##{request.id} in second \(Second Guild\)/)
        # Still working in sample: the override scoped exactly one command.
        expect(dm(boss, "status")).to match(/sample \(SAMPLE\) is running/)
      end

      it "reads the override wherever it sits in the command" do
        expect(dm(boss, "status @second")).to match(/second \(Second Guild\) is running/)
      end

      it "refuses an override naming a community the operator does not run" do
        expect(dm(boss, "status @nope")).to match(/do not run a community with slug "nope"/)
      end

      it "keeps the focus in the durable session store, so it survives a restart" do
        sessions = Rubotty::ControlPlane::OperatorConsole::KvSessions.new(Rubotty::Storage::Memory.new)
        before_restart = described_class.new(operator_flow: flow, request_lane: request_lane,
                                             sessions: sessions, logger: Rubotty::Log.null)
        after_restart = described_class.new(operator_flow: flow, request_lane: request_lane,
                                            sessions: sessions, logger: Rubotty::Log.null)

        before_restart.handle_dm(adapter: :telegram, account: "telegram", author: boss, text: "use second")
        reply = after_restart.handle_dm(adapter: :telegram, account: "telegram", author: boss, text: "status")

        expect(reply).to match(/second \(Second Guild\) is running/)
      end

      it "answers the global commands with no community context at all" do
        expect(dm(boss, "help")).to match(/Operator console/)
        expect(dm(boss, "whoami")).to match(/operator of: sample, second/)
        expect(dm(boss, "communities")).to match(/sample.*\n.*second/)
      end
    end

    # The DM arrives on Telegram, but the second community knows this human
    # only by their Discord id, and the two are linked as one person.
    it "reaches a community the sender operates under a DIFFERENT platform identity" do
      add_second_community(adapter: "discord", native_id: "80000000000000013", username: nil)

      expect(dm(boss, "communities")).to match(/second/)
      expect(dm(boss, "status @second")).to match(/second \(Second Guild\) is running/)
    end

    it "never reaches a community the sender does not operate" do
      without_owner_floor
      now = Time.now
      models.community.create(slug: "elsewhere", name: "Somewhere Else", status: "active",
                              settings: "{}", created_at: now, updated_at: now)

      expect(dm(boss, "communities")).not_to match(/elsewhere/)
      expect(dm(boss, "status @elsewhere")).to match(/do not run a community/i)
    end
  end

  describe "resume / suspend" do
    let(:lifecycle) { instance_double("CommunityLifecycle") }

    subject(:console) do
      described_class.new(operator_flow: flow, request_lane: request_lane,
                          lifecycle: lifecycle, logger: Rubotty::Log.null)
    end

    it "stops the bot in the current community through the lifecycle service" do
      row = models.community.first
      allow(lifecycle).to receive(:find_by_slug).with("sample").and_return(row)
      allow(lifecycle).to receive(:stop).with(community: row)
                                        .and_return(Struct.new(:status).new(:stopped))

      expect(dm(boss, "suspend")).to match(/Stopped the bot in sample.*goes quiet/i)
    end

    it "starts the bot in the current community" do
      row = models.community.first
      allow(lifecycle).to receive(:find_by_slug).with("sample").and_return(row)
      allow(lifecycle).to receive(:start).with(community: row)
                                         .and_return(Struct.new(:status).new(:started))

      expect(dm(boss, "resume")).to match(/Started the bot in sample/)
    end

    it "offers resume/suspend in help only when the lifecycle service is wired" do
      allow(lifecycle).to receive(:find_by_slug)
      expect(dm(boss, "help")).to match(/resume\s+start the bot/)
    end

    # #1884: the old spelling still works, but only spelled out against one
    # community, which nobody types by pressing a button.
    it "still starts and stops when the command names the community outright" do
      row = models.community.first
      allow(lifecycle).to receive(:find_by_slug).with("sample").and_return(row)
      allow(lifecycle).to receive(:start).with(community: row)
                                         .and_return(Struct.new(:status).new(:started))
      allow(lifecycle).to receive(:stop).with(community: row)
                                        .and_return(Struct.new(:status).new(:stopped))

      expect(dm(boss, "start @sample")).to match(/Started the bot in sample/)
      expect(dm(boss, "stop @sample")).to match(/Stopped the bot in sample/)
    end

    it "welcomes a bare start rather than touching the lifecycle service" do
      allow(lifecycle).to receive(:find_by_slug)
      allow(lifecycle).to receive(:start)

      expect(dm(boss, "/start")).to match(/Hello, and welcome/)
      expect(lifecycle).not_to have_received(:start)
    end

    # Acting on this one literally would take a community offline because
    # somebody asked to be left alone.
    it "refuses to read a bare stop as shutting a community down" do
      allow(lifecycle).to receive(:find_by_slug)
      allow(lifecycle).to receive(:stop)

      reply = dm(boss, "/stop")

      expect(reply).to match(/Nothing has been stopped/)
      expect(reply).to match(/suspend @<slug>/)
      expect(lifecycle).not_to have_received(:stop)
    end
  end

  it "does not offer resume/suspend when no lifecycle service is wired" do
    expect(dm(boss, "help")).not_to match(/start the bot/)
  end

  # #1884: the client owns these two words in a private chat, and an operator
  # told to open one and press Start was answered with a refusal.
  describe "the words the client reserves" do
    it "welcomes an operator pressing Start rather than refusing them" do
      reply = dm(boss, "/start")

      expect(reply).to match(/\AHello, and welcome\./)
      expect(reply).to match(/select handful of private communities/i)
      expect(reply).not_to match(/not available on this deployment/i)
    end

    it "tells an operator that this chat is their console, and where the list is" do
      reply = dm(boss, "/start")

      expect(reply).to match(/You operate sample/)
      expect(reply).to match(/`help`/)
    end

    # A deep link sends a payload after the word, and it is still the button.
    it "welcomes the same way when a deep-link payload rides after the word" do
      expect(dm(boss, "/start sample-invite")).to match(/\AHello, and welcome\./)
    end

    it "answers a bare stop without shutting anything down or naming a verb that is not wired" do
      reply = dm(boss, "/stop")

      expect(reply).to match(/Nothing has been stopped/)
      expect(reply).to match(/block or mute this chat/i)
      expect(reply).not_to match(/suspend @<slug>/)
    end

    # Somebody who reads a community and runs none reaches the console too, and
    # a welcome must not imply a standing they do not hold.
    it "does not tell somebody who operates nothing that they have a console to run" do
      community_viewers = Rubotty::ControlPlane::CommunityViewers.new(models: models, logger: Rubotty::Log.null)
      community_viewers.grant(community_id: models.community.first.id, adapter: "telegram",
                              handle: "onlooker", native_id: "424242", granted_by: "seeded")
      reader = described_class.new(operator_flow: flow, request_lane: request_lane,
                                   community_viewers: community_viewers, logger: Rubotty::Log.null)

      reply = reader.handle_dm(adapter: :telegram, account: "telegram", author: viewer_only, text: "/start")

      expect(reply).to match(/\AHello, and welcome\./)
      expect(reply).not_to match(/You operate/)
    end
  end

  describe "channel-mapping wizard" do
    let(:mapper) do
      Rubotty::ControlPlane::ChannelMapper.new(models: models, registry: registry, logger: Rubotty::Log.null)
    end

    subject(:console) do
      described_class.new(operator_flow: flow, request_lane: request_lane,
                          mapper: mapper, logger: Rubotty::Log.null)
    end

    # Two fresh unmapped channels, one per platform, so the wizard has
    # something to map.
    before do
      now = Time.now
      community = models.community.first
      %w[telegram discord].each_with_index do |adapter, i|
        connection = models.platform_connection.where(community_id: community.id, adapter: adapter).first
        key = adapter == "telegram" ? "tg-new" : "dc-new"
        route = adapter == "telegram" ? "-100777" : "555000"
        settings = adapter == "telegram" ? { chat_id: route } : { channel_id: route }
        models.channel.create(
          community_id: community.id, platform_connection_id: connection.id,
          adapter: adapter, account: connection.account, route_key: route,
          endpoint_key: key, label: key, receives: true, sends: true,
          relay: "{}", display_name: "{}", settings: JSON.generate(settings),
          created_at: now, updated_at: now
        )
      end
      registry.reload
    end

    it "offers map in help when a mapper is wired" do
      expect(dm(boss, "help")).to match(/map\s+map channels into rooms/)
    end

    it "lists the unmapped channels numbered per platform on map" do
      reply = dm(boss, "map")
      expect(reply).to match(/telegram:/)
      expect(reply).to match(/1\. tg-new/)
      expect(reply).to match(/discord:/)
      expect(reply).to match(/1\. dc-new/)
      expect(reply).to match(/Reply with pairs/)
    end

    it "maps a numbered pair into a room and confirms" do
      dm(boss, "map")
      reply = dm(boss, "1 1")
      expect(reply).to match(/Mapped 1 pair into rooms/)

      # The mapping is live: the two channels now fan out to each other.
      origin = registry.current.resolve(:telegram, "telegram", "-100777")&.endpoint
      targets = registry.current.topology.rooms_for(origin.id)
                        .flat_map { |room| room.targets_for(origin) }.map(&:id)
      expect(targets).to include("dc-new")
    end

    it "reports an out-of-range pair without mapping it" do
      dm(boss, "map")
      expect(dm(boss, "1 9")).to match(/out of range/)
    end

    # The console drives the same ChannelMapper the dashboard does, so a
    # single channel is mappable from a DM and a one-platform community can
    # still run the wizard.

    it "maps a single numbered channel into a room of its own" do
      dm(boss, "map")
      expect(dm(boss, "1")).to match(/Mapped 1 single channel into rooms/)

      origin = registry.current.resolve(:telegram, "telegram", "-100777")&.endpoint
      rooms = registry.current.topology.rooms_for(origin.id)
      expect(rooms.size).to eq(1)
      expect(rooms.flat_map { |room| room.targets_for(origin) }).to be_empty
    end

    it "still runs the wizard when only one platform has unmapped channels left" do
      dm(boss, "map")
      dm(boss, "1") # tg-new takes a room of its own, leaving only discord unmapped

      prompt = dm(boss, "map")
      expect(prompt).to match(/discord:/)
      expect(prompt).to match(/1\. dc-new/)
      expect(prompt).to match(/Each gets a room of its own/)

      expect(dm(boss, "1")).to match(/Mapped 1 single channel into rooms/)
      channel = models.channel.where(endpoint_key: "dc-new").first
      room_ids = models.room_channel.where(channel_id: channel.id).select_map(:room_id)
      expect(room_ids.size).to eq(1)
      expect(models.room_channel.where(room_id: room_ids.first).count).to eq(1)
    end

    it "reports an out-of-range single channel without mapping it" do
      dm(boss, "map")
      expect(dm(boss, "9")).to match(/Channel 9: out of range/)
    end

    it "cancels the wizard on cancel, mapping nothing" do
      dm(boss, "map")
      expect(dm(boss, "cancel")).to match(/Cancelled/)
      # A following numbered reply is now an ordinary unknown command.
      expect(dm(boss, "1 1")).to match(/Unknown command/)
    end

    it "says there is nothing to map once every channel is mapped" do
      dm(boss, "map")
      dm(boss, "1 1")
      expect(dm(boss, "map")).to match(/already mapped/)
    end
  end

  describe "web login" do
    # A minimal key/value store, exactly the get_state/put_state surface the
    # message map exposes. Token issue and redemption are covered directly in
    # the WebLoginTokens spec; this covers only the console's wiring.
    let(:state_store) do
      Class.new do
        def initialize = @rows = {}

        def get_state(key)
          row = @rows[key.to_s]
          return nil if row.nil?
          return nil if row[:expires_at] && row[:expires_at] <= Time.now

          row[:value]
        end

        def put_state(key, value, expires_at: nil)
          @rows[key.to_s] = { value: value.to_s, expires_at: expires_at }
          nil
        end
      end.new
    end
    let(:web_login) { Rubotty::ControlPlane::WebLoginTokens.new(store: state_store, logger: Rubotty::Log.null) }

    subject(:console) do
      described_class.new(operator_flow: flow, request_lane: request_lane, web_login: web_login,
                          dashboard_url: "https://rubotty.example.org/admin-panel", logger: Rubotty::Log.null)
    end

    it "hands an operator a reusable dashboard sign-in link, good for about an hour" do
      reply = dm(boss, "web-login")
      expect(reply).to match(%r{https://rubotty\.example\.org/admin-panel/operator-login\?token=\S+})
      expect(reply).to match(/valid for about 60 minutes/)
    end

    it "issues a redeemable token scoped to every community the operator runs, needing none in focus" do
      reply = dm(boss, "web-login")
      token = reply[%r{token=(\S+)}, 1]

      outcome = web_login.redeem(token: token)
      expect(outcome).to be_ok
      expect(outcome.community_ids).to eq([models.community.first.id])
    end

    it "never shows a non-operator a sign-in link: their DM is not recognised as the console at all" do
      expect(dm(newcomer, "web-login")).to eq(Rubotty::ControlPlane::ControlLane::DEFAULT_NOTICE)
    end

    it "rate-limits a second request while a link is still outstanding" do
      dm(boss, "web-login")
      reply = dm(boss, "web-login")
      expect(reply).to match(/already have an active sign-in link/i)
    end

    # The viewer dimension rides on this same link, so the console asks the
    # deployment's YAML who holds it and stamps the answer on the token it
    # was about to mint anyway.
    describe "the viewer dimension" do
      # A stand-in for config/dashboard_viewers.yml, which ships empty.
      def viewers_naming(*handles)
        Rubotty::Security::DashboardViewers.new(usernames: handles)
      end

      def console_with(viewers)
        described_class.new(operator_flow: flow, request_lane: request_lane, web_login: web_login,
                            dashboard_url: "https://rubotty.example.org/admin-panel",
                            viewers: viewers, logger: Rubotty::Log.null)
      end

      def redeem_from(reply)
        web_login.redeem(token: reply[%r{token=(\S+)}, 1])
      end

      it "mints a plain operator token for somebody the YAML does not name" do
        reply = console_with(viewers_naming("somebody-else"))
                .handle_dm(adapter: :telegram, account: "telegram", author: boss, text: "web-login")

        expect(redeem_from(reply).viewer).to be(false)
        expect(reply).to match(/It signs you in to: /)
      end

      # Both dimensions on one token: reads across the deployment, writes still
      # only where the operators rows say.
      it "mints a viewer AND operator token for an operator the YAML names" do
        reply = console_with(viewers_naming("sample_owner"))
                .handle_dm(adapter: :telegram, account: "telegram", author: boss, text: "web-login")

        outcome = redeem_from(reply)
        expect(outcome.viewer).to be(true)
        expect(outcome.community_ids).to eq([models.community.first.id])
        expect(reply).to match(/viewer of every community/)
      end

      # A viewer who operates nothing would otherwise never reach the console at
      # all: their DM falls through to the request lane, and there is no other
      # way for them to be handed a link.
      it "lets a viewer who operates nothing ask for a link, and gives them a read-only one" do
        reply = console_with(viewers_naming("newbie"))
                .handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "web-login")

        outcome = redeem_from(reply)
        expect(outcome.viewer).to be(true)
        expect(outcome.community_ids).to eq([])
        expect(reply).to match(/read every community and change nothing/)
      end

      it "still sends a stranger the console does not know to the request lane" do
        reply = console_with(viewers_naming("somebody-else"))
                .handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "web-login")

        expect(reply).to eq(Rubotty::ControlPlane::ControlLane::DEFAULT_NOTICE)
      end

      # The union in one call: the roster resolves the shipped list AND the rows
      # an administrator granted, so a grant made this morning rides this
      # afternoon's link without a deploy.
      it "reads a granted row the same as a handle the deployment ships with" do
        roster = Rubotty::ControlPlane::DashboardViewers.new(
          models: models, floor: viewers_naming("shipped"), logger: Rubotty::Log.null
        )
        roster.grant(adapter: "telegram", handle: "newbie", native_id: "999888", granted_by: "admin")

        granted = console_with(roster)
                  .handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "web-login")
        expect(redeem_from(granted).viewer).to be(true)

        shipped_person = Rubotty::Core::Author.new(native_id: "777", username: "shipped")
        shipped = console_with(roster)
                  .handle_dm(adapter: :telegram, account: "telegram", author: shipped_person, text: "web-login")
        expect(redeem_from(shipped).viewer).to be(true)
      end

      # Matched on the handle, never the display name, which anyone can set to
      # anything.
      it "does not read viewer status off a display name" do
        impostor = Rubotty::Core::Author.new(native_id: "555", username: "impostor", display_name: "ada")
        reply = console_with(viewers_naming("ada"))
                .handle_dm(adapter: :telegram, account: "telegram", author: impostor, text: "web-login")

        expect(reply).to eq(Rubotty::ControlPlane::ControlLane::DEFAULT_NOTICE)
      end
    end

    # The third dimension on the same link. It is the whole point of the issue:
    # an administrator should not have to go and find the root password.
    describe "the administrator dimension" do
      def administrators_naming(*handles)
        Rubotty::Security::DashboardAdministrators.new(usernames: handles)
      end

      def console_with_administrators(administrators)
        described_class.new(operator_flow: flow, request_lane: request_lane, web_login: web_login,
                            dashboard_url: "https://rubotty.example.org/admin-panel",
                            administrators: administrators, logger: Rubotty::Log.null)
      end

      def redeem_from(reply)
        web_login.redeem(token: reply[%r{token=(\S+)}, 1])
      end

      it "mints no administrator claim for somebody no roster names" do
        reply = console_with_administrators(administrators_naming("somebody-else"))
                .handle_dm(adapter: :telegram, account: "telegram", author: boss, text: "web-login")

        expect(redeem_from(reply).administrator).to be(false)
      end

      it "stamps the claim on the link of an administrator who operates a community too" do
        reply = console_with_administrators(administrators_naming("sample_owner"))
                .handle_dm(adapter: :telegram, account: "telegram", author: boss, text: "web-login")

        expect(redeem_from(reply).administrator).to be(true)
        expect(reply).to match(/signs you in as an administrator/)
      end

      # An administrator who operates nothing would otherwise never reach the
      # console at all: their DM would fall through to the request lane.
      it "lets an administrator who operates nothing ask for a link" do
        reply = console_with_administrators(administrators_naming("newbie"))
                .handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "web-login")

        outcome = redeem_from(reply)
        expect(outcome.administrator).to be(true)
        expect(outcome.community_ids).to eq([])
      end

      it "gives that link a shorter life than an ordinary one, and says so" do
        reply = console_with_administrators(administrators_naming("newbie"))
                .handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "web-login")

        expect(reply).to match(/valid for about 10 minutes/)
        expect(reply).to match(/short link on purpose/)
      end

      # Matched on the handle, never the display name, which anyone can set to
      # anything. This is the one that would hand the deployment to a stranger.
      it "does not read the role off a display name" do
        impostor = Rubotty::Core::Author.new(native_id: "555", username: "impostor", display_name: "ada")
        reply = console_with_administrators(administrators_naming("ada"))
                .handle_dm(adapter: :telegram, account: "telegram", author: impostor, text: "web-login")

        expect(reply).to eq(Rubotty::ControlPlane::ControlLane::DEFAULT_NOTICE)
      end

      # The union in one call: the shipped list and the rows an administrator
      # granted resolve the same, so a grant made this morning rides this
      # afternoon's link without a deploy.
      it "reads a granted row the same as a handle the deployment ships with" do
        roster = Rubotty::ControlPlane::DashboardAdministrators.new(
          models: models, floor: administrators_naming("shipped"), logger: Rubotty::Log.null
        )
        roster.grant(adapter: "telegram", handle: "newbie", native_id: "999888", granted_by: "admin")

        granted = console_with_administrators(roster)
                  .handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "web-login")
        expect(redeem_from(granted).administrator).to be(true)

        shipped_person = Rubotty::Core::Author.new(native_id: "777", username: "shipped")
        shipped = console_with_administrators(roster)
                  .handle_dm(adapter: :telegram, account: "telegram", author: shipped_person,
                             text: "web-login")
        expect(redeem_from(shipped).administrator).to be(true)
      end

      it "carries the handle on the token, so the dashboard can ask the roster again" do
        reply = console_with_administrators(administrators_naming("newbie"))
                .handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "web-login")

        expect(redeem_from(reply).operator["username"]).to eq(newcomer.username)
      end
    end

    it "offers web-login in help only when a web-login service is wired" do
      expect(dm(boss, "help")).to match(/web-login\s+get a one-time dashboard sign-in link/)
    end

    it "declines politely when no web-login service is wired" do
      bare = described_class.new(operator_flow: flow, request_lane: request_lane, logger: Rubotty::Log.null)
      reply = bare.handle_dm(adapter: :telegram, account: "telegram", author: boss, text: "web-login")
      expect(reply).to match(/not available on this deployment/i)
      expect(bare.handle_dm(adapter: :telegram, account: "telegram", author: boss, text: "help"))
        .not_to match(/web-login/)
    end
  end

  # These commands have to agree with the dashboard, so the assertions compare
  # the DM's reply against the same services the dashboard's routes call rather
  # than against numbers written out by hand.
  describe "chat-native admin (#298)" do
    # Every example below is about what one operator's ROWS reach, so the floor
    # that would grant the fixture's handle every community is held off.
    before { without_owner_floor }

    let(:db) { seeded[0] }
    let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }
    let(:analytics) { Rubotty::ControlPlane::Analytics.new(db: db, models: models) }

    subject(:console) do
      described_class.new(operator_flow: flow, request_lane: request_lane,
                          feature_controls: controls, analytics: analytics,
                          logger: Rubotty::Log.null)
    end

    # A community nobody here operates, with a feature row of its own, so a
    # leak across the tenant boundary is visible.
    def add_foreign_community
      now = Time.now
      other = models.community.create(slug: "other", name: "Other Guild", status: "active",
                                      settings: "{}", created_at: now, updated_at: now)
      models.feature_setting.create(community_id: other.id, room_id: nil, feature: "faq",
                                    enabled: true, config: "{}", created_at: now, updated_at: now)
      other
    end

    describe "a sender who operates nothing" do
      it "never sees the console: config falls through to the #31 notice" do
        expect(dm(newcomer, "config")).to eq(Rubotty::ControlPlane::ControlLane::DEFAULT_NOTICE)
      end

      it "never sees the console: analytics falls through to the #31 notice" do
        expect(dm(newcomer, "analytics")).to eq(Rubotty::ControlPlane::ControlLane::DEFAULT_NOTICE)
      end

      it "learns nothing about a community's numbers, not even a count" do
        reply = dm(newcomer, "analytics")
        expect(reply).not_to match(/sample/)
        expect(reply).not_to match(/members/i)
      end

      it "writes no feature row when it tries to flip one" do
        dm(newcomer, "config faq on")
        expect(models.feature_setting.where(feature: "faq").count).to eq(0)
      end
    end

    describe "an operator of one community" do
      it "reads that community's features and never another's" do
        add_foreign_community
        reply = dm(boss, "config")

        expect(reply).to match(/Features in sample \(SAMPLE\)/)
        expect(reply).not_to match(/other/)
      end

      it "writes into its own community, leaving a community it does not run alone" do
        other = add_foreign_community
        dm(boss, "config faq off")

        expect(controls.list(models.community.where(slug: "sample").first)
                       .find { |row| row[:feature] == "faq" }[:enabled]).to be(false)
        # The write carried a community_id, so the foreign row is untouched.
        expect(controls.list(other).find { |row| row[:feature] == "faq" }[:enabled]).to be(true)
      end

      it "reports analytics for its own community only" do
        add_foreign_community
        expect(dm(boss, "analytics")).to match(/sample \(SAMPLE\), last 7d/)
      end
    end

    describe "an operator of several communities" do
      let!(:second) { add_second_community }

      it "refuses to guess which community a feature read is about" do
        expect(dm(boss, "config")).to match(/will not guess/i)
      end

      it "refuses to guess which community an analytics read is about" do
        expect(dm(boss, "analytics")).to match(/will not guess/i)
      end

      it "writes NOTHING while it is still asking which community" do
        dm(boss, "config faq on")
        expect(models.feature_setting.where(feature: "faq").count).to eq(0)
      end

      it "flips the feature in the community a one-word answer names" do
        dm(boss, "config faq on")
        reply = dm(boss, "2")

        expect(reply).to match(/Turned faq on for community-wide in second \(Second Guild\)/)
        expect(controls.list(second).find { |row| row[:feature] == "faq" }[:enabled]).to be(true)
        # sample, the community it did not name, has no faq row at all.
        expect(models.feature_setting.where(community_id: models.community.where(slug: "sample").first.id,
                                            feature: "faq").count).to eq(0)
      end

      it "runs a one-off analytics read in another community with @slug" do
        expect(dm(boss, "analytics @second")).to match(/second \(Second Guild\), last 7d/)
      end

      # The same room key exists in two communities. The selector resolves
      # inside the community the command runs in, so an identical name on both
      # sides cannot reach across the boundary.
      it "resolves a room selector inside the community the command runs in" do
        now = Time.now
        twin = models.room.create(community_id: second.id, room_key: "general",
                                  label: "General", created_at: now, updated_at: now)

        dm(boss, "config faq on in general @sample")

        sample = models.community.where(slug: "sample").first
        mine = controls.list(sample).find { |row| row[:feature] == "faq" }
        expect(mine[:room_key]).to eq("general")
        expect(mine[:enabled]).to be(true)
        # The identically-named room in the other community got nothing.
        expect(models.feature_setting.where(community_id: second.id, room_id: twin.id).count).to eq(0)
      end

      it "refuses a config override naming a community the operator does not run" do
        other = add_foreign_community
        before = models.feature_setting.where(feature: "faq").select_map(:id)

        expect(dm(boss, "config faq on @other")).to match(/do not run a community with slug "other"/)
        # The refusal wrote nothing, in the named community or either of theirs.
        expect(models.feature_setting.where(feature: "faq").select_map(:id)).to eq(before)
        expect(controls.list(other).find { |row| row[:feature] == "faq" }[:enabled]).to be(true)
      end
    end

    describe "agreeing with the dashboard" do
      let(:community) { models.community.where(slug: "sample").first }

      it "status reports the same five counts the community overview page totals" do
        reply = dm(boss, "status")

        expect(reply).to match(/platforms:\s+#{models.platform_connection.where(community_id: community.id).count}/)
        expect(reply).to match(/channels:\s+#{models.channel.where(community_id: community.id).count}/)
        expect(reply).to match(/operators:\s+#{models.operator.where(community_id: community.id).count}/)
        expect(reply)
          .to match(/feature settings:\s+#{models.feature_setting.where(community_id: community.id).count}/)
      end

      it "status still leads with the running state, as it always did" do
        expect(dm(boss, "status")).to match(/\Asample \(SAMPLE\) is running\. 0 open operator requests\./)
      end

      it "config lists every catalog feature, not only the ones with a row" do
        reply = dm(boss, "config")

        Rubotty::Features::Catalog.names.each do |feature|
          expect(reply).to match(/\b#{Regexp.escape(feature)}\b/)
        end
      end

      it "shows an untouched feature at its code default, exactly as the matrix does" do
        reply = dm(boss, "config")

        # No row means the code default: off for everything but the bridge.
        expect(reply).to match(/on\s+bridge/)
        expect(reply).to match(/off\s+faq\s+\(default\)/)
      end

      it "shows an always-on feature as on, not as off for lack of a row" do
        reply = dm(boss, "config")

        expect(reply).to match(/on\s+identify_topic\s+\(always on\)/)
      end

      it "explains that an always-on feature has no toggle, rather than naming a fake default" do
        expect(dm(boss, "config disabled_command_notice"))
          .to match(/disabled_command_notice runs unconditionally .+ and has no toggle/)
      end

      it "refuses to flip an always-on feature, same as the dashboard" do
        expect(dm(boss, "config identify_topic on")).to match(/that did not work.*always runs here/i)
      end

      it "reads a feature's enabled state back through the same service the dashboard writes with" do
        controls.enable(community: community, selector: "general", feature: "faq")
        reply = dm(boss, "config faq")

        expect(reply).to match(/on\s+room general/)
      end

      it "shows a config key the dashboard's editor would show" do
        controls.set(community: community, selector: "all", feature: "faq", key: "match", value: "fuzzy")
        expect(dm(boss, "config faq")).to match(/match = fuzzy/)
      end

      it "coerces a value exactly as the CLI and the dashboard do" do
        dm(boss, "config word_filter set words foo, bar")
        stored = controls.list(community).find { |row| row[:feature] == "word_filter" }[:config]

        expect(stored["words"]).to eq(%w[foo bar])
      end

      it "analytics reports the same totals Analytics#overview hands the dashboard" do
        report = analytics.overview(community: community, window: "7d")
        reply = dm(boss, "analytics")

        expect(reply).to match(/members\s+#{report[:members][:total]} known/)
        expect(reply).to match(/moderation\s+#{report[:moderation][:total]} actions/)
      end

      it "honours the window the dashboard's picker offers" do
        expect(dm(boss, "analytics 30d")).to match(/last 30d/)
      end

      it "falls back to the dashboard's default window for an unknown one" do
        expect(dm(boss, "analytics nonsense")).to match(/last #{Rubotty::ControlPlane::Analytics::DEFAULT_WINDOW}/)
      end

      it "says plainly when a panel's table is absent rather than reporting a zero" do
        # relay_claims is not created by the control-plane migration, so the
        # message panel is genuinely unavailable here.
        expect(dm(boss, "analytics")).to match(/messages\s+not recorded on this deployment/)
      end
    end

    describe "bad input" do
      it "names the real features when asked about one that does not exist" do
        expect(dm(boss, "config nope")).to match(/no feature called "nope"/i)
      end

      it "passes the service's own complaint back when a room selector matches nothing" do
        expect(dm(boss, "config faq on in nowhere")).to match(/no room in community/i)
      end

      it "asks for a key when set is given none" do
        expect(dm(boss, "config faq set")).to match(/which key/i)
      end

      it "asks for a value when set is given only a key" do
        expect(dm(boss, "config faq set match")).to match(/which value/i)
      end

      it "reads a hyphenated feature name as the underscored one" do
        expect(dm(boss, "config word-filter")).not_to match(/no feature called/i)
      end

      # `@<slug>` is the community override wherever it sits, so a value
      # beginning with it is read as a community name. It has to fail safe,
      # refusing and writing nothing.
      it "refuses rather than misfiling a config value that starts with the override sigil" do
        reply = dm(boss, "config greetings set message @everyone")

        expect(reply).to match(/do not run a community with slug "everyone"/)
        expect(models.feature_setting.where(feature: "greetings").count).to eq(0)
      end
    end

    describe "when a service or a platform cannot carry the command" do
      let(:bare) do
        described_class.new(operator_flow: flow, request_lane: request_lane, logger: Rubotty::Log.null)
      end

      def bare_dm(text)
        bare.handle_dm(adapter: :telegram, account: "telegram", author: boss, text: text)
      end

      it "declines config honestly when no feature-controls service is wired" do
        expect(bare_dm("config")).to match(/not available on this deployment/i)
      end

      it "declines analytics honestly when no analytics service is wired" do
        expect(bare_dm("analytics")).to match(/not available on this deployment/i)
      end

      it "does not offer either command in help when neither is wired" do
        reply = bare_dm("help")
        expect(reply).not_to match(/^\s+config/)
        expect(reply).not_to match(/^\s+analytics/)
      end

      it "offers both in help once they are wired" do
        reply = dm(boss, "help")
        expect(reply).to match(/config <feature> on\|off/)
        expect(reply).to match(/analytics \[24h\|7d\|30d\|90d\]/)
      end

      # Only Telegram and Discord implement #handle_control_gesture. Asserted
      # so an adapter gaining or losing a DM lane has to update this list.
      it "only reaches the console on the platforms with an inbound DM lane" do
        carries_dm = lambda do |klass|
          klass.method_defined?(:handle_control_gesture) ||
            klass.private_method_defined?(:handle_control_gesture)
        end

        expect(carries_dm.call(Rubotty::Adapters::Telegram::Adapter)).to be(true)
        expect(carries_dm.call(Rubotty::Adapters::Discord::Adapter)).to be(true)

        [Rubotty::Adapters::Matrix::Adapter, Rubotty::Adapters::Irc::Adapter,
         Rubotty::Adapters::Xmpp::Adapter].each do |klass|
          expect(carries_dm.call(klass)).to be(false), "#{klass} looks like it grew a DM lane"
        end
      end
    end
  end

  # One verb for asking about a role, with the role as its argument. An
  # operator already holds one here, so most of what this answers is what each
  # role is and where it applies.
  describe "vindicating a content policy action" do
    # Stands in for ContentPolicy::Vindication: the console's whole job here
    # is to find the community, hand over the code and the operator's words,
    # and read the outcome back in English.
    class ConsoleVindication
      attr_reader :calls

      def initialize(outcome, open: [], holds: {})
        @outcome = outcome
        @open = open
        @holds = holds
        @calls = []
      end

      def available? = true

      def recent(community_id:) = @open

      def holds?(community_id:, code:) = Array(@holds[code.to_s]).include?(community_id)

      def vindicate(community:, code:, operator:, statement: nil)
        @calls << { community_id: community.id, code: code, operator: operator, statement: statement }
        @outcome
      end
    end

    OpenAction = Struct.new(:code, :action, :author_name, :policy, keyword_init: true)

    def outcome(**fields)
      Rubotty::ContentPolicy::Vindication::Outcome.new(
        **{ status: :reversed, action: "delete", author: "Ada", policy: "Racial slurs",
            restored: true, removed: true, told_author: true, silent: false }.merge(fields)
      )
    end

    def console_with(vindication)
      described_class.new(operator_flow: flow, request_lane: request_lane,
                          vindication: vindication, logger: Rubotty::Log.null)
    end

    def vindicate(text, result = outcome, quoted: nil, open: [])
      service = ConsoleVindication.new(result, open: open)
      reply = console_with(service).handle_dm(adapter: :telegram, account: "telegram", author: boss,
                                              text: text, quoted: quoted)
      [reply, service]
    end

    # The alert an operator replies to, in the shape the DM actually carries.
    def alert_text(code = "bq7k")
      "Example Travel: Erik matched the \"Potentially offensive language\" policy " \
        "(https://t.me/c/8000000002/7044/12602). Message: \"something\" Reasoning: because. " \
        "Confidence: 0.80 Wrong? Answer with /vindicate #{code} <why>."
    end

    # The alert an operator replied to names its own community, so asking which
    # one is a question the message answered before it was sent. The code
    # decides it rather than the name the alert opens with, since a code is
    # unique per community and a name is prose.
    context "when the operator runs several communities" do
      let!(:second) { add_second_community }

      def reply_to_alert(service, code: "bq7k")
        console_with(service).handle_dm(adapter: :telegram, account: "telegram", author: boss,
                                        text: "/vindicate it is the name of a channel",
                                        quoted: alert_text(code))
      end

      it "reads the community out of the alert instead of asking" do
        first = models.community.first
        service = ConsoleVindication.new(outcome, holds: { "bq7k" => [first.id] })

        reply = reply_to_alert(service)

        expect(reply).not_to match(/will not guess/i)
        expect(service.calls.first).to include(community_id: first.id, code: "bq7k")
      end

      # An operator who typed the code out rather than replying has named the
      # action just as exactly, so the same lookup answers it.
      it "reads the community from a code typed on the line, with no reply at all" do
        first = models.community.first
        service = ConsoleVindication.new(outcome, holds: { "bq7k" => [first.id] })

        reply = console_with(service).handle_dm(
          adapter: :telegram, account: "telegram", author: boss,
          text: "/vindicate bq7k it is the name of a channel"
        )

        expect(reply).not_to match(/will not guess/i)
        expect(service.calls.first).to include(community_id: first.id, code: "bq7k")
      end

      # Four characters collide across communities eventually, and reversing
      # the wrong community's action is worse than one more question.
      it "still asks when the code names an action in more than one of them" do
        ids = models.community.all.map(&:id)
        service = ConsoleVindication.new(outcome, holds: { "bq7k" => ids })

        expect(reply_to_alert(service)).to match(/will not guess/i)
        expect(service.calls).to be_empty
      end

      it "still asks when the code names an action in none of them" do
        service = ConsoleVindication.new(outcome, holds: {})

        expect(reply_to_alert(service)).to match(/will not guess/i)
        expect(service.calls).to be_empty
      end
    end

    it "hides the command when no reversal service is wired, so nothing advertises a dead verb" do
      expect(dm(boss, "help")).not_to match(/vindicate/)
      expect(vindicate("help").first).to match(/vindicate <code>/)
    end

    it "passes the code and everything after it as the operator's own words" do
      _reply, service = vindicate("/vindicate bq7k they were quoting the rule, not breaking it")

      expect(service.calls.first).to include(code: "bq7k",
                                             statement: "they were quoting the rule, not breaking it")
    end

    it "names the operator by the platform they answered from, which is what the audit trail keeps" do
      _reply, service = vindicate("vindicate bq7k my call")

      expect(service.calls.first[:operator]).to eq("telegram:sample_owner")
    end

    it "takes innocent as the same verb, since an alert reader reaches for either word" do
      _reply, service = vindicate("innocent bq7k sorry")

      expect(service.calls.first[:code]).to eq("bq7k")
    end

    it "asks for a code rather than guessing when the line carries none" do
      reply, service = vindicate("vindicate")

      expect(reply).to match(/Which action\?/)
      expect(service.calls).to be_empty
    end

    # The gesture an operator actually makes: reply to the alert and say why.
    # Retyping a code that is already in the message above is the sort of thing
    # nobody does on a phone.
    describe "answering an alert by replying to it" do
      it "reads the code out of the alert, so a bare vindicate works" do
        _reply, service = vindicate("/vindicate", quoted: alert_text)

        expect(service.calls.first[:code]).to eq("bq7k")
      end

      it "takes the whole line as the operator's words when the code came from the alert" do
        _reply, service = vindicate("/vindicate he was quoting somebody else", quoted: alert_text)

        expect(service.calls.first).to include(code: "bq7k", statement: "he was quoting somebody else")
      end

      it "prefers a code typed on the line over the one the alert carried" do
        _reply, service = vindicate("vindicate wxyz my reason", quoted: alert_text("bq7k"))

        expect(service.calls.first).to include(code: "wxyz", statement: "my reason")
      end

      # Anything the bot said that was not an alert carries no code, so the
      # reply is answered the same way a bare command with no reply is.
      it "ignores a reply to something that is not an alert" do
        reply, service = vindicate("/vindicate", quoted: "Now working in sample (SAMPLE).")

        expect(service.calls).to be_empty
        expect(reply).to match(/Which action\?/)
      end

      # Both kinds of alert carry a code of the same shape, so only the verb an
      # alert advertised tells them apart. A proposal names approve and reject,
      # which vindicate never reads, so its code is not looked up here.
      it "ignores a reply to a topic move proposal, whose code names no action" do
        proposal = "Example Travel: Ada posted in General, and this reads like Banking. " \
                   "Move it? Answer /approve m3xt, or /reject m3xt <why>."
        reply, service = vindicate("/vindicate", quoted: proposal)

        expect(service.calls).to be_empty
        expect(reply).to match(/Which action\?/)
      end
    end

    # A dead end helped nobody: an operator who lost the alert still needs to
    # find out which codes are live.
    it "lists what is still open when nothing named an action" do
      open = [OpenAction.new(code: "bq7k", action: "flag_notify", author_name: "Erik",
                             policy: "Potentially offensive language")]
      reply, = vindicate("vindicate", outcome, open: open)

      expect(reply).to include("bq7k")
      expect(reply).to include("Erik")
      expect(reply).to include("Potentially offensive language")
    end

    it "says what landed: the community, the author, the restored message and the author being told" do
      reply, = vindicate("vindicate bq7k fine")

      expect(reply).to match(/Reversed bq7k in sample \(SAMPLE\)/)
      expect(reply).to include("Ada was moderated for \"Racial slurs\"")
      expect(reply).to include("back in the room")
      expect(reply).to include("They have been told")
    end

    it "says plainly when the author could not be told, so the operator knows to do it themselves" do
      reply, = vindicate("vindicate bq7k fine", outcome(told_author: false, restored: false))

      expect(reply).to include("could not be put back")
      expect(reply).to include("could not be told")
    end

    # A flag leaves the message where it is, so a reversal of one has nothing to
    # put back and no failure to report. It read as an error against an action
    # that had done exactly what it was configured to do.
    it "does not report a failed restore for an action that never removed anything" do
      reply, = vindicate("vindicate bq7k fine",
                         outcome(action: "flag_notify", restored: false, removed: false))

      expect(reply).to include("never taken down")
      expect(reply).not_to include("could not be put back")
      expect(reply).to include("They have been told")
    end

    it "explains a notify reversal, where there was never anything on the message to undo" do
      reply, = vindicate("vindicate bq7k fine", outcome(action: "notify", silent: true,
                                                        restored: false, told_author: false))

      expect(reply).to include("nothing to undo")
      expect(reply).not_to include("could not be told")
    end

    it "reports an unknown code against the community it looked in" do
      reply, = vindicate("vindicate zzzz", outcome(status: :unknown))

      expect(reply).to match(/No content policy action zzzz in sample \(SAMPLE\)/)
    end

    it "refuses a code somebody already answered, rather than reporting a second reversal" do
      reply, = vindicate("vindicate bq7k fine", outcome(status: :already))

      expect(reply).to match(/already been reversed/)
    end

    # A code is minted per community, so the same four letters can name a
    # different action in each: the console asks rather than picking one.
    it "asks which community when the operator runs several and named none" do
      add_second_community
      reply, service = vindicate("vindicate bq7k fine")

      expect(reply).to match(/will not guess which one/)
      expect(service.calls).to be_empty
    end

    it "acts in the community an @slug names, without changing the one being worked in" do
      add_second_community
      _reply, service = vindicate("vindicate bq7k fine @sample")

      expect(service.calls.first[:community_id]).to eq(models.community.first.id)
    end

    # The statement is written for the author to read, so a handle part way
    # through it is the operator's own words and never a community override.
    it "leaves a handle inside the operator's words alone" do
      _reply, service = vindicate("vindicate bq7k sorry @ada, my mistake")

      expect(service.calls.first[:statement]).to eq("sorry @ada, my mistake")
    end
  end

  describe "answering a topic move proposal" do
    ProposalOutcome = Rubotty::SemanticAnalysis::MoveDecisions::Outcome
    OpenProposal = Struct.new(:code, :from_room, :to_room, :author_name, keyword_init: true)

    class ConsoleProposals
      attr_reader :calls

      def initialize(outcome, open: [], holds: {})
        @outcome = outcome
        @open = open
        @holds = holds
        @calls = []
      end

      def holds?(community_id:, code:) = Array(@holds[code.to_s]).include?(community_id)

      def available? = true

      def pending(community_id:) = @open

      def settle(community:, code:, operator:, approve:, reason: nil)
        @calls << { code: code, operator: operator, approve: approve, reason: reason }
        @outcome
      end
    end

    def decided(**fields)
      ProposalOutcome.new(**{ status: :decided, state: "approved", author: "Ada",
                              from_room: "general", to_room: "banking", moved: true }.merge(fields))
    end

    def answer(text, result = decided, quoted: nil, open: [])
      service = ConsoleProposals.new(result, open: open)
      console = described_class.new(operator_flow: flow, request_lane: request_lane,
                                    proposals: service, logger: Rubotty::Log.null)
      reply = console.handle_dm(adapter: :telegram, account: "telegram", author: boss,
                                text: text, quoted: quoted)
      [reply, service]
    end

    def proposal_alert(code = "bq7k")
      "Example Travel: Ada posted in General, and this reads like Banking. " \
        "Move it? Answer /approve #{code}, or /reject #{code} <why>."
    end

    it "approves by code and says what happened" do
      reply, service = answer("/approve bq7k")

      expect(service.calls.first).to include(code: "bq7k", approve: true)
      expect(reply).to include("Approved bq7k")
      expect(reply).to include("moving it now")
    end

    it "rejects with the operator's reason, which is optional" do
      _reply, service = answer("/reject bq7k banking talk belongs here too")

      expect(service.calls.first).to include(approve: false, reason: "banking talk belongs here too")
      _reply2, bare = answer("/reject bq7k")
      expect(bare.calls.first).to include(approve: false, reason: "")
    end

    it "reads the code out of the proposal a reply answers" do
      _reply, service = answer("/approve", quoted: proposal_alert)

      expect(service.calls.first[:code]).to eq("bq7k")
    end

    # The mirror of the same guard: an action alert names vindicate, which
    # approve never reads, so a reply to one opens no proposal.
    it "ignores a reply to a content policy alert, whose code names no proposal" do
      alert = "rubotty removed a message for offensive language. " \
              "Wrong? Answer with /vindicate m3xt <why>."
      _reply, service = answer("/approve", quoted: alert)

      expect(service.calls).to be_empty
    end

    # The same inference the vindication alerts get: a proposal DM names its
    # community, so answering one should not stop to ask which.
    context "when the operator runs several communities" do
      let!(:second) { add_second_community }

      def answer_proposal(service)
        console = described_class.new(operator_flow: flow, request_lane: request_lane,
                                      proposals: service, logger: Rubotty::Log.null)
        console.handle_dm(adapter: :telegram, account: "telegram", author: boss,
                          text: "/approve", quoted: proposal_alert)
      end

      it "reads the community out of the proposal instead of asking" do
        first = models.community.first
        service = ConsoleProposals.new(decided, holds: { "bq7k" => [first.id] })

        reply = answer_proposal(service)

        expect(reply).not_to match(/will not guess/i)
        expect(service.calls.first).to include(code: "bq7k", approve: true)
      end

      # An operator who typed the code out rather than replying has named the
      # proposal just as exactly, so the same lookup answers it.
      it "reads the community from a code typed on the line, with no reply at all" do
        first = models.community.first
        service = ConsoleProposals.new(decided, holds: { "bq7k" => [first.id] })
        console = described_class.new(operator_flow: flow, request_lane: request_lane,
                                      proposals: service, logger: Rubotty::Log.null)

        reply = console.handle_dm(adapter: :telegram, account: "telegram", author: boss,
                                  text: "/approve bq7k")

        expect(reply).not_to match(/will not guess/i)
        expect(service.calls.first).to include(code: "bq7k", approve: true)
      end

      it "still asks when the code names a proposal in more than one of them" do
        service = ConsoleProposals.new(decided, holds: { "bq7k" => models.community.all.map(&:id) })

        expect(answer_proposal(service)).to match(/will not guess/i)
        expect(service.calls).to be_empty
      end

      it "still asks when the code names a proposal in none of them" do
        service = ConsoleProposals.new(decided, holds: {})

        expect(answer_proposal(service)).to match(/will not guess/i)
        expect(service.calls).to be_empty
      end
    end

    # This fake answered #find for as long as the console reached for one,
    # holding every example above green while the real MoveDecisions had no
    # such method and every inference failed in production (#1957). Pin the
    # surface so a fake cannot drift off what it stands for again.
    it "stands in for a real MoveDecisions, method for method" do
      real = Rubotty::SemanticAnalysis::MoveDecisions.instance_methods
      %i[available? pending settle holds?].each do |name|
        expect(real).to include(name)
        expect(ConsoleProposals.instance_methods).to include(name)
      end
    end

    # approve and reject already answer operator requests, named by a numeric
    # id. The two can never be confused, so neither verb had to be renamed.
    it "still answers an operator request when the argument is an id" do
      request = flow.request(community_id: models.community.first.id, adapter: "telegram",
                             native_id: "999888", username: "newbie", display: "New Bie").request
      reply, service = answer("approve #{request.id}")

      expect(service.calls).to be_empty
      expect(reply).to match(/Approved ##{request.id}/)
    end

    it "says so when a proposal was already answered or has lapsed" do
      expect(answer("/approve bq7k", decided(status: :settled, state: "rejected")).first)
        .to match(/already been answered|already answered/)
      expect(answer("/approve bq7k", decided(status: :lapsed)).first).to match(/lapsed/)
    end

    it "lists what is open when the code resolves to nothing" do
      open = [OpenProposal.new(code: "wxyz", from_room: "general", to_room: "banking",
                               author_name: "Ada")]
      reply, = answer("/approve bq7k", decided(status: :unknown), open: open)

      expect(reply).to include("wxyz")
      expect(reply).to include("general to banking")
    end
  end

  describe "the role command" do
    let(:community_viewers) do
      Rubotty::ControlPlane::CommunityViewers.new(models: models, logger: Rubotty::Log.null)
    end

    subject(:console) do
      described_class.new(operator_flow: flow, request_lane: request_lane,
                          community_viewers: community_viewers, logger: Rubotty::Log.null)
    end

    it "lists the roles when the command names none" do
      reply = dm(boss, "/role")

      expect(reply).to match(/role operator/)
      expect(reply).to match(/role viewer/)
    end

    it "tells an operator they already hold the operator role here" do
      expect(dm(boss, "/role operator")).to match(/already an operator/i)
    end

    # An operator of the community already reads it, so there is nothing there
    # to ask for and no row is written.
    it "tells an operator they already read the community they run" do
      expect(dm(boss, "/role viewer")).to match(/already read it/i)
      expect(community_viewers.pending(community_id: models.community.first.id)).to be_empty
    end

    it "offers the command in help, and no longer offers a command per role" do
      reply = dm(boss, "help")

      expect(reply).to match(/role <name>/)
      expect(reply).not_to include("admin-viewer")
    end

    it "says so plainly when there is nowhere to file a viewer request" do
      bare = described_class.new(operator_flow: flow, request_lane: request_lane, logger: Rubotty::Log.null)
      allow(flow).to receive(:request).and_return(
        Rubotty::ControlPlane::OperatorFlow::Result.new(status: :created)
      )

      reply = bare.handle_dm(adapter: :telegram, account: "telegram", author: viewer_only, text: "/role viewer")

      expect(reply).to match(/not available on this deployment/i)
    end

    # Somebody who reads one community and operates none: the console is where
    # their sign-in link comes from, so the role command has to answer there too.
    it "files a request for somebody who reads a community but operates none" do
      community_viewers.grant(community_id: models.community.first.id, adapter: "telegram",
                              handle: "onlooker", native_id: "424242", granted_by: "seeded")

      reply = console.handle_dm(adapter: :telegram, account: "telegram", author: viewer_only,
                                text: "/role viewer")

      expect(reply).to match(/already read/i)
    end
  end

  # Reading one community and changing nothing in it, carried on the same
  # sign-in link the deployment-wide dimension rides.
  describe "a community viewer's web-login link" do
    let(:store) { Rubotty::Storage::Memory.new }
    let(:web_login) { Rubotty::ControlPlane::WebLoginTokens.new(store: store, logger: Rubotty::Log.null) }
    let(:community_viewers) do
      Rubotty::ControlPlane::CommunityViewers.new(models: models, logger: Rubotty::Log.null)
    end

    subject(:console) do
      described_class.new(operator_flow: flow, request_lane: request_lane, web_login: web_login,
                          community_viewers: community_viewers, logger: Rubotty::Log.null)
    end

    it "carries the community it reads, and no write scope at all" do
      community = models.community.first
      community_viewers.grant(community_id: community.id, adapter: "telegram",
                              handle: "onlooker", native_id: "424242", granted_by: "seeded")

      reply = console.handle_dm(adapter: :telegram, account: "telegram", author: viewer_only,
                                text: "web-login")
      outcome = web_login.redeem(token: reply[%r{token=(\S+)}, 1])

      expect(outcome.viewer).to be(false)
      expect(outcome.viewer_communities).to eq([community.id])
      expect(outcome.community_ids).to eq([])
      expect(reply).to match(/read sample/i)
    end
  end

  describe Rubotty::ControlPlane::OperatorConsole::KvSessions do
    # A minimal key/value store, exactly the get_state/put_state surface the
    # message map exposes.
    let(:store) do
      Class.new do
        def initialize = @h = {}
        def get_state(key) = @h[key]
        def put_state(key, value, expires_at: nil) = @h[key] = value
      end.new
    end

    subject(:sessions) { described_class.new(store) }

    it "round-trips a session hash as JSON under a namespaced key" do
      sessions.write("telegram:telegram:1", { "community_id" => 7 })
      expect(sessions.read("telegram:telegram:1")).to eq("community_id" => 7)
      expect(store.get_state("console:telegram:telegram:1")).to include("community_id")
    end

    it "reads an empty hash for an unknown or unparseable key" do
      expect(sessions.read("nope")).to eq({})
      store.put_state("console:bad", "not json")
      expect(sessions.read("bad")).to eq({})
    end
  end
end
