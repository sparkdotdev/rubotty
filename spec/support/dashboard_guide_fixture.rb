# frozen_string_literal: true

require "tmpdir"
require "fileutils"

module DashboardGuideFixture
  # This is rendering input, independent of optional documentation in a private
  # checkout. It exercises tables, headings, Unicode and adjacent code fences.
  def dashboard_guide_markdown
    functions = Rubotty::Scripting::HostFunctions::CATALOG.each_key.map do |name|
      "| `#{name}` | A host function entry. |"
    end.join("\n")
    <<~MARKDOWN
      # Scripting reference

      ## What wakes a script

      A message can wake a script. Café and Köln are UTF-8 text.
      Use `remember` for state and `async_http` to reach a website.

      | Function | Description |
      | --- | --- |
      #{functions}

      ### Message hook

      ```lua
      return { action = "allow" }
      ```

      ### State

      ```lua
      local remembered = "value"
      return remembered
      ```

      ### Configuration

      ```yaml
      enabled: true
      ```
    MARKDOWN
  end

  def with_dashboard_guide_fixture(present: true)
    renderer = Rubotty::Dashboard::ReadmeRenderer
    Dir.mktmpdir("dashboard-guide") do |dir|
      path, source = write_dashboard_guide_fixture(dir, present: present)
      yield path, source
    ensure
      renderer.reset!
    end
  end

  def install_dashboard_guide_fixture(present: true)
    @dashboard_guide_directories ||= []
    dir = Dir.mktmpdir("dashboard-guide")
    @dashboard_guide_directories << dir
    write_dashboard_guide_fixture(dir, present: present)
  end

  def remove_dashboard_guide_fixtures
    Array(@dashboard_guide_directories).each { |dir| FileUtils.remove_entry(dir) }
    Rubotty::Dashboard::ReadmeRenderer.reset!
  end

  private

  def write_dashboard_guide_fixture(dir, present:)
    path = File.join(dir, "guide.md")
    source = dashboard_guide_markdown
    File.write(path, source, encoding: Encoding::UTF_8) if present
    renderer = Rubotty::Dashboard::ReadmeRenderer
    allow(renderer).to receive(:scripting_path).and_return(path)
    renderer.reset!
    [path, source]
  end
end

RSpec.configure { |config| config.include DashboardGuideFixture }
