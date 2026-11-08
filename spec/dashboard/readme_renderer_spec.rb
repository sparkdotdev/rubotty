# frozen_string_literal: true
require "tmpdir"

require "spec_helper"
require "rubotty/dashboard/readme_renderer"
require "tempfile"

# README rendering for the dashboard, parsed over a fixture rather than the
# project's own README, which would fail every time a sentence is edited.
RSpec.describe Rubotty::Dashboard::ReadmeRenderer do
  before { described_class.reset! }
  after { described_class.reset! }

  def render(markdown)
    file = Tempfile.new(["readme", ".md"])
    file.write(markdown)
    file.close
    described_class.render(path: file.path)
  ensure
    file&.unlink
  end

  it "renders ordinary markdown to HTML" do
    html = render("# Title\n\nSome *text*.\n")
    expect(html).to include("<h1")
    expect(html).to include("<em>text</em>")
  end

  # A contents list has nothing to link to without this: {Prose#contents}
  # reads these ids straight back out of the rendered heading.
  it "gives every heading its own id, for a contents list to link to" do
    html = render("# Title\n\n## First Section\n\n## Second Section\n")
    expect(html).to include(%(<h2 id="first-section">))
    expect(html).to include(%(<h2 id="second-section">))
  end

  it "escapes raw HTML in the source instead of passing it through" do
    html = render("Hello <script>alert(1)</script> world.\n")
    expect(html).not_to include("<script>")
    expect(html).to include("&lt;script&gt;")
  end

  it "escapes a raw HTML block the same way as a raw HTML span" do
    html = render("<div class=\"evil\">block</div>\n")
    expect(html).not_to include("<div class=\"evil\">")
    expect(html).to include("&lt;div")
  end

  let(:logo_readme) do
    <<~MARKDOWN
      <p align="center">
        <img src="rubotty-logo.png" alt="Rubotty" width="180">
      </p>

      # Rubotty
    MARKDOWN
  end

  it "embeds the logo and preserves its alt text and width" do
    allow(File).to receive(:binread).and_call_original
    allow(File).to receive(:binread).with(described_class::LOGO_PATH).and_return("\x89PNG\r\n\x1a\n".b)

    expect(render(logo_readme)).to include('<img src="data:image/png;base64,iVBORw0KGgo=" alt="Rubotty" width="180"')
  end

  it "renders the document without an image when the logo is absent" do
    allow(File).to receive(:binread).and_call_original
    allow(File).to receive(:binread).with(described_class::LOGO_PATH).and_raise(Errno::ENOENT)

    html = render(logo_readme)
    expect(html).to include('<h1 id="rubotty">Rubotty</h1>')
    expect(html).not_to include("<img", "rubotty-logo.png")
  end

  it "rewrites a relative repo link to an absolute GitHub URL" do
    html = render("See [LICENSE.MD](LICENSE.MD) for the full text.\n")
    expect(html).to include('href="https://github.com/sparkdotdev/rubotty/blob/main/LICENSE.MD"')
  end

  it "serves the contribution policy and full agreement at the legal anchors" do
    html = described_class.render(path: described_class.licence_path, app_root: "/admin-panel")

    expect(html).to include('id="spark-contribution-agreement-110"')
    expect(html).to include('id="contribution-policy"')
    expect(html).to include('href="#spark-contribution-agreement-110"')
    expect(html).to include('href="/admin-panel/licence#contribution-policy"')
  end

  it "leaves an already-absolute link alone" do
    html = render("See [an issue](https://example.invalid/support).\n")
    expect(html).to include('href="https://example.invalid/support"')
  end

  it "leaves an in-page anchor link alone" do
    html = render("See [a section](#a-section).\n")
    expect(html).to include('href="#a-section"')
  end

  it "caches per path, so the same document is not reparsed" do
    file = Tempfile.new(["readme", ".md"])
    file.write("# One\n")
    file.close

    first = described_class.render(path: file.path)
    File.write(file.path, "# Changed on disk\n")
    second = described_class.render(path: file.path)
    file.unlink

    expect(second).to eq(first)
  end

  # @rendered is keyed by [path, app_root], and the dashboard renders both the
  # README and the scripting reference through this: a cache keyed on path
  # alone would hand the second document the first one's HTML.
  it "keeps two documents apart" do
    one = Tempfile.new(["one", ".md"])
    one.write("# One\n")
    one.close
    two = Tempfile.new(["two", ".md"])
    two.write("# Two\n")
    two.close

    first = described_class.render(path: one.path)
    second = described_class.render(path: two.path)
    one.unlink
    two.unlink

    expect(first).to include("One")
    expect(second).to include("Two")
  end

  it "degrades to nil when README.md is not present, rather than raising" do
    expect(described_class.render(path: "/nonexistent/README.md")).to be_nil
  end
end

# Every fenced block in these documents is written the GitHub way and kramdown's
# own fence is ~~~, so without a rewrite each one parses as a paragraph holding a
# code span.
RSpec.describe Rubotty::Dashboard::ReadmeRenderer, "fenced code blocks" do
  def html(source) = described_class.send(:to_html, source)

  it "renders a backtick fence as a code block, not a paragraph" do
    rendered = html("before\n\n```lua\nlocal m = ...\nreturn nil\n```\n\nafter\n")

    expect(rendered).to include("<pre><code")
    expect(rendered).not_to include("<p><code>lua")
  end

  it "keeps the language, which is what the editor highlights by" do
    expect(html("```lua\nreturn nil\n```\n")).to include('class="language-lua"')
  end

  it "keeps the newlines inside the block" do
    expect(html("```lua\nlocal a = 1\nlocal b = 2\n```\n")).to include("local a = 1\nlocal b = 2")
  end

  it "leaves inline code alone" do
    expect(html("a `bare` word\n")).to include("<code>bare</code>")
  end

  # A fence marker only means anything on a line of its own.
  it "leaves a backtick run inside a sentence alone" do
    expect(html("write ``` to open a block\n")).not_to include("<pre>")
  end

  it "renders every fenced block in an installed guide" do
    with_dashboard_guide_fixture do |path, _source|
      rendered = described_class.render(path: path)

      expect(rendered.scan("<pre><code").size).to eq(3)
      expect(rendered).to include('class="language-lua"').and include('class="language-yaml"')
      expect(rendered).not_to include("<p><code>lua")
    end
  end

  # \s matches newlines, so a fence rewrite using it on both sides eats the blank
  # line after a closing fence and glues the next heading onto the code block.
  it "keeps the blank line after a closing fence" do
    rendered = html("```lua\nreturn nil\n```\n\n### After the block\n\ntext\n")

    expect(rendered).to include("<h3")
    expect(rendered).not_to include("### After the block")
  end

  it "leaves every guide heading after a fenced block as a heading" do
    with_dashboard_guide_fixture do |path, _source|
      rendered = described_class.render(path: path)

      expect(rendered.scan(/<h3/).size).to eq(3)
      expect(rendered).to include('id="state"').and include('id="configuration"')
      expect(rendered).not_to include("###")
    end
  end
end

# A deployment under a POSIX or C locale gets US-ASCII as Encoding.default_external
# and File.read follows it, so one accented character in README.md takes the
# dashboard index down unless these documents are read as UTF-8 outright.
RSpec.describe Rubotty::Dashboard::ReadmeRenderer, "under an ASCII locale" do
  around do |example|
    was = Encoding.default_external
    # Ruby warns on the assignment, which is noise here rather than news.
    original = $VERBOSE
    $VERBOSE = nil
    Encoding.default_external = Encoding::US_ASCII
    example.run
  ensure
    Encoding.default_external = was
    $VERBOSE = original
  end

  it "renders a document holding non-ASCII text" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "doc.md")
      File.write(path, "# Café\n\nBridging a room in Köln, naïvely.\n")
      described_class.instance_variable_set(:@rendered, nil)

      rendered = described_class.render(path: path)

      expect(rendered).to include("Köln")
      expect(rendered.encoding).to eq(Encoding::UTF_8)
    end
  ensure
    described_class.instance_variable_set(:@rendered, nil)
  end

  it "renders the release documents the dashboard serves" do
    %w[../../README.md ../../LICENSE.MD ../../CONTRIBUTING.md].each do |relative|
      described_class.instance_variable_set(:@rendered, nil)
      path = File.expand_path(relative, __dir__)

      expect { described_class.render(path: path) }.not_to raise_error
    end
  ensure
    described_class.instance_variable_set(:@rendered, nil)
  end

  it "reads an optional guide as UTF-8 rather than the process locale" do
    with_dashboard_guide_fixture do |path, _source|
      expect(described_class.render(path: path)).to include("Café").and include("Köln")
    end
  end
end
