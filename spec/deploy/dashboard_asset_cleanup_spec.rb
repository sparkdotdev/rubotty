# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"
require "fileutils"

RSpec.describe "retired dashboard asset cleanup" do
  it "removes old appearance assets from a reused build directory and preserves unrelated files" do
    script = File.expand_path("../../scripts/clean-dashboard-assets.js", __dir__)
    Dir.mktmpdir do |dir|
      public_dir = File.join(dir, "lib/rubotty/dashboard/public")
      FileUtils.mkdir_p(File.join(public_dir, "fonts"))
      %w[theme-obsolete.css swatch-ruby.css chart-engine-rough-viz.js fonts/comic-neue-latin-400-normal.woff2].each do |name|
        File.write(File.join(public_dir, name), "retired")
      end
      File.write(File.join(public_dir, "dashboard.css"), "active")
      File.write(File.join(public_dir, "fonts", "other.woff2"), "unrelated")

      output, status = Open3.capture2e(DashboardToolchain.path("node"), script, chdir: dir)

      expect(status.success?).to be(true), output
      expect(Dir.children(public_dir)).to contain_exactly("dashboard.css", "fonts")
      expect(Dir.children(File.join(public_dir, "fonts"))).to eq(["other.woff2"])
      expect(File.read(File.join(public_dir, "dashboard.css"))).to eq("active")
    end
  end
end
