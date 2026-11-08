# frozen_string_literal: true

require "json"
require "open3"
require "fileutils"
require "digest"

# Record the installed toolchain, including packages missed by generic image scanners.
module RuntimeComponents
  RECEIPT = "/usr/local/share/rubotty/runtime-components.json"
  TEAL_SOURCE = "/usr/local/share/rubotty/teal-source.json"

  def self.command(*arguments)
    stdout, stderr, status = Open3.capture3(*arguments)
    raise "Runtime component probe failed: #{arguments.first}" unless status.success?

    (stdout + stderr).strip
  end

  def self.available?(name)
    ENV.fetch("PATH").split(File::PATH_SEPARATOR).any? { |directory| File.executable?(File.join(directory, name)) }
  end

  def self.version(name, *arguments)
    output = command(name, *arguments)
    found = output[/\b\d+\.\d+\.\d+(?:[-+][A-Za-z0-9._-]+)?/]
    raise "Runtime component version is missing: #{name}" unless found

    { "version" => found, "version_output" => output }
  end

  def self.write_json(path, data)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(data) + "\n")
  end

  def self.capture_teal(checkout, destination = TEAL_SOURCE)
    revision = command("git", "-C", checkout, "rev-parse", "HEAD")
    raise "Teal source revision is invalid" unless revision.match?(/\A[0-9a-f]{40}\z/)

    write_json(destination, version("tl", "--version").merge("source_commit" => revision))
  end

  def self.capture(destination = RECEIPT, source = TEAL_SOURCE)
    runtimes = {
      "ruby" => version("ruby", "--version"),
      "lua" => version("lua", "-v"),
      "luarocks" => version("luarocks", "--version")
    }
    tools = {}
    tools["fennel"] = version("fennel", "--version") if available?("fennel")
    if available?("tl")
      raise "Installed Teal has no recorded source revision" unless File.file?(source)

      tools["teal"] = version("tl", "--version")
      recorded = JSON.parse(File.read(source))
      unless tools["teal"]["version"] == recorded["version"] && recorded["source_commit"].to_s.match?(/\A[0-9a-f]{40}\z/)
        raise "Installed Teal differs from its source receipt"
      end
      tools["teal"]["source_commit"] = recorded.fetch("source_commit")
    end
    rocks = command("luarocks", "list", "--porcelain").lines.filter_map do |line|
      name, rock_version, state = line.split
      next unless state == "installed"

      { "name" => name, "version" => rock_version }
    end
    if tools.key?("fennel") && rocks.none? { |rock| rock["name"].downcase == "fennel" }
      raise "Installed Fennel is absent from the LuaRocks inventory"
    end
    if tools.key?("teal") && rocks.none? { |rock| %w[tl teal].include?(rock["name"].downcase) }
      raise "Installed Teal is absent from the LuaRocks inventory"
    end
    write_json(destination, { "schema_version" => 1, "runtimes" => runtimes, "tools" => tools,
                              "rocks" => rocks.sort_by { |rock| [rock["name"], rock["version"]] } })
  end

  def self.enrich(sbom_path, receipt_path, output_path)
    sbom = JSON.parse(File.read(sbom_path))
    raise "Expected a CycloneDX JSON SBOM" unless sbom["bomFormat"] == "CycloneDX"

    receipt = JSON.parse(File.read(receipt_path))
    raise "Unsupported runtime component receipt" unless receipt["schema_version"] == 1

    components = sbom["components"] ||= []
    add = lambda do |name, version, kind, purl, properties = []|
      existing = components.find { |entry| entry["type"] != "file" && entry["name"].to_s.downcase == name.downcase && entry["version"] == version }
      if existing
        existing["properties"] = ((existing["properties"] || []) + properties).uniq unless properties.empty?
      else
        components << { "type" => kind, "name" => name, "version" => version, "purl" => purl,
                        "bom-ref" => purl, "properties" => properties }
      end
    end
    receipt.fetch("runtimes").each do |name, entry|
      version = entry.fetch("version")
      add.call(name, version, "application", "pkg:generic/#{name}@#{version}",
               [{ "name" => "rubotty:runtime-probe", "value" => entry.fetch("version_output") }])
    end
    receipt.fetch("rocks").each do |rock|
      name, version = rock.values_at("name", "version")
      tool_name = { "fennel" => "fennel", "tl" => "teal", "teal" => "teal" }[name.downcase]
      tool = receipt.fetch("tools")[tool_name]
      properties = []
      if tool
        properties << { "name" => "rubotty:probed-version", "value" => tool.fetch("version") }
        properties << { "name" => "rubotty:source-commit", "value" => tool["source_commit"] } if tool["source_commit"]
      end
      add.call(name, version, "library", "pkg:luarocks/#{name.downcase}@#{version}", properties)
    end
    metadata = sbom["metadata"] ||= {}
    properties = metadata["properties"] ||= []
    properties.reject! { |entry| entry["name"] == "rubotty:runtime-receipt-sha256" }
    properties << { "name" => "rubotty:runtime-receipt-sha256", "value" => Digest::SHA256.file(receipt_path).hexdigest }
    write_json(output_path, sbom)
  end
end

if $PROGRAM_NAME == __FILE__
  action, *arguments = ARGV
  case action
  when "capture-teal" then RuntimeComponents.capture_teal(*arguments)
  when "capture" then RuntimeComponents.capture(*arguments)
  when "enrich" then RuntimeComponents.enrich(*arguments)
  else abort "Usage: runtime-components.rb capture-teal CHECKOUT [OUTPUT] | capture [OUTPUT [TEAL_SOURCE]] | enrich SBOM RECEIPT OUTPUT"
  end
end
