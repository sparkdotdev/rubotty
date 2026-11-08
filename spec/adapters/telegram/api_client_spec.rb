# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Telegram::ApiClient do
  # A Telegram URL embeds the bot token, and URI.parse puts the whole URL into
  # the message when it raises, so a malformed token must fail scrubbed.
  describe "a malformed token never reaches an error message" do
    # The embedded space is what makes URI.parse reject the URL.
    let(:token) { "123456:SECRETTOKEN has a space" }

    it "raises a redacted AdapterError from a bare url build" do
      client = described_class.new(token: token, http: nil)
      expect { client.send(:url_for, "getMe") }.to raise_error(Rubotty::AdapterError) do |error|
        expect(error.message).not_to include("SECRETTOKEN")
        expect(error.message).not_to include(token)
      end
    end

    it "raises a redacted AdapterError through call, without attempting the request" do
      http = instance_spy(Rubotty::Adapters::Telegram::BotApi)
      client = described_class.new(token: token, http: http)

      expect { client.call("getMe") }.to raise_error(Rubotty::AdapterError) do |error|
        expect(error.message).not_to include("SECRETTOKEN")
        expect(error.message).not_to include(token)
      end
      expect(http).not_to have_received(:call)
    end

    it "still builds a normal URL for a well formed token" do
      client = described_class.new(token: "123456:AAgoodtoken")
      uri = client.send(:url_for, "getMe")
      expect(uri).to be_a(URI::HTTPS)
      expect(uri.to_s).to eq("https://api.telegram.org/bot123456:AAgoodtoken/getMe")
    end
  end

  # A 409 from getUpdates means another process is already long-polling this
  # bot, and Telegram only ever serves one.
  describe "a getUpdates 409 becomes one clear, specific message" do
    let(:http) { Fakes::TelegramHttp.new }

    it "raises an AdapterError naming the real cause rather than the raw Telegram text" do
      http.error_on("getUpdates", code: 409,
                                  description: "Conflict: terminated by other getUpdates request")
      client = described_class.new(token: "t", http: http)

      expect { client.call("getUpdates", offset: 1) }.to raise_error(Rubotty::AdapterError) do |error|
        expect(error.message).to eq("another getUpdates instance is polling for this bot")
        expect(error.retryable?).to be(true)
      end
    end

    it "logs that same clear message once, rather than leaving it to a generic caller" do
      lines = []
      logger = instance_double(Logger)
      allow(logger).to receive(:warn) { |&block| lines << block.call }
      http.error_on("getUpdates", code: 409, description: "Conflict: terminated by other getUpdates request")
      client = described_class.new(token: "t", http: http, logger: logger)

      expect { client.call("getUpdates", offset: 1) }.to raise_error(Rubotty::AdapterError)

      expect(lines.join("\n")).to include("another getUpdates instance is polling for this bot")
    end

    # A 409 from any other call is a real Telegram conflict of its own.
    it "does not misreport a 409 from a different call as the getUpdates collision" do
      http.error_on("sendMessage", code: 409, description: "Conflict: something else entirely")
      client = described_class.new(token: "t", http: http)

      expect { client.call("sendMessage", chat_id: 1, text: "hi") }.to raise_error(Rubotty::AdapterError) do |error|
        expect(error.message).not_to include("getUpdates")
        expect(error.message).to include("something else entirely")
      end
    end
  end

  # getFile refuses anything over 20MB, which is the single most predictable
  # attachment loss on Telegram. #file_url used to swallow that failure and
  # answer nil, which meant Inbound#resolve_file's own rescue could never see
  # it and warn.
  describe "#file_url" do
    let(:http) { Fakes::TelegramHttp.new }
    let(:client) { described_class.new(token: "t", http: http) }

    it "raises rather than swallowing a getFile failure" do
      http.error_on("getFile", code: 400, description: "Bad Request: file is too big")
      expect { client.file_url("f1") }.to raise_error(Rubotty::AdapterError, /too big/)
    end

    it "builds the download URL from a successful getFile" do
      http.on("getFile", "file_path" => "photos/f1.jpg")
      expect(client.file_url("f1")).to eq("https://api.telegram.org/file/bott/photos/f1.jpg")
    end
  end

  # Everywhere else in the suite the Bot API seam is a fake, so this is the
  # one place the real telegram-bot-ruby dispatch runs. It raises on the
  # status alone, but Telegram sends its ordinary error envelope alongside
  # that status, so recovering the envelope is what keeps every error below readable.
  describe "over the real gem dispatch" do
    let(:token) { "123456:AAgoodtoken" }
    let(:transport) { Rubotty::Adapters::Telegram::BotApi.new(token: token) }
    let(:client) { described_class.new(token: token, http: transport) }

    # The env carries the request URL the way a real response does, token in the
    # path and all, because the gem's own exception reads it back out.
    def response(status, body)
      env = instance_double(Faraday::Env, url: URI.parse("https://api.telegram.org/bot#{token}/getMe"))
      instance_double(Faraday::Response, status: status, body: body, env: env)
    end

    def answers(status, body)
      allow(transport.send(:api).connection).to receive(:post).and_return(response(status, body))
    end

    def telegram_error(code, description, parameters = nil)
      payload = { "ok" => false, "error_code" => code, "description" => description }
      payload["parameters"] = parameters if parameters
      JSON.generate(payload)
    end

    it "returns the result of a call Telegram accepted" do
      answers(200, JSON.generate("ok" => true, "result" => { "message_id" => 7 }))
      expect(client.call("sendMessage", chat_id: 1, text: "hi")).to eq({ "message_id" => 7 })
    end

    it "reads the description out of a 400 rather than reporting a bare status" do
      answers(400, telegram_error(400, "Bad Request: chat not found"))
      expect { client.call("sendMessage", chat_id: 1, text: "hi") }
        .to raise_error(Rubotty::AdapterError, /chat not found/)
    end

    # Telegram has no error code for "that message is gone": every shape of it
    # is a 400 whose description says so. Content policy reads this to spot a
    # member deleting their own message, since the Bot API never reports one.
    it "recognises every phrasing of a message that is not there" do
      ["Bad Request: message to react not found",
       "Bad Request: message to delete not found",
       "Bad Request: message not found"].each do |description|
        answers(400, telegram_error(400, description))
        expect { client.call("setMessageReaction", chat_id: 1) }
          .to raise_error(Rubotty::MessageGoneError), description
      end
    end

    # Read as gone, this would repost a message still sitting in the room.
    it "leaves another 400 an ordinary adapter error, never a gone message" do
      answers(400, telegram_error(400, "Bad Request: chat not found"))
      expect { client.call("setMessageReaction", chat_id: 1) }
        .not_to raise_error(Rubotty::MessageGoneError)
    end

    # The new id is the one thing that lets the mapped channel follow the group.
    it "keeps the supergroup id a 400 for an upgraded group names" do
      answers(400, telegram_error(400, "Bad Request: group chat was upgraded to a supergroup chat",
                                  { "migrate_to_chat_id" => -1_004_429_957_423 }))
      expect { client.call("sendMessage", chat_id: -5_223_379_096, text: "hi") }
        .to raise_error(Rubotty::Adapters::Telegram::ChatMigratedError) { |error|
          expect(error.migrate_to_chat_id).to eq(-1_004_429_957_423)
          expect(error.retryable?).to be(false)
        }
    end

    it "still recognises a 403 as a permission problem" do
      answers(403, telegram_error(403, "Forbidden: bot was kicked from the supergroup chat"))
      expect { client.call("sendMessage", chat_id: 1, text: "hi") }
        .to raise_error(Rubotty::PermissionError)
    end

    # Losing retry_after would turn a paced retry into a hot loop against a
    # Telegram that has already said to wait.
    it "still carries retry_after off a 429" do
      answers(429, telegram_error(429, "Too Many Requests", { "retry_after" => 12 }))
      expect { client.call("sendMessage", chat_id: 1, text: "hi") }
        .to raise_error(Rubotty::RateLimitedError) { |error| expect(error.retry_after).to eq(12) }
    end

    it "still reduces a getUpdates 409 to the one cause it can have" do
      answers(409, telegram_error(409, "Conflict: terminated by other getUpdates request"))
      expect { client.call("getUpdates", offset: 1) }
        .to raise_error(Rubotty::AdapterError, "another getUpdates instance is polling for this bot")
    end

    # The gem's own exception quotes the request URL when the body will not
    # parse, and a Telegram URL carries the bot token in its path.
    it "does not leak the token when the error body is not JSON at all" do
      answers(502, "<html>bad gateway</html>")
      expect { client.call("getMe") }.to raise_error(Rubotty::AdapterError) do |error|
        expect(error.message).not_to include("AAgoodtoken")
        expect(error.message).to include("502")
        expect(error.retryable?).to be(true)
      end
    end

    # The poll loop only knows how to retry an AdapterError, so anything else
    # reaching it kills the receive thread and takes the bridge off the air.
    [Faraday::ConnectionFailed, Faraday::SSLError, SocketError, Errno::ECONNRESET].each do |failure|
      it "turns a #{failure} into a retryable error rather than letting it escape" do
        allow(transport.send(:api).connection).to receive(:post).and_raise(failure, "no route")
        expect { client.call("getMe") }.to raise_error(Rubotty::AdapterError) do |error|
          expect(error.retryable?).to be(true)
        end
      end
    end

    it "reports a Faraday timeout as a timeout, which is what a long poll hits first" do
      allow(transport.send(:api).connection).to receive(:post).and_raise(Faraday::TimeoutError)
      expect { client.call("getUpdates") }.to raise_error(Rubotty::AdapterError, /timed out/)
    end

    describe "what actually goes on the wire" do
      let(:sent) { [] }

      before do
        allow(transport.send(:api).connection).to receive(:post) do |_path, params|
          sent << params
          response(200, JSON.generate("ok" => true, "result" => []))
        end
      end

      # The gem forwards a nil as an empty form field, and Telegram rejects an
      # explicit null for an optional parameter, so stripping them is still ours.
      it "drops a nil parameter instead of sending it empty" do
        client.call("sendMessage", chat_id: 1, text: "hi", reply_to_message_id: nil)
        expect(sent.first).not_to have_key(:reply_to_message_id)
        expect(sent.first[:text]).to eq("hi")
      end

      # Form encoding is what the gem uses, and a nested value survives it by
      # being JSON encoded on the way out.
      it "JSON encodes a nested parameter so Telegram still receives structure" do
        client.call("getUpdates", offset: 1, allowed_updates: %w[message message_reaction])
        expect(JSON.parse(sent.first[:allowed_updates])).to eq(%w[message message_reaction])
      end
    end
  end
end
