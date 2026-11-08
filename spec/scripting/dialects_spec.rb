# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# The languages an operator may write in. A dialect is described once in the registry,
# so nothing downstream keeps its own list.
RSpec.describe Rubotty::Scripting::Dialects do
  # Rocks land under the luarocks tree, and a deployment once had every transpiler
  # installed and offered none because the editor process never looked there. Which
  # directory it is depends on how luarocks was configured, so it is asked.
  describe "where it looks for a transpiler" do
    before { described_class.reset_search_paths! }

    after { described_class.reset_search_paths! }

    it "searches PATH" do
      expect(described_class.search_paths).to include(*described_class.path_entries)
    end

    it "also searches wherever luarocks says it installs executables" do
      allow(described_class).to receive(:luarocks_bin_dir).and_return("/opt/rocks/bin")

      expect(described_class.search_paths).to include("/opt/rocks/bin")
    end

    it "carries on with PATH alone when there is no luarocks to ask" do
      allow(described_class).to receive(:luarocks_bin_dir).and_return(nil)

      expect(described_class.search_paths).to eq(described_class.path_entries)
    end

    it "finds a transpiler that is only in the luarocks directory" do
      allow(described_class).to receive(:luarocks_bin_dir).and_return("/opt/rocks/bin")
      allow(File).to receive(:executable?).and_return(false)
      allow(File).to receive(:executable?).with("/opt/rocks/bin/moonc").and_return(true)

      expect(described_class.installed?("moonc")).to be(true)
    end
  end

  it "always knows Lua, and needs no transpiler for it" do
    expect(described_class.find("lua").native?).to be(true)
    expect(described_class.available_names).to include("lua")
  end

  it "gives every dialect its own extension, so examples can share a name" do
    extensions = described_class::ALL.map(&:extension)

    expect(extensions.uniq.length).to eq(extensions.length)
  end

  it "reads a trigger header using that dialect's own comment marker" do
    fennel = described_class.find("fennel")
    lua = described_class.find("lua")

    expect(";; trigger: contains"[fennel.trigger_pattern, 1]).to eq("contains")
    expect("-- trigger: contains"[lua.trigger_pattern, 1]).to eq("contains")
    expect(";; trigger: contains"[lua.trigger_pattern, 1]).to be_nil
  end

  it "refuses a language it does not know rather than guessing" do
    expect { described_class.find!("python") }
      .to raise_error(Rubotty::Scripting::Error, /not a language rubotty knows/)
  end

  # A deployment missing a transpiler should offer fewer dialects. MoonScript used to
  # be offered everywhere and fail at save.
  describe "what this deployment can actually compile" do
    it "leaves out a dialect whose transpiler is missing" do
      allow(described_class).to receive(:installed?) { |binary| binary.nil? }

      expect(described_class.available_names).to eq(["lua"])
      expect(described_class.available?("moonscript")).to be(false)
    end

    it "counts a dialect as available once its transpiler is on PATH" do
      allow(described_class).to receive(:installed?).and_return(true)

      expect(described_class.available_names).to eq(described_class.names)
    end

    # The registry is a closed list, so an unknown name is nothing at all.
    it "carries no dialect it was not given" do
      expect(described_class.find("something-else")).to be_nil
    end
  end

  # Teal used to answer here, because no tagged release ran on Lua 5.5. It is
  # built from source now and works there, so nothing has a known cause left.
  describe "why a dialect is missing" do
    after { described_class.reset_versions! }

    it "says nothing for Teal on a Lua 5.5 runtime" do
      allow(described_class).to receive(:lua_runtime).and_return("Lua 5.5.0  Copyright (C) 1994-2025 Lua.org, PUC-Rio")

      expect(described_class.unavailable_reason(described_class.find("teal"))).to be_nil
    end

    it "says nothing for a dialect other than Teal" do
      allow(described_class).to receive(:lua_runtime).and_return("Lua 5.5.0")

      expect(described_class.unavailable_reason(described_class.find("moonscript"))).to be_nil
    end
  end
end
