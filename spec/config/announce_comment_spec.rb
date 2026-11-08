# frozen_string_literal: true

require "spec_helper"
require "yamlcamel"

# A realistic config's announce block once argued for one detail level in its
# comment and set the other, which nothing caught because a comment is not
# loaded. These read both halves and hold them to each other.
RSpec.describe "the announce block in the control-plane fixture config" do
  let(:path) { File.expand_path("../fixtures/control_plane/sample.config.yaml", __dir__) }
  let(:text) { File.read(path, encoding: "UTF-8") }
  let(:announce) { YAMLCamel.load(text)["announce"] }

  # The comment block's "detail: <level>" lines, which document what the setting
  # takes.
  let(:documented) { text.scan(/^#\s*detail:\s*(\w+)/).flatten.uniq }

  # Read off the schema, so adding a level without documenting it fails here.
  let(:allowed) do
    Rubotty::Config::Definition.send(:announce_schema).fields[:detail].one_of.map(&:to_s)
  end

  it "documents exactly the levels the schema accepts" do
    expect(documented.sort).to eq(allowed.sort)
  end

  it "sets a level the schema accepts" do
    expect(allowed).to include(announce["detail"])
  end

  it "does not argue for a level other than the one it sets" do
    chosen = announce["detail"]
    block = text[/^announce:.*?(?=\n[a-z_]+:|\z)/m]

    expect(block).to include("detail: #{chosen}")
    expect(block).not_to match(/only safe choice/)
  end
end
