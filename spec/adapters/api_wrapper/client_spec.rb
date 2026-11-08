# frozen_string_literal: true

require "spec_helper"

# The thing that actually signs and sends an api_wrapper account's outbound
# webhook POSTs. adapter_spec.rb always swaps in Fakes::ApiWrapperClient, so
# these specs build the real Client instead, with injected http: and
# resolver: stubs, to exercise the real signing and failover.
RSpec.describe Rubotty::Adapters::ApiWrapper::Client do
  let(:secret) { "whsec_" + Base64.strict_encode64("s" * 24) }
  let(:webhook_url) { "https://hooks.example.invalid/deliver" }
  let(:public_resolver) { ->(_host) { ["93.184.216.34"] } }

  RawResponse = Struct.new(:code, :body)

  # Stands in for the socket: records what was sent and hands back a canned
  # response, so a spec can assert on the request without opening one. Answers
  # #code and #body, the shape Net::HTTP itself would hand #post.
  def fake_http(status: 200, body: "ok", &capture)
    lambda do |uri, headers, request_body|
      capture&.call(uri, headers, request_body)
      RawResponse.new(status.to_s, body)
    end
  end

  def build(http: nil, resolver: public_resolver, secret: self.secret)
    described_class.new(webhook_url: webhook_url, secret: secret, logger: Rubotty::Log.null,
                        http: http, resolver: resolver)
  end

  describe "#post" do
    it "signs the envelope and posts it, coming back as an ok Response" do
      captured = nil
      client = build(http: fake_http { |uri, headers, body| captured = [uri, headers, body] })

      response = client.post(type: "message.created", data: { "body" => "hi" })

      expect(response.status).to eq(200)
      expect(response.ok?).to be(true)
      expect(response.gone?).to be(false)

      uri, headers, body = captured
      expect(uri.to_s).to eq(webhook_url)

      envelope = YAMLCamel.load(body)
      expect(envelope["type"]).to eq("message.created")
      expect(envelope["data"]).to eq({ "body" => "hi" })

      expect(
        Rubotty::ControlPlane::WebhookSignature.verify(
          secret: secret, id: headers["webhook-id"], timestamp: headers["webhook-timestamp"],
          payload: body, header: headers["webhook-signature"]
        )
      ).to be(true)
    end

    it "maps a 410 response to gone? rather than ok?" do
      client = build(http: fake_http(status: 410, body: "already deleted"))

      response = client.post(type: "message.deleted", data: {})

      expect(response.gone?).to be(true)
      expect(response.ok?).to be(false)
    end

    it "maps a 500 response to neither ok? nor gone?" do
      client = build(http: fake_http(status: 500, body: "boom"))

      response = client.post(type: "message.created", data: {})

      expect(response.ok?).to be(false)
      expect(response.gone?).to be(false)
    end

    it "refuses to send when the guard rejects the resolved address, without ever touching the wire" do
      called = false
      client = build(http: fake_http { called = true }, resolver: ->(_host) { ["10.0.0.9"] })

      expect { client.post(type: "message.created", data: {}) }
        .to raise_error(Rubotty::AdapterError) { |e| expect(e.retryable?).to be(true) }
      expect(called).to be(false)
    end

    # No http: injected, so #post drives the real per address loop over
    # Util::MediaFetcher.pinned_http.
    it "fails over to the next resolved address once the first will not connect" do
      dual = ->(_host) { ["93.184.216.34", "93.184.216.35"] }
      attempted = []
      allow(Rubotty::Util::MediaFetcher).to receive(:pinned_http) do |_uri, address, **_opts|
        attempted << address
        connection = instance_double(Net::HTTP)
        if address == "93.184.216.34"
          allow(connection).to receive(:request).and_raise(Net::OpenTimeout, "no route")
        else
          allow(connection).to receive(:request).and_return(Net::HTTPOK.new("1.1", "200", "OK"))
        end
        connection
      end
      client = build(resolver: dual)

      response = client.post(type: "message.created", data: { "body" => "hi" })

      expect(attempted).to eq(["93.184.216.34", "93.184.216.35"])
      expect(response.status).to eq(200)
    end

    it "raises a retryable AdapterError once every resolved address is unreachable" do
      dual = ->(_host) { ["93.184.216.34", "93.184.216.35"] }
      allow(Rubotty::Util::MediaFetcher).to receive(:pinned_http) do
        connection = instance_double(Net::HTTP)
        allow(connection).to receive(:request).and_raise(Net::OpenTimeout, "no route")
        connection
      end
      client = build(resolver: dual)

      expect { client.post(type: "message.created", data: {}) }
        .to raise_error(Rubotty::AdapterError) { |e| expect(e.retryable?).to be(true) }
    end
  end
end
