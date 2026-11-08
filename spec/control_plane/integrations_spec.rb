# frozen_string_literal: true

require "spec_helper"

# What the dashboard's Integrations page drives to configure a deployment-wide
# connection to an outside service, and the seam that adapts a stored row
# into what Translation::Settings reads.
RSpec.describe Rubotty::ControlPlane::Integrations, :control_plane do
  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:now) { Time.now }

  # A plain reference to the outer class, not `described_class`: the nested
  # LibreTranslateSettings examples below change what `described_class` means,
  # and this is used from inside that nesting too.
  subject(:integrations) { Rubotty::ControlPlane::Integrations.new(models: models, clock: -> { now }) }

  describe "deployment-managed credentials" do
    it "uses a deployment secret ahead of the recoverable legacy database key" do
      %w[openarc libretranslate].each do |name|
        variable = "RUBOTTY_#{name.upcase}_API_KEY"
        service = described_class.new(models: models, env: { variable => "deployment-secret" })
        service.save(name: name, api_key: "legacy-secret")
        expect(service.api_key_for(name)).to eq("deployment-secret")
        expect(service.find(name).api_key).to eq("legacy-secret")
      end
    end

    it "retains the legacy key until a nonblank replacement is configured" do
      service = described_class.new(models: models, env: { "RUBOTTY_OPENARC_API_KEY" => "  " })
      service.save(name: "openarc", api_key: "legacy-secret")
      expect(service.api_key_for("openarc")).to eq("legacy-secret")
    end
  end

  describe "#find" do
    it "is nil for an integration that has never been saved" do
      expect(integrations.find("libretranslate")).to be_nil
    end
  end

  describe "#list" do
    it "returns one entry per known integration even when none are configured" do
      expect(integrations.list.map(&:name)).to eq(described_class::KNOWN)
      expect(integrations.list.map(&:id)).to all(be_nil)
    end

    it "returns the stored row where one has been saved, alongside unsaved placeholders" do
      integrations.save(name: "libretranslate", url: "https://lt.example")
      row = integrations.list.find { |entry| entry.name == "libretranslate" }
      expect(row.id).not_to be_nil
      expect(row.url).to eq("https://lt.example")
    end
  end

  describe "#save" do
    it "rejects an unknown integration name" do
      expect { integrations.save(name: "bogus", url: "https://x.example") }
        .to raise_error(described_class::Invalid, /not a known integration/)
    end

    it "creates a row with a URL, an api key and config" do
      row = integrations.save(
        name: "libretranslate", url: "https://lt.example", api_key: "shh",
        config: { "allowed_pairs" => "en:pt,pt:en" }
      )
      expect(row.name).to eq("libretranslate")
      expect(row.url).to eq("https://lt.example")
      expect(row.api_key).to eq("shh")
      expect(row.json_value(:config)).to eq("allowed_pairs" => "en:pt,pt:en")
    end

    it "rejects a URL that is not http or https" do
      expect { integrations.save(name: "libretranslate", url: "not a url") }
        .to raise_error(described_class::Invalid, /http or https/)
    end

    it "accepts a blank URL, meaning not yet configured" do
      row = integrations.save(name: "libretranslate", url: "")
      expect(row.url).to be_nil
    end

    it "updates an existing row rather than creating a second one" do
      integrations.save(name: "libretranslate", url: "https://lt.example")
      integrations.save(name: "libretranslate", url: "https://lt2.example")

      expect(models.integration.where(name: "libretranslate").count).to eq(1)
      expect(integrations.find("libretranslate").url).to eq("https://lt2.example")
    end

    it "leaves a stored api key untouched when the new value is blank, like a password field" do
      integrations.save(name: "libretranslate", url: "https://lt.example", api_key: "first-key")
      integrations.save(name: "libretranslate", url: "https://lt.example", api_key: "")

      expect(integrations.find("libretranslate").api_key).to eq("first-key")
    end

    it "leaves a stored api key untouched when api_key is nil" do
      integrations.save(name: "libretranslate", url: "https://lt.example", api_key: "first-key")
      integrations.save(name: "libretranslate", url: "https://lt.example", api_key: nil)

      expect(integrations.find("libretranslate").api_key).to eq("first-key")
    end

    it "replaces a stored api key with a new non-blank value" do
      integrations.save(name: "libretranslate", url: "https://lt.example", api_key: "first-key")
      integrations.save(name: "libretranslate", url: "https://lt.example", api_key: "second-key")

      expect(integrations.find("libretranslate").api_key).to eq("second-key")
    end

    it "stamps updated_at on every save" do
      integrations.save(name: "libretranslate", url: "https://lt.example")
      later = now + 3600
      described_class.new(models: models, clock: -> { later })
                     .save(name: "libretranslate", url: "https://lt2.example")

      expect(integrations.find("libretranslate").updated_at).to be_within(1).of(later)
    end
  end

  describe "#configured?" do
    it "is false with no row at all" do
      expect(integrations.configured?("libretranslate")).to be(false)
    end

    it "is false for a row with a blank URL" do
      integrations.save(name: "libretranslate", url: "")
      expect(integrations.configured?("libretranslate")).to be(false)
    end

    it "is true once a URL is set" do
      integrations.save(name: "libretranslate", url: "https://lt.example")
      expect(integrations.configured?("libretranslate")).to be(true)
    end
  end

  describe described_class::LibreTranslateSettings do
    subject(:store) { described_class.new(integrations) }

    it "answers nil for url, api_key and allowed_pairs with no row saved" do
      expect(store.url).to be_nil
      expect(store.api_key).to be_nil
      expect(store.allowed_pairs).to be_nil
    end

    it "reads the stored url and api key straight through" do
      integrations.save(name: "libretranslate", url: "https://lt.example", api_key: "shh")

      expect(store.url).to eq("https://lt.example")
      expect(store.api_key).to eq("shh")
    end

    it "parses the stored allowed_pairs text into pairs" do
      integrations.save(name: "libretranslate", url: "https://lt.example",
                        config: { "allowed_pairs" => "en:pt, pt:en" })

      expect(store.allowed_pairs).to eq([%w[en pt], %w[pt en]])
    end

    it "drives a real Translation::Settings, winning over the environment" do
      integrations.save(name: "libretranslate", url: "https://lt.example", api_key: "shh")
      settings = Rubotty::Translation::Settings.new(
        env: { Rubotty::Translation::Settings::URL_VAR => "http://env.example" }, store: store
      )

      expect(settings.url).to eq("https://lt.example")
      expect(settings.api_key).to eq("shh")
      expect(settings).to be_configured
    end
  end

  describe described_class::OpenArcSettings do
    subject(:store) { described_class.new(integrations) }

    it "answers nil until the deployment-wide connection is saved" do
      expect(store.url).to be_nil
      expect(store.api_key).to be_nil
      expect(store.model).to be_nil
      expect(store.reload_spec).to be_nil
    end

    it "carries the reload recipe stored beside the chosen model" do
      recipe = { "model_path" => "/models/Qwen3-14B", "model_name" => "Qwen3-14B",
                 "model_type" => "llm", "engine" => "ovgenai", "device" => "GPU" }
      integrations.save(name: "openarc", url: "http://openarc.example",
                        config: { "model" => "Qwen3-14B", "reload" => recipe })
      settings = Rubotty::OpenArc::Settings.new(store: store)

      expect(store.reload_spec).to eq(recipe)
      expect(settings.reload_spec).to eq(recipe)
      expect(settings).to be_reloadable
    end

    # A recipe kept for a model nobody asks for any more is left where it is
    # and simply never acted on, so changing the model cannot load the old one.
    it "will not act on a recipe naming a model that is no longer chosen" do
      integrations.save(name: "openarc", url: "http://openarc.example",
                        config: { "model" => "Ministral-8B",
                                  "reload" => { "model_path" => "/models/Qwen3-14B", "model_name" => "Qwen3-14B",
                                                "model_type" => "llm", "engine" => "ovgenai", "device" => "GPU" } })
      settings = Rubotty::OpenArc::Settings.new(store: store)

      expect(settings.reload_spec).to be_nil
      expect(settings).not_to be_reloadable
      expect(settings.stored_reload_spec["model_name"]).to eq("Qwen3-14B")
    end

    it "drives the settings from the stored connection" do
      integrations.save(name: "openarc", url: "http://openarc.example", api_key: "shh")
      settings = Rubotty::OpenArc::Settings.new(store: store)

      expect(settings.url).to eq("http://openarc.example")
      expect(settings.api_key).to eq("shh")
      expect(settings).to be_configured
    end

    # The connection was saved with a pinned model long before one could be
    # chosen, so a row with nothing in config has to keep running.
    it "falls back to the built-in model until one is chosen" do
      integrations.save(name: "openarc", url: "http://openarc.example")
      settings = Rubotty::OpenArc::Settings.new(store: store)

      expect(settings.model).to eq(Rubotty::OpenArc::Settings::DEFAULT_MODEL)
      expect(settings.model_chosen?).to be(false)
    end

    it "carries a chosen model, so it can be rotated without a restart" do
      integrations.save(name: "openarc", url: "http://openarc.example", config: { "model" => "Ministral-8B" })
      settings = Rubotty::OpenArc::Settings.new(store: store)

      expect(store.model).to eq("Ministral-8B")
      expect(settings.model).to eq("Ministral-8B")
      expect(settings.model_chosen?).to be(true)
    end

    it "reads a cleared model as no choice rather than as a blank model" do
      integrations.save(name: "openarc", url: "http://openarc.example", config: { "model" => "Ministral-8B" })
      integrations.save(name: "openarc", url: "http://openarc.example", config: { "model" => nil })
      settings = Rubotty::OpenArc::Settings.new(store: store)

      expect(settings.model).to eq(Rubotty::OpenArc::Settings::DEFAULT_MODEL)
      expect(settings.model_chosen?).to be(false)
    end
  end
end
