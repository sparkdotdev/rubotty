# frozen_string_literal: true

require "kramdown"
require "base64"

module Kramdown
  module Parser
    # kramdown has no option that disallows raw HTML in the source. Must live under
    # Kramdown::Parser under this name for `Document.new(input: ...)` to find it.
    # Overriding beats dropping :block_html/:span_html: that breaks markdown tables.
    class RubottySafe < Kramdown
      # Never claims a block as HTML; dispatch falls through to the paragraph parser.
      def parse_block_html
        false
      end

      # Adds the "<" that triggered this as one character of ordinary text, so the
      # converter escapes it and a README containing `<script>` renders it inert.
      def parse_span_html
        add_text(escape_html(@src.scan(/./m)))
      end
    end
  end
end

module Rubotty
  module Dashboard
    # Renders README.md for the dashboard's Documentation screen. The README's one
    # deliberate piece of raw HTML is the centred logo; {rewrite_logo} swaps it for
    # a markdown image before parsing so it survives {Kramdown::Parser::RubottySafe}
    # above.
    class ReadmeRenderer
      REPO_URL = "https://github.com/sparkdotdev/rubotty"
      RAW_URL = "https://raw.githubusercontent.com/sparkdotdev/rubotty/main"
      LOGO_PATH = File.expand_path("../../../rubotty-logo.png", __dir__)

      LOGO_HTML = %r{<p align="center">\s*<img src="([^"]+)" alt="([^"]*)"(?:\s+width="(\d+)")?[^>]*>\s*</p>}.freeze

      # Relative targets this dashboard serves itself: the repository is
      # private, so rewriting these to GitHub sends an operator to a 404. Add
      # a route here and the README's link to it follows automatically.
      IN_APP_DOCS = {
        "LICENSE.MD" => "/licence",
        "CONTRIBUTING.md" => "/licence#contribution-policy",
        "docs/scripting.md" => "/documentation"
      }.freeze

      class << self
        # The rendered HTML, or +nil+ if README.md is not present. Memoized
        # per path, since the source only changes on a deploy; +app_root+ is
        # the mount prefix, and given one, README links to IN_APP_DOCS point
        # here instead of a private repository.
        def render(path: default_path, app_root: nil)
          @rendered ||= {}
          key = [path, app_root]
          return @rendered[key] if @rendered.key?(key)

          @rendered[key] = File.exist?(path) ? to_html(read_source(path), app_root) : nil
        end

        # UTF-8 named outright: under a POSIX or C locale the process default is
        # US-ASCII, and one accented character then 500s the page on the first regex.
        def read_source(path)
          source = File.read(path, encoding: Encoding::UTF_8)
          return source unless File.expand_path(path) == licence_path

          # Keep the standard licence and additional contribution grants in
          # separate files, while making all current terms readable here.
          ["CONTRIBUTING.md"].each do |name|
            additional = File.join(File.dirname(licence_path), name)
            source += "\n\n---\n\n#{File.read(additional, encoding: Encoding::UTF_8)}" if File.file?(additional)
          end
          source
        end

        # The file behind each document {Primitives::Prose} may draw. Every
        # markdown source this dashboard renders is one of these three, all
        # shipped beside the running code, which is the whole reason that
        # primitive can be handed a name instead of a string of markup.
        def document_path(document)
          case document.to_sym
          when :readme then default_path
          when :scripting then scripting_path
          when :licence then licence_path
          else raise ArgumentError, "unknown document #{document.inspect}"
          end
        end

        # The scripting reference, which operators cannot read on disk.
        def scripting_path
          File.expand_path("../../../docs/scripting.md", __dir__)
        end

        # The licence. The repository is private, so the footer's GitHub link is a
        # 404 for the noncommercial operators the licence now entitles.
        def licence_path
          File.expand_path("../../../LICENSE.MD", __dir__)
        end

        # Test-only: clears the memoized render.
        def reset!
          @rendered = nil
        end

        private

        def default_path
          File.expand_path("../../../README.md", __dir__)
        end

        def to_html(source, app_root = nil)
          doc = Kramdown::Document.new(normalise_fences(rewrite_logo(source)), input: "RubottySafe", auto_ids: true)
          rewrite_relative_urls(doc.root, app_root)
          doc.to_html
        end

        # Backtick fences rewritten as the tilde fences kramdown understands; its
        # default parser reads ``` as a code span. Spaces and tabs rather than \s:
        # \s matches newlines, so \s*$ ate the blank line after a fence.
        FENCE = /^([ \t]*)```([A-Za-z0-9_+-]*)[ \t]*$/

        def normalise_fences(source)
          source.to_s.gsub(FENCE) { "#{Regexp.last_match(1)}~~~#{Regexp.last_match(2)}" }
        end

        # The logo converted to a markdown image with a data URL src, so it renders
        # instead of being escaped. The width attribute is carried across in an
        # inline attribute list; without it the oversized PNG renders full size.
        def rewrite_logo(source)
          source.sub(LOGO_HTML) do
            alt = Regexp.last_match(2)
            width = Regexp.last_match(3)
            url = logo_data_url
            next "" unless url

            ial = width ? %({: width="#{width}"}) : ""
            "![#{alt}](#{url})#{ial}"
          end
        end

        def logo_data_url
          "data:image/png;base64,#{Base64.strict_encode64(File.binread(LOGO_PATH))}"
        rescue Errno::ENOENT
          nil
        end

        # Rewrites relative link and image targets to absolute GitHub URLs. Walks
        # the parsed tree, so it cannot reach into a code block.
        def rewrite_relative_urls(element, app_root = nil)
          if element.type == :a && element.attr["href"]
            element.attr["href"] = absolute_url(element.attr["href"], app_root: app_root)
          elsif element.type == :img && element.attr["src"]
            element.attr["src"] = absolute_url(element.attr["src"], image: true)
          end
          element.children.each { |child| rewrite_relative_urls(child, app_root) }
        end

        def absolute_url(target, image: false, app_root: nil)
          return target if target.start_with?("http://", "https://", "mailto:", "data:", "#")

          route = IN_APP_DOCS[target] unless image
          return "#{app_root}#{route}" if app_root && route

          image ? "#{RAW_URL}/#{target}" : "#{REPO_URL}/blob/main/#{target}"
        end
      end
    end
  end
end
