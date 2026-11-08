# frozen_string_literal: true

require "spec_helper"

# "backfill" is a declaration only, so the CLI and dashboard can configure it. The
# paced resync itself runs as a boot sweep in Core::Backfill.
RSpec.describe Rubotty::Features::Backfill do
  it "is on by default, because losing what was in flight is unrecoverable and silent" do
    expect(described_class.default_enabled?).to be(true)
  end

  it "says in its description what turning it off costs" do
    expect(described_class.description).to match(/silently loses/)
  end

  it "declares the stable feature key used in feature_settings" do
    expect(described_class.feature_name).to eq("backfill")
  end

  it "is registered in the catalog so the admin CLI recognises and resolves it" do
    expect(Rubotty::Features::Catalog.known?("backfill")).to be(true)
    expect(Rubotty::Features::Catalog.class_for("backfill")).to eq(described_class)
  end

  it "exposes a config schema so the window and pace are validated and editable" do
    expect(described_class.config_schema).to be_a(Rubotty::Config::Schema)
  end

  # The schema is what an operator edits and DEFAULTS is what the sweep runs on,
  # so a key that disagrees between them lies to whoever set it.
  it "declares the same default the sweep actually uses, for every key it offers" do
    described_class.config_schema.fields.each do |name, field|
      expect(field.default).to eq(Rubotty::Core::Backfill::DEFAULTS[name]), "#{name} disagrees with DEFAULTS"
    end
  end

  # A key present in DEFAULTS and missing from the schema passes the check
  # above silently, since it never walks DEFAULTS at all. This is the other
  # half: nothing the sweep reads may go undeclared to the operator.
  it "offers every key the sweep actually reads" do
    missing = Rubotty::Core::Backfill::DEFAULTS.keys - described_class.config_schema.fields.keys

    expect(missing).to be_empty, "#{missing.inspect} can never be seen or changed on the dashboard"
  end

  it "lets a community decide how big a gap may be restored without asking" do
    field = described_class.config_schema.fields[:auto_relay_limit]

    expect(field.type).to eq(:integer)
    expect(field.default).to eq(Rubotty::ControlPlane::BackfillProposals::AUTO_RELAY_LIMIT)
  end

  # Turning the limit down is what starts previews being kept, so the page where
  # it is set says so.
  it "says on the dashboard what a proposal keeps while it waits" do
    expect(described_class.retention_notice).to include("preview")
    expect(described_class.retention_notice).to include("auto_relay_limit")
  end
end
