# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "tmpdir"

# dart-sass writes a UTF-8 BOM in compressed mode whenever the output holds a
# non-ascii character (assets/dashboard/style.scss's "\25B8" arrow). Inlined
# into a style tag it corrupts the first CSS rule. scripts/strip-bom.js removes
# it at build time; this spec guards the script and package.json's wiring of it.
RSpec.describe "dashboard CSS BOM stripping" do
  repo_root = File.expand_path("../..", __dir__)
  bom_strip_script = File.join(repo_root, "scripts", "strip-bom.js")

  let(:root) { repo_root }
  let(:strip_script) { bom_strip_script }

  def node = DashboardToolchain.path("node")

  def run!(*cmd)
    out, status = Open3.capture2e(*cmd)
    raise "#{cmd.join(' ')} failed:\n#{out}" unless status.success?

    out
  end

  describe "scripts/strip-bom.js" do
    it "removes a leading UTF-8 BOM in place" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "with-bom.css")
        File.binwrite(path, "\xEF\xBB\xBF.rb-page{color:red}".b)

        run!(node, strip_script, path)

        expect(File.binread(path)).to eq(".rb-page{color:red}")
      end
    end

    it "leaves a file with no BOM untouched" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "clean.css")
        File.binwrite(path, ".rb-page{color:red}")

        run!(node, strip_script, path)

        expect(File.binread(path)).to eq(".rb-page{color:red}")
      end
    end
  end

  describe "package.json" do
    let(:scripts) { JSON.parse(File.read(File.join(root, "package.json"))).fetch("scripts") }

    # railpack.json lists scripts/strip-bom.js as a local include, which
    # railpack flattens to /app/strip-bom.js at deploy time (see
    # spec/deploy/railpack_spec.rb), so the invocation resolves the script at
    # either path rather than assuming the repository layout survived.
    it "strips the BOM from the built dashboard stylesheet" do
      expect(scripts.fetch("build:dashboard-style")).to match(%r{node .*strip-bom\.js\)? \S+\.css\z})
    end
  end

  if DashboardToolchain.ready?(%w[node sass])
    describe "a real sass compile" do
      it "starts with a rule after the BOM is stripped" do
        Dir.mktmpdir do |dir|
          output = File.join(dir, "dashboard.css")
          run!(DashboardToolchain.path("sass"), "--no-source-map", "--style=compressed",
               File.join(root, "assets/dashboard/style.scss"), output)
          run!(node, strip_script, output)

          bytes = File.binread(output)
          expect(bytes.byteslice(0, 3)).not_to eq("\xEF\xBB\xBF".b)
          expect(bytes[0]).to match(/[.:@]/)
        end
      end
    end
  else
    it "has no toolchain installed to compile the stylesheets with" do
      DashboardToolchain.report_gap!(self, %w[node sass], "the dashboard CSS BOM check")
    end
  end
end
