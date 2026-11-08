# frozen_string_literal: true

require_relative "css_cascade"

# Resolves a colour declaration down to a channel triple, so a check can
# compare the ink a theme sets against the ground it lands on. Reading the two
# declarations is not enough on its own: the pair that made this necessary both
# said var(--rb-success), one as an ink and one as a tint, and only the
# resolved values say they are the same colour.
module CssColour
  module_function

  NAMED = { "white" => [255, 255, 255], "black" => [0, 0, 0] }.freeze
  BLANK = %w[none transparent inherit initial unset currentcolor].freeze

  # Every custom property a stylesheet declares, in light mode. The swatch
  # writes light, then dark, then each mode under its own data-theme, so the
  # dark blocks are dropped by name and the last light declaration wins.
  def definitions(css)
    found = {}
    CssCascade.blocks(css).each do |selector, body, _layered, _order|
      next unless selector.match?(/:root|\.rb-page\b/)
      next if selector.include?('data-theme="dark"')

      body.scan(/(--[\w-]+)\s*:\s*([^;]+)/) { |name, value| found[name] = value.strip }
    end
    found
  end

  # @return [Array<Integer>, nil] the channels, or nil for a colour that lets
  #   what is behind it through
  def resolve(value, definitions, depth = 0)
    raise "CssColour looped resolving #{value.inspect}" if depth > 12

    text = value.to_s.strip
    return nil if text.empty? || BLANK.include?(text.downcase)

    # A background can layer several images/gradients over a solid backing
    # colour, comma separated outside any function's own parens. Only the
    # last layer may carry that colour, so it is the one worth resolving.
    layers = split_arguments(text)
    return resolve(layers.last.to_s.strip, definitions, depth + 1) if layers.length > 1

    return NAMED[text.downcase] if NAMED.key?(text.downcase)
    return hex(text) if text.start_with?("#")
    return variable(text, definitions, depth) if text.downcase.start_with?("var(")
    return mix(text, definitions, depth) if text.downcase.start_with?("color-mix(")
    return channels(text) if text.downcase.start_with?("rgb")

    raise "CssColour cannot read the colour #{text.inspect}"
  end

  # The colour an element ends up sitting on, which is the first ground in the
  # chain that lets nothing through.
  def ground(css, chain, definitions)
    chain.length.downto(1) do |length|
      value = CssCascade.value_of(css, "background", chain.first(length)) ||
              CssCascade.value_of(css, "background-color", chain.first(length))
      colour = resolve(value, definitions)
      return colour if colour
    end
    NAMED["white"]
  end

  def contrast(one, two)
    high, low = [luminance(one), luminance(two)].minmax.reverse
    ((high + 0.05) / (low + 0.05)).round(2)
  end

  def luminance(colour)
    channel = colour.map do |raw|
      part = raw / 255.0
      part <= 0.03928 ? part / 12.92 : (((part + 0.055) / 1.055)**2.4)
    end
    (0.2126 * channel[0]) + (0.7152 * channel[1]) + (0.0722 * channel[2])
  end

  def hex(text)
    digits = text.delete_prefix("#")
    digits = digits.chars.flat_map { |one| [one, one] }.join if digits.length == 3
    raise "CssColour cannot read the colour #{text.inspect}" unless digits.length >= 6

    digits[0, 6].scan(/../).map { |pair| pair.to_i(16) }
  end

  def channels(text)
    numbers = text[/\((.*)\)/m, 1].to_s.split(%r{[,\s/]+}).reject(&:empty?)
    return nil if numbers.length > 3 && numbers[3].to_f.zero?

    numbers.first(3).map { |one| one.end_with?("%") ? (one.to_f * 2.55).round : one.to_f.round }
  end

  def variable(text, definitions, depth)
    inner = text[/\Avar\((.*)\)\z/mi, 1].to_s
    name, given = inner.split(",", 2).map(&:strip)
    declared = definitions[name]
    return resolve(declared, definitions, depth + 1) if declared
    return resolve(given, definitions, depth + 1) if given

    raise "CssColour found no definition for #{name}"
  end

  # color-mix in the sRGB space, which is the one space the themes reach for.
  def mix(text, definitions, depth)
    inner = text[/\Acolor-mix\((.*)\)\z/mi, 1].to_s
    space, first, second = split_arguments(inner)
    raise "CssColour cannot mix in #{space.inspect}" unless space.strip.casecmp?("in srgb")

    one, weight = weighted(first, definitions, depth)
    two, = weighted(second, definitions, depth)
    return nil if one.nil? || two.nil?

    one.zip(two).map { |left, right| ((left * weight) + (right * (1 - weight))).round }
  end

  def weighted(argument, definitions, depth)
    text = argument.strip
    share = text[/\s(\d+(?:\.\d+)?)%\z/, 1]
    text = text.sub(/\s\d+(?:\.\d+)?%\z/, "") if share
    unless share
      trailing = text[/\s(var\(--[\w-]+\))\z/, 1]
      if trailing
        text = text.sub(/\s#{Regexp.escape(trailing)}\z/, "")
        share = resolve_share(trailing, definitions)
      end
    end
    [resolve(text, definitions, depth + 1), share ? share.to_f / 100 : 0.5]
  end

  def resolve_share(text, definitions)
    name = text[/var\((--[\w-]+)\)/, 1]
    definitions.fetch(name) { raise "CssColour found no definition for #{name}" }.delete("%")
  end

  # Splits on the commas that sit outside any bracket.
  def split_arguments(text)
    found = [+""]
    depth = 0
    text.each_char do |char|
      depth += 1 if char == "("
      depth -= 1 if char == ")"
      if char == "," && depth.zero?
        found << +""
      else
        found.last << char
      end
    end
    found
  end
end
