# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Core::PuppetStatusSweep, :control_plane do
  def fake_adapter(snapshot)
    Class.new do
      define_method(:puppet_snapshot) { snapshot }
    end.new
  end

  it "writes a resolved endpoint's status and check time onto the channel it names" do
    _db, models = seeded_sample
    checked_at = Time.utc(2026, 8, 25, 12)
    sweep = described_class.new(models: models, clock: -> { checked_at })

    sweep.run("discord" => fake_adapter("dc-general" => :active))

    row = models.channel.where(endpoint_key: "dc-general").first
    expect(row.puppet_status).to eq("active")
    expect(row.puppet_checked_at).to eq(checked_at)
  end

  it "records a degraded endpoint the same way" do
    _db, models = seeded_sample
    sweep = described_class.new(models: models)

    sweep.run("discord" => fake_adapter("dc-general" => :degraded))

    expect(models.channel.where(endpoint_key: "dc-general").first.puppet_status).to eq("degraded")
  end

  it "leaves a channel untouched when nothing has resolved it yet" do
    _db, models = seeded_sample
    sweep = described_class.new(models: models)

    sweep.run("discord" => fake_adapter({}))

    expect(models.channel.where(endpoint_key: "dc-general").first.puppet_status).to be_nil
  end

  it "ignores an adapter with no puppet_snapshot method, such as Telegram's" do
    _db, models = seeded_sample
    sweep = described_class.new(models: models)

    expect { sweep.run("telegram" => Object.new) }.not_to raise_error
  end

  it "does not raise when a snapshot names an endpoint no channel row matches" do
    _db, models = seeded_sample
    sweep = described_class.new(models: models)

    expect { sweep.run("discord" => fake_adapter("nowhere" => :active)) }.not_to raise_error
  end

  it "keeps sweeping the rest when one adapter's own snapshot raises" do
    _db, models = seeded_sample
    logger = instance_double(Logger, warn: nil)
    broken = Class.new { define_method(:puppet_snapshot) { raise "boom" } }.new
    sweep = described_class.new(models: models, logger: logger)

    sweep.run("broken" => broken, "discord" => fake_adapter("dc-general" => :active))

    expect(models.channel.where(endpoint_key: "dc-general").first.puppet_status).to eq("active")
    expect(logger).to have_received(:warn)
  end

  it "runs with no adapters at all" do
    _db, models = seeded_sample
    sweep = described_class.new(models: models)

    expect { sweep.run({}) }.not_to raise_error
    expect { sweep.run(nil) }.not_to raise_error
  end
end
