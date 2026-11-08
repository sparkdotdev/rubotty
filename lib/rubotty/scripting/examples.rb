# frozen_string_literal: true

module Rubotty
  module Scripting
    # The scripts that ship with rubotty, offered in the editor as a starting
    # point. An example's own header comment is its metadata: the first comment
    # line is the summary, and the `-- trigger:` line names the rule it expects.
    module Examples
      ROOT = File.expand_path("../../../examples/scripting", __dir__)

      # Every example is hand written once per dialect, as files sharing a name
      # and differing only in extension.
      DIRS = { "command" => "commands", "processor" => "processors",
               "callback" => "callbacks" }.freeze

      # An example that reads a data file ships one, as a `.yaml` beside the
      # dialects.
      DATA_EXTENSION = ".yaml"

      # +sources+ is language => body. +data+ is the shipped data file's text,
      # or "" for an example that needs none.
      Example = Struct.new(:id, :name, :kind, :trigger_type, :summary, :sources, :data,
                           keyword_init: true) do
        def source(language) = sources[language.to_s] || sources["lua"]

        def languages = sources.keys
      end

      module_function

      # Every shipped example, ready for the editor's picker.
      def all
        DIRS.flat_map { |kind, dir| load_dir(kind, dir) }.compact.sort_by(&:name)
      end

      def find(id) = all.find { |example| example.id == id.to_s }

      def load_dir(kind, dir)
        Dir[File.join(ROOT, dir, "*.lua")].sort.map do |path|
          build(kind, dir, File.basename(path, ".lua"))
        end
      rescue StandardError
        []
      end

      def build(kind, dir, name)
        sources = Dialects::ALL.each_with_object({}) do |dialect, out|
          path = File.join(ROOT, dir, "#{name}#{dialect.extension}")
          out[dialect.name] = File.read(path) if File.exist?(path)
        end
        return nil if sources.empty?

        lua = Dialects.find("lua")
        Example.new(
          id: "#{dir}/#{name}",
          name: name.tr("_", " "),
          kind: kind,
          trigger_type: sources["lua"][lua.trigger_pattern, 1] || "always",
          summary: summarise(sources["lua"], lua),
          sources: sources,
          data: read_data(dir, name)
        )
      rescue StandardError
        nil
      end

      # The data file beside an example, or "" when it ships none. One file
      # serves every dialect.
      def read_data(dir, name)
        path = File.join(ROOT, dir, "#{name}#{DATA_EXTENSION}")
        File.exist?(path) ? File.read(path) : ""
      rescue StandardError
        ""
      end

      # The first comment line, minus the comment marker.
      def summarise(source, dialect)
        first = source.lines.find do |line|
          line.start_with?(dialect.comment) && !line.match?(dialect.trigger_pattern)
        end
        first.to_s.sub(dialect.summary_prefix, "").strip
      end

      # What the editor page embeds, so picking one fills the body and sets the
      # kind, language and trigger together.
      def payload
        all.map do |example|
          {
            "id" => example.id, "name" => example.name, "kind" => example.kind,
            "trigger_type" => example.trigger_type, "summary" => example.summary,
            "sources" => example.sources, "data" => example.data.to_s
          }
        end
      end
    end
  end
end
