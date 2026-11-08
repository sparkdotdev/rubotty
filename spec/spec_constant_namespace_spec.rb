# frozen_string_literal: true

require "spec_helper"
require "ripper"

# A class, module or constant written directly inside a describe block still
# defines that constant on Object, so a second spec file reusing the name
# reopens or reassigns it and can fail with a superclass mismatch or share
# state silently. Each file's own helpers belong under a module instead.
RSpec.describe "spec file constants" do
  def const_name(ref)
    case ref[0]
    when :const_ref, :top_const_ref
      ref[1][1]
    when :const_path_ref
      "#{const_name(ref[1])}::#{ref[2][1]}"
    end
  end

  # The constant's name for CONST = value, CONST ||= value, and the
  # Struct.new, Data.define or Class.new cases, since those are ordinary
  # assignment with that value on the right. nil for a qualified target
  # (Module::CONST = value): it already names the module it belongs to, so
  # it cannot leak onto Object.
  def bare_const_assignment_name(node)
    return nil unless %i[assign opassign].include?(node[0])

    target = node[1]
    return nil unless target.is_a?(Array) && target[0] == :var_field

    const_token = target[1]
    const_token[1] if const_token.is_a?(Array) && const_token[0] == :@const
  end

  # Walks the parse tree instead of counting indentation, since indentation
  # cannot tell a describe block's do/end apart from a real class or module
  # scope. depth only grows while walking inside a class or module body, so a
  # class nested in a support module is not mistaken for a top level one.
  def record_top_level_defs(node, depth, path, found)
    return unless node.is_a?(Array)

    case node[0]
    when :class
      found[const_name(node[1])] << path if depth.zero?
      record_top_level_defs(node[3], depth + 1, path, found)
    when :module
      found[const_name(node[1])] << path if depth.zero?
      record_top_level_defs(node[2], depth + 1, path, found)
    else
      name = bare_const_assignment_name(node)
      found[name] << path if depth.zero? && name
      node.each { |child| record_top_level_defs(child, depth, path, found) if child.is_a?(Array) }
    end
  end

  it "never gives two spec files a top level class, module or constant of the same name" do
    found = Hash.new { |hash, key| hash[key] = [] }

    Dir.glob("spec/**/*.rb").sort.each do |path|
      sexp = Ripper.sexp(File.read(path, encoding: "UTF-8"))
      next unless sexp

      record_top_level_defs(sexp, 0, path, found)
    end

    offenders = found.select { |_name, paths| paths.uniq.size > 1 }
    report = offenders.map { |name, paths| "  #{name}: #{paths.uniq.join(', ')}" }.join("\n")

    expect(offenders).to be_empty,
                         "shared by more than one file, wrap each in its own module instead:\n#{report}"
  end
end
