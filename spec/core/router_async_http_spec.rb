# frozen_string_literal: true

require "spec_helper"

# async_http records the call rather than making it. The hop counter is bounded
# because a callback can call async_http again, so two scripts naming each other
# would otherwise loop for as long as the endpoints answer.
RSpec.describe Rubotty::Core::Router, "async_http", :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:endpoints) { Rubotty::Scripting::Endpoints.new(models: models, logger: Rubotty::Log.null) }
  let(:scripts) { Rubotty::ControlPlane::Scripts.new(models: models, logger: Rubotty::Log.null) }
  let(:store) { Rubotty::ControlPlane::ScriptEndpoints.new(models: models) }
  let(:requests) { [] }

  before do
    store.save(community: community, name: "weather", url: "https://api.example.com/w",
               http_method: "GET")
    store.save(community: community, name: "poster", url: "https://api.example.com/p",
               http_method: "POST")
    scripts.save(community: community, name: "handler", kind: "callback",
                 source: "return nil", trigger_type: "always")
  end

  def handler(generation: 0)
    described_class.allocate.send(:script_async_http_handler, community, scripts, endpoints,
                                  { generation: generation, requests: requests })
  end

  def refusal(answer) = answer.is_a?(Rubotty::Scripting::Answer) ? answer.values.last : nil

  it "records the call rather than making it" do
    expect(handler.call({ "endpoint" => "weather" })).to be(true)
    expect(requests.first["endpoint"]).to eq("weather")
  end

  it "counts the hop, so what it books knows how deep it already is" do
    handler(generation: 1).call({ "endpoint" => "weather" })

    expect(requests.first["generation"]).to eq(2)
  end

  it "stops a chain once it has gone as far as it may" do
    answer = handler(generation: Rubotty::Core::Router::MAX_GENERATIONS).call({ "endpoint" => "weather" })

    expect(refusal(answer)).to include("stops after")
    expect(requests).to be_empty
  end

  it "refuses an endpoint this community does not have" do
    expect(refusal(handler.call({ "endpoint" => "nowhere" }))).to include("no endpoint called nowhere")
  end

  it "refuses a call that names no endpoint at all" do
    expect(refusal(handler.call({}))).to include("needs an endpoint")
  end

  it "refuses a body against an endpoint that only ever gets" do
    answer = handler.call({ "endpoint" => "weather", "body" => "hello" })

    expect(refusal(answer)).to include("takes no body")
  end

  it "takes a body for one that posts" do
    expect(handler.call({ "endpoint" => "poster", "body" => "hello" })).to be(true)
  end

  # The callback is resolved at booking time, so a typo refuses now.
  it "refuses a callback naming a script that is not there" do
    answer = handler.call({ "endpoint" => "weather", "then_call" => "missing" })

    expect(refusal(answer)).to include("no script called missing")
  end

  it "books a callback that does exist, with the data it should be woken with" do
    handler.call({ "endpoint" => "weather", "then_call" => "handler", "data" => { "town" => "Lisbon" } })

    expect(requests.first["then_call"]).to eq("handler")
    expect(requests.first["data"]).to eq("town" => "Lisbon")
  end

  it "is absent entirely without an endpoint store, rather than failing later" do
    absent = described_class.allocate.send(:script_async_http_handler, community, scripts, nil,
                                           { generation: 0, requests: requests })

    expect(absent).to be_nil
  end
end
