# frozen_string_literal: true

# Reads the swatch sources the way the build does, so the contract is held
# against the SASS an author actually edits rather than against compiled CSS
# that only exists after npm run build.
module Swatches
  module_function

  ROOT = File.expand_path("../../assets/themes", __dir__)

  # Opaque, six digit, lower case. Every role but overlay-scrim is a colour that
  # gets composited against nothing, so alpha would make its contrast unknowable.
  OPAQUE = /\A#[0-9a-f]{6}\z/

  def contract = File.read(File.join(ROOT, "_swatch.scss"), encoding: "UTF-8")

  # The role set, parsed out of the $roles list rather than repeated here.
  def roles
    contract[/\$roles:(.*?);/m, 1].to_s.split(",").map(&:strip).reject(&:empty?)
  end

  # The declaration weight for every role. A role's value tells a swatch what
  # colour to emit; its weight tells a stylesheet where that colour belongs.
  def weights
    body = contract[/\$weights:\s*\((.*?)\);/m, 1].to_s
    body.lines.filter_map do |line|
      match = line.match(/\A\s*([a-z-]+):\s*(ink|ground|rule|fill),?\s*\z/)
      [match[1], match[2]] if match
    end.to_h
  end

  # A solid ink is a marker until text is painted over it, when it becomes a
  # failed ground. Grounds also never become text or a border. colour-mix()
  # remains valid because it makes a ground from a controlled tint, which is
  # how status pills retain the tone without putting text on the raw ink.
  def weight_offences(css)
    CssCascade.blocks(css).flat_map do |selector, body, _layered, _order|
      declarations = body.scan(/(?:\A|;)\s*([a-z-]+)\s*:\s*([^;{}]+)/).to_h
      coloured = declarations.fetch("color", "")
      coloured_role = role_in(coloured)
      grounds = %w[background background-color].filter_map { |property| role_in(declarations[property]) }

      offences = []
      if coloured_role && weights.fetch(coloured_role) == "ground"
        offences << "#{selector}: color uses #{coloured_role}, a ground role"
      end
      if coloured_role && weights.fetch(coloured_role) == "rule"
        offences << "#{selector}: color uses #{coloured_role}, a rule role"
      end
      if coloured_role && grounds.any? { |role| weights.fetch(role) == "ink" }
        grounds.filter { |role| weights.fetch(role) == "ink" }.each do |role|
          offences << "#{selector}: background uses #{role}, an ink role behind text"
        end
      end

      %w[border border-color border-top border-top-color border-right border-right-color border-bottom border-bottom-color border-left border-left-color outline outline-color]
        .filter_map { |property| role_in(declarations[property]) }
        .select { |role| weights.fetch(role) == "ground" }
        .each { |role| offences << "#{selector}: border uses #{role}, a ground role" }

      offences
    end
  end

  def role_in(value)
    name = value.to_s[/\Avar\(--rb-([a-z-]+)(?:,|\))/, 1]
    name if name && weights.key?(name)
  end

  # How many colours the series role carries, from $series-length.
  def series_length = contract[/\$series-length:\s*(\d+)/, 1].to_i

  # The series role's value is an ordered list rather than one colour.
  def series(colours) = colours.fetch("series").delete("()").split(",").map(&:strip)

  def paths = Dir.glob(File.join(ROOT, "swatches", "swatch-*.scss")).sort

  def names = paths.map { |path| File.basename(path, ".scss").delete_prefix("swatch-") }

  # Both modes of one swatch, each as a role to value hash.
  def read(name)
    source = File.read(File.join(ROOT, "swatches", "swatch-#{name}.scss"), encoding: "UTF-8")
    %w[light dark].to_h { |mode| [mode, parse(source, mode)] }
  end

  # One `$mode: ( role: value, ... );` map. Read a line at a time because rgba()
  # carries commas of its own, which splitting the body on commas would eat.
  def parse(source, mode)
    body = source[/\$#{mode}:\s*\((.*?)^\);/m, 1].to_s
    body.lines.filter_map do |line|
      match = line.match(/\A\s*([a-z-]+):\s*(.+?),?\s*\z/)
      [match[1], match[2]] if match
    end.to_h
  end

  # WCAG 2.x relative luminance.
  def luminance(hex)
    channels = hex.delete_prefix("#").scan(/../).map { |pair| pair.to_i(16) / 255.0 }
    linear = channels.map { |channel| channel <= 0.03928 ? channel / 12.92 : (((channel + 0.055) / 1.055)**2.4) }
    (0.2126 * linear[0]) + (0.7152 * linear[1]) + (0.0722 * linear[2])
  end

  def contrast(one, other)
    pair = [luminance(one), luminance(other)]
    (pair.max + 0.05) / (pair.min + 0.05)
  end

  # CIE L*a*b* under D65, because contrast ratio reads two equally bright colours
  # as identical, which red and green are. The 0.04045 here is the sRGB spec's
  # own threshold rather than a typo of the 0.03928 WCAG froze above it.
  def lab(hex)
    channels = hex.delete_prefix("#").scan(/../).map { |pair| pair.to_i(16) / 255.0 }
    red, green, blue = channels.map { |c| c <= 0.04045 ? c / 12.92 : (((c + 0.055) / 1.055)**2.4) }
    white = [0.95047, 1.0, 1.08883]
    xyz = [(0.4124 * red) + (0.3576 * green) + (0.1805 * blue),
           (0.2126 * red) + (0.7152 * green) + (0.0722 * blue),
           (0.0193 * red) + (0.1192 * green) + (0.9505 * blue)]
    fx, fy, fz = xyz.zip(white).map do |value, reference|
      ratio = value / reference
      ratio > 0.008856 ? ratio**(1.0 / 3) : (7.787 * ratio) + (16.0 / 116)
    end
    [(116 * fy) - 16, 500 * (fx - fy), 200 * (fy - fz)]
  end

  # CIE76, which is the crude one and is plenty for "are these two obviously
  # different colours". Just noticeable is about 2.3.
  def delta_e(one, other) = Math.sqrt(lab(one).zip(lab(other)).sum { |a, b| (a - b)**2 })
end
