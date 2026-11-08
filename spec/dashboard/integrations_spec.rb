# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# The admin-only Integrations page: the deployment-wide connection settings
# for an outside service rubotty plugs into, starting with LibreTranslate.
RSpec.describe "Rubotty::Dashboard::App integrations", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: { "DASHBOARD_SECRET" => secret }) }

  def login! = post("/login", secret: secret)

  it "gates the page behind the operator session" do
    get "/integrations"
    expect(last_response.status).to eq(302)
    expect(last_response.headers["location"]).to end_with("/login")
  end

  it "gates saving a connection behind a session, performing no change" do
    expect do
      post "/integrations/libretranslate", url: "https://lt.example"
    end.not_to change { models.integration.count }
    expect(last_response.headers["location"]).to end_with("/login")
  end

  context "when signed in as an operator, not an administrator" do
    let(:operator_session) { dashboard_session(role: "operator", operator_communities: [models.community.first.id]) }

    it "refuses the page with 403" do
      get "/integrations", {}, "rack.session" => operator_session
      expect(last_response.status).to eq(403)
    end
  end

  context "when signed in as an administrator" do
    before { login! }

    it "renders the page with cards for LibreTranslate and OpenArc, not yet configured" do
      get "/integrations"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("Integrations").and include("LibreTranslate")
                                                              .and include("OpenArc")
                                                              .and include("not configured")
    end

    it "saves the LibreTranslate connection" do
      post "/integrations/libretranslate", url: "https://lt.example", api_key: "shh",
                                           allowed_pairs: "en:pt,pt:en"
      follow_redirect!

      row = deps.integrations.find("libretranslate")
      expect(row.url).to eq("https://lt.example")
      expect(row.api_key).to eq("shh")
      expect(row.json_value(:config)["allowed_pairs"]).to eq("en:pt,pt:en")
      expect(last_response.body).to include("Saved the LibreTranslate connection")
    end

    it "shows the connection as connected once a URL is saved" do
      deps.integrations.save(name: "libretranslate", url: "https://lt.example")
      get "/integrations"
      expect(last_response.body).to include("connected")
    end

    it "never renders a stored api key back onto the page" do
      deps.integrations.save(name: "libretranslate", url: "https://lt.example", api_key: "super-secret-value")
      get "/integrations"
      expect(last_response.body).not_to include("super-secret-value")
    end

    it "shows a pill saying a key is stored, without the key itself" do
      deps.integrations.save(name: "libretranslate", url: "https://lt.example", api_key: "super-secret-value")
      get "/integrations"
      expect(last_response.body).to include("key stored")
    end

    it "leaves a stored key untouched when the save submits a blank key box" do
      deps.integrations.save(name: "libretranslate", url: "https://lt.example", api_key: "first-key")
      post "/integrations/libretranslate", url: "https://lt.example", api_key: ""
      expect(deps.integrations.find("libretranslate").api_key).to eq("first-key")
    end

    it "flashes an error and saves nothing for a URL that is not http or https" do
      expect do
        post "/integrations/libretranslate", url: "not a url"
      end.not_to change { models.integration.count }
      follow_redirect!
      expect(last_response.body).to include("http or https")
    end

    describe "testing the connection" do
      it "flashes success and persists nothing when the test succeeds" do
        fake_client = instance_double(Rubotty::Translation::Client, test_connection: [{ "code" => "en" }])
        allow(Rubotty::Translation::Client).to receive(:new).and_return(fake_client)

        expect do
          post "/integrations/libretranslate/test", url: "https://lt.example", api_key: "shh"
        end.not_to change { models.integration.count }
        follow_redirect!

        expect(last_response.body).to include("Connected").and include("1 language")
      end

      it "flashes the failure reason when the test fails" do
        failing_client = instance_double(Rubotty::Translation::Client)
        allow(failing_client).to receive(:test_connection)
          .and_raise(Rubotty::Translation::Client::Error, "LibreTranslate answered HTTP 401")
        allow(Rubotty::Translation::Client).to receive(:new).and_return(failing_client)

        post "/integrations/libretranslate/test", url: "https://lt.example", api_key: "wrong"
        follow_redirect!

        expect(last_response.body).to include("LibreTranslate answered HTTP 401")
      end

      it "falls back to the stored url and key when the test submits them blank" do
        deps.integrations.save(name: "libretranslate", url: "https://stored.example", api_key: "stored-key")
        seen_settings = nil
        allow(Rubotty::Translation::Client).to receive(:new) do |settings:, **|
          seen_settings = settings
          instance_double(Rubotty::Translation::Client, test_connection: [])
        end

        post "/integrations/libretranslate/test", url: "", api_key: ""

        expect(seen_settings.url).to eq("https://stored.example")
        expect(seen_settings.api_key).to eq("stored-key")
      end
    end

    describe "the OpenArc connection" do
      # The page asks the server what it has every time it draws, so almost
      # everything here needs a listing to answer with.
      def stub_models(*ids, status: [])
        allow(Rubotty::OpenArc::Client).to receive(:new)
          .and_return(instance_double(Rubotty::OpenArc::Client, models: ids, test_connection: ids, status: status))
      end

      def stub_unreachable(message = "could not reach OpenArc: Errno::ECONNREFUSED")
        failing = instance_double(Rubotty::OpenArc::Client)
        allow(failing).to receive(:models).and_raise(Rubotty::OpenArc::Client::Error, message)
        allow(failing).to receive(:test_connection).and_raise(Rubotty::OpenArc::Client::Error, message)
        allow(Rubotty::OpenArc::Client).to receive(:new).and_return(failing)
      end

      it "saves the endpoint and key" do
        stub_models
        post "/integrations/openarc", url: "http://openarc.example", api_key: "shh"
        follow_redirect!

        row = deps.integrations.find("openarc")
        expect(row.url).to eq("http://openarc.example")
        expect(row.api_key).to eq("shh")
        expect(last_response.body).to include("Saved the OpenArc connection")
      end

      it "tests the submitted connection without persisting it" do
        stub_models("test-model")

        expect do
          post "/integrations/openarc/test", url: "http://openarc.example", api_key: "shh",
                                             model: "test-model"
        end.not_to change { models.integration.where(name: "openarc").count }
        follow_redirect!

        expect(last_response.body).to include("Connected").and include("test-model")
      end

      it "uses the stored values when the test fields are blank" do
        deps.integrations.save(name: "openarc", url: "http://stored.example", api_key: "stored-key",
                               config: { "model" => "second-test-model" })
        seen_settings = nil
        allow(Rubotty::OpenArc::Client).to receive(:new) do |settings:|
          seen_settings = settings
          instance_double(Rubotty::OpenArc::Client, test_connection: ["second-test-model"], models: ["second-test-model"])
        end

        post "/integrations/openarc/test", url: "", api_key: "", model: ""

        expect(seen_settings.url).to eq("http://stored.example")
        expect(seen_settings.api_key).to eq("stored-key")
        expect(seen_settings.model).to eq("second-test-model")
      end

      # A URL in the field says somebody typed one, not that anything is
      # listening. Reading "connected" off a stored URL is what let a server
      # with no worker loaded sit here looking healthy while every feature
      # that depends on it failed.
      describe "whether the endpoint answers" do
        it "says it is answering when the listing came back" do
          deps.integrations.save(name: "openarc", url: "http://openarc.example")
          stub_models("test-model")

          get "/integrations"

          expect(last_response.body).to include("answering")
          expect(last_response.body).not_to include("not answering")
        end

        it "says it is not answering, with the reason, when the endpoint refused" do
          deps.integrations.save(name: "openarc", url: "http://openarc.example")
          stub_unreachable("OpenArc answered HTTP 503: no worker is available")

          get "/integrations"

          expect(last_response.body).to include("not answering").and include("no worker is available")
        end

        it "leaves a connection with no URL saved reading as not configured" do
          get "/integrations"

          expect(last_response.body).to include("not configured")
          expect(last_response.body).not_to include("answering")
        end
      end

      describe "choosing the model" do
        it "offers what the configured server reports it has loaded" do
          deps.integrations.save(name: "openarc", url: "http://openarc.example")
          stub_models("test-model", "second-test-model")

          get "/integrations"

          expect(last_response.body).to include("test-model").and include("second-test-model")
        end

        it "stores the chosen model beside the url and the key" do
          stub_models("test-model", "second-test-model")

          post "/integrations/openarc", url: "http://openarc.example", model: "second-test-model"

          expect(deps.integrations.find("openarc").json_value(:config)["model"]).to eq("second-test-model")
        end

        it "reads a blank choice as the built-in default rather than as a blank model" do
          stub_models("test-model")
          deps.integrations.save(name: "openarc", url: "http://openarc.example",
                                 config: { "model" => "second-test-model" })

          post "/integrations/openarc", url: "http://openarc.example", model: ""

          expect(deps.integrations.find("openarc").json_value(:config)["model"]).to be_nil
        end

        # The whole point of the issue: a model that has gone has to be said
        # here, rather than turning up as a failed summary hours later.
        it "says plainly when the stored model is no longer on the server" do
          deps.integrations.save(name: "openarc", url: "http://openarc.example",
                                 config: { "model" => "second-test-model" })
          stub_models("test-model")

          get "/integrations"

          expect(last_response.body).to include("The stored model is not loaded on this server")
          expect(last_response.body).to include("second-test-model")
        end

        it "says nothing of the kind while the stored model is still there" do
          deps.integrations.save(name: "openarc", url: "http://openarc.example",
                                 config: { "model" => "test-model" })
          stub_models("test-model")

          get "/integrations"

          expect(last_response.body).not_to include("The stored model is not loaded on this server")
        end

        # An unreachable server proves nothing about the stored model, so the
        # page names the reason instead of claiming the model has gone.
        it "names why the list is missing rather than claiming the model has gone" do
          deps.integrations.save(name: "openarc", url: "http://openarc.example",
                                 config: { "model" => "second-test-model" })
          stub_unreachable

          get "/integrations"

          expect(last_response.status).to eq(200)
          expect(last_response.body).to include("Could not read this server's model list")
          expect(last_response.body).not_to include("The stored model is not loaded on this server")
        end

        it "still draws the page with no connection saved at all" do
          get "/integrations"

          expect(last_response.status).to eq(200)
          expect(last_response.body).to include("Save an endpoint URL first")
        end

        it "warns on a test when the server does not carry the chosen model" do
          stub_models("test-model")

          post "/integrations/openarc/test", url: "http://openarc.example", model: "second-test-model"
          follow_redirect!

          expect(last_response.body).to include("second-test-model is not loaded")
        end

        it "calls a server with nothing loaded a failure rather than a pass" do
          stub_models

          post "/integrations/openarc/test", url: "http://openarc.example"
          follow_redirect!

          expect(last_response.body).to include("no models loaded")
        end
      end

      describe "loading a model onto the server" do
        it "shows what openarc/status reports beyond the bare model list" do
          deps.integrations.save(name: "openarc", url: "http://openarc.example")
          stub_models("test-model",
                     status: [{ "model_name" => "test-model", "model_type" => "llm",
                                "engine" => "openvino", "device" => "CPU" }])

          get "/integrations"

          expect(last_response.body).to include("test-model").and include("openvino").and include("CPU")
        end

        it "names why the loaded list is missing rather than showing nothing" do
          deps.integrations.save(name: "openarc", url: "http://openarc.example")
          fake = instance_double(Rubotty::OpenArc::Client, models: ["test-model"], test_connection: ["test-model"])
          allow(fake).to receive(:status).and_raise(Rubotty::OpenArc::Client::Error, "OpenArc answered HTTP 404")
          allow(Rubotty::OpenArc::Client).to receive(:new).and_return(fake)

          get "/integrations"

          expect(last_response.body).to include("Could not read what is loaded").and include("HTTP 404")
        end

        it "does not offer the load form until a connection is saved" do
          get "/integrations"

          expect(last_response.body).to include("Save an endpoint URL above first")
        end

        it "loads a model with the fields submitted" do
          deps.integrations.save(name: "openarc", url: "http://openarc.example")
          seen = nil
          double = instance_double(Rubotty::OpenArc::Client, models: [], test_connection: [], status: [])
          allow(double).to receive(:load_model) do |**kwargs|
            seen = kwargs
            "loaded"
          end
          allow(Rubotty::OpenArc::Client).to receive(:new).and_return(double)

          post "/integrations/openarc/load", model_path: "/models/test-model", model_name: "test-model",
                                             model_type: "llm", engine: "openvino", device: "CPU",
                                             cache_dir: "/cache"
          follow_redirect!

          expect(seen).to eq(model_path: "/models/test-model", model_name: "test-model", model_type: "llm",
                             engine: "openvino", device: "CPU", cache_dir: "/cache")
          expect(last_response.body).to include("Loaded test-model onto the OpenArc server")
        end

        it "passes a blank cache directory through as nil rather than an empty string" do
          deps.integrations.save(name: "openarc", url: "http://openarc.example")
          seen = nil
          double = instance_double(Rubotty::OpenArc::Client)
          allow(double).to receive(:load_model) do |**kwargs|
            seen = kwargs
            "loaded"
          end
          allow(Rubotty::OpenArc::Client).to receive(:new).and_return(double)

          post "/integrations/openarc/load", model_path: "/models/test-model", model_name: "test-model",
                                             model_type: "llm", engine: "openvino", device: "CPU",
                                             cache_dir: ""

          expect(seen[:cache_dir]).to be_nil
        end

        it "flashes the client's own error rather than a silent failure" do
          deps.integrations.save(name: "openarc", url: "http://openarc.example")
          double = instance_double(Rubotty::OpenArc::Client, models: [], test_connection: [], status: [])
          allow(double).to receive(:load_model)
            .and_raise(Rubotty::OpenArc::Client::Error, "model_type has to be one of: llm, vlm")
          allow(Rubotty::OpenArc::Client).to receive(:new).and_return(double)

          post "/integrations/openarc/load", model_path: "/models/x", model_name: "x",
                                             model_type: "bogus", engine: "openvino", device: "CPU"
          follow_redirect!

          expect(last_response.body).to include("model_type has to be one of")
        end

        it "refuses to load without a saved connection rather than guessing at one" do
          post "/integrations/openarc/load", model_path: "/models/x", model_name: "x",
                                             model_type: "llm", engine: "openvino", device: "CPU"
          follow_redirect!

          expect(last_response.body).to include("save the OpenArc connection first")
        end

        # The recipe is only worth keeping once the load it describes has
        # worked, so it is written after the call rather than beside it.
        it "keeps the fields of a load that worked" do
          deps.integrations.save(name: "openarc", url: "http://openarc.example",
                                 config: { "model" => "test-model" })
          double = instance_double(Rubotty::OpenArc::Client, models: [], test_connection: [], status: [])
          allow(double).to receive(:load_model).and_return("loaded")
          allow(Rubotty::OpenArc::Client).to receive(:new).and_return(double)

          post "/integrations/openarc/load", model_path: "/models/test-model", model_name: "test-model",
                                             model_type: "llm", engine: "openvino", device: "CPU",
                                             cache_dir: ""
          follow_redirect!

          config = deps.integrations.find("openarc").json_value(:config)
          expect(config["reload"]).to eq("model_path" => "/models/test-model", "model_name" => "test-model",
                                         "model_type" => "llm", "engine" => "openvino", "device" => "CPU")
          expect(config["model"]).to eq("test-model")
          expect(last_response.body).to include("goes back by itself")
        end

        # A load nobody has chosen is still written down, and is inert until
        # the model it names is the one completions ask for.
        it "keeps nothing at all when the load itself failed" do
          deps.integrations.save(name: "openarc", url: "http://openarc.example")
          double = instance_double(Rubotty::OpenArc::Client, models: [], test_connection: [], status: [])
          allow(double).to receive(:load_model)
            .and_raise(Rubotty::OpenArc::Client::Error, "device GPU.9 is not on this server")
          allow(Rubotty::OpenArc::Client).to receive(:new).and_return(double)

          post "/integrations/openarc/load", model_path: "/models/test-model", model_name: "test-model",
                                             model_type: "llm", engine: "openvino", device: "GPU.9"

          expect(deps.integrations.find("openarc").json_value(:config)["reload"]).to be_nil
        end

        it "forgets the recipe without disturbing the chosen model" do
          deps.integrations.save(name: "openarc", url: "http://openarc.example",
                                 config: { "model" => "test-model", "reload" => { "model_name" => "test-model" } })

          post "/integrations/openarc/forget"
          follow_redirect!

          config = deps.integrations.find("openarc").json_value(:config)
          expect(config).not_to have_key("reload")
          expect(config["model"]).to eq("test-model")
          expect(last_response.body).to include("no longer put a model back")
        end

        # Save writes the whole config hash, so the recipe and the chosen model
        # would flatten each other if either write forgot the other was there.
        it "keeps the recipe when the connection itself is saved again" do
          deps.integrations.save(name: "openarc", url: "http://openarc.example",
                                 config: { "model" => "test-model", "reload" => { "model_name" => "test-model" } })

          post "/integrations/openarc", url: "http://openarc.example:8010", model: "other-test-model"

          config = deps.integrations.find("openarc").json_value(:config)
          expect(config["reload"]).to eq("model_name" => "test-model")
          expect(config["model"]).to eq("other-test-model")
        end
      end
    end

    it "reaches the page from the top navigation" do
      get "/"
      expect(last_response.body).to include("/integrations")
    end
  end
end
