# frozen_string_literal: true

require "spec_helper"
require "yamlcamel"

RSpec.describe "shared container image contract" do
  root = File.expand_path("../..", __dir__)
  let(:compose) { YAMLCamel.load_file(File.join(root, "deploy/shared-image.compose.yml")) }

  it "runs two independent commands from one image with no source build" do
    services = compose.fetch("services")
    expect(services.keys).to eq(%w[rubotty rubotty-web])
    expect(services.values.map { |service| service.fetch("image") }.uniq)
      .to eq(["${RUBOTTY_IMAGE:?Set the verified ghcr.io repository@sha256 digest}"])
    expect(services.values).not_to include(have_key("build"))
    expect(services.fetch("rubotty").fetch("command")).to eq(%w[bundle exec bin/rubotty run])
    expect(services.fetch("rubotty-web").fetch("command")).to eq(%w[bundle exec bin/rubotty web])
  end
end
