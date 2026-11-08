# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::ControlPlane::WebhookPump, "response bounds" do
  let(:pump) { described_class.new(webhooks: nil, models: nil) }

  it "stops reading at the diagnostic budget instead of buffering the complete body" do
    chunks_read = 0
    response = double("subscriber response", code: "503")
    allow(response).to receive(:read_body) do |&consume|
      10_000.times do
        chunks_read += 1
        consume.call("x" * 1000)
      end
    end
    http = double("pinned HTTP connection")
    allow(http).to receive(:request) { |_request, &receive| receive.call(response) }

    result = pump.send(:read_response, http, Net::HTTP::Post.new("/hook"))

    expect(result.code).to eq("503")
    expect(result.body.bytesize).to eq(described_class::MAX_RESPONSE)
    expect(chunks_read).to eq(2)
  end

  it "bounds the whole response even when every small chunk arrives within the read timeout" do
    stub_const("#{described_class}::REQUEST_TIMEOUT", 0.05)
    response = double("slow subscriber response", code: "503")
    allow(response).to receive(:read_body) do |&consume|
      loop do
        sleep 0.02
        consume.call("x")
      end
    end
    http = double("pinned HTTP connection")
    allow(http).to receive(:request) { |_request, &receive| receive.call(response) }

    expect { pump.send(:read_response, http, Net::HTTP::Post.new("/hook")) }.to raise_error(Timeout::Error)
  end

  it "includes address resolution in the overall delivery deadline" do
    stub_const("#{described_class}::REQUEST_TIMEOUT", 0.05)
    slow = described_class.new(webhooks: nil, models: nil, resolver: lambda { |_host|
      sleep 1
      ["93.184.216.34"]
    })
    subscription = Struct.new(:url).new("https://subscriber.example/hook")

    result = slow.send(:post, subscription, nil, now: Time.now)

    expect(result[:status]).to be_nil
    expect(result[:error]).to include("Timeout")
  end
end
