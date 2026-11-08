# frozen_string_literal: true

# Works out which declaration wins for one element across the stylesheets a
# page really loads, so a check can ask what a browser would draw instead of
# reading a selector and hoping. Both bugs behind #982 were invisible to a
# reader precisely because every selector involved looked correct on its own:
# `.rb-align-end` sets the alignment it says it does and loses anyway, to
# `.rb-table td` beside it. The stylesheets to feed it are {.fallback} and a
# theme's compiled output, in that order, which is the order a page links them.
module CssCascade
  module_function

  VIEWS = File.expand_path("../../lib/rubotty/dashboard/views", __dir__)

  # The chrome and content floor layout.erb inlines into every page.
  def fallback = read("fallback.css")

  # The primitive classes as the un-themed page draws them. Served only while
  # the theme layer is off, so a themed question must not include it.
  def fallback_vocabulary = read("fallback-vocabulary.css")

  # What a themed page loads, in source order.
  def themed(theme_css) = "#{fallback}\n#{theme_css}"

  # What a page loads with the theme layer switched off.
  def unthemed = "#{fallback}\n#{fallback_vocabulary}"

  def read(name)
    @read ||= {}
    @read[name] ||= File.read(File.join(VIEWS, name), encoding: "UTF-8")
  end

  Rule = Struct.new(:selector, :value, :layered, :specificity, :order)

  # One element in the chain being asked about, outermost first. States are the
  # pseudo-classes this element is in, named without their colon.
  Node = Struct.new(:tag, :classes, :attributes, :states, :pseudo)

  def node(tag, *classes, attributes: {}, states: [], pseudo: nil)
    Node.new(tag, classes, attributes.transform_keys(&:to_s), states.map(&:to_s), pseudo&.to_s)
  end

  # The three shapes a custom property's mode switch takes: an unqualified
  # :root, an explicit data-theme, and the prefers-color-scheme idiom. Always
  # the outermost compound, never the element being asked about.
  ROOT_TOKEN = /\A:root(?:\[data-theme=(?:"(light|dark)"|(light|dark))\]|:not\(\[data-theme="?light"?\]\))?\z/

  def root_token?(token) = ROOT_TOKEN.match?(token)

  # nil for a root token good in either mode (an unqualified :root, the
  # swatch's own light default); "light" or "dark" for one an explicit
  # data-theme, or the prefers-color-scheme idiom, restricts to.
  def root_mode(token)
    match = ROOT_TOKEN.match(token)
    return nil unless match

    match[1] || match[2] || (token.include?(":not(") ? "dark" : nil)
  end

  # The value a browser would resolve for property on the last node of chain,
  # or nil when no rule reaches it. mode narrows a custom property's own
  # root-level declaration to its light or dark half and is ignored otherwise.
  def value_of(css, property, chain, mode: nil)
    winner = candidates(css, property, chain, mode).max_by { |rule| priority(rule) }
    winner&.value
  end

  # An unlayered declaration beats a layered one however the two selectors
  # weigh, which is the whole reason the fallback sits in a layer.
  def priority(rule) = [rule.layered ? 0 : 1, rule.specificity, rule.order]

  # Every rule that both declares property and reaches the target element.
  def candidates(css, property, chain, mode = nil)
    target = chain.last
    rules(css, property).select do |rule|
      next false unless plausible?(rule.selector, target)

      matches?(rule.selector, chain, mode)
    end
  end

  # Selector, value pairs for one property. At-rule wrappers fall out of this
  # rather than being parsed, @layer excepted, since what a layer holds loses
  # to anything outside it.
  def rules(css, property)
    @rules ||= {}
    @rules[[css.hash, property]] ||= blocks(css).flat_map do |selectors, body, layered, order|
      value = declared(body, property)
      next [] unless value

      selectors.split(",").map(&:strip).reject(&:empty?).map do |selector|
        Rule.new(selector, value, layered, specificity(selector), order)
      end
    end
  end

  # One stylesheet is asked about many properties, and the scan below is the
  # expensive half, so a sheet is broken into blocks once.
  def blocks(css)
    @blocks ||= {}
    @blocks[css.hash] ||= begin
      found = []
      each_rule(strip_comments(css)) { |selectors, body, layered| found << [selectors, body, layered, found.length] }
      found
    end
  end

  # Walks blocks in source order, opening at-rules and reporting the style
  # rules inside them. Anything a browser would not read as a rule (a keyframe
  # step, a statement at-rule) has to be dropped here rather than downstream.
  def each_rule(css, layered: false, &block)
    index = 0
    prelude = +""
    while index < css.length
      case css[index]
      when "{"
        finish = closing_brace(css, index)
        name = prelude.strip
        body = css[(index + 1)...finish]
        if name.start_with?("@")
          each_rule(body, layered: layered || name.match?(/\A@layer\b/), &block) unless skipped?(name)
        else
          block.call(name, body, layered)
        end
        prelude = +""
        index = finish + 1
      when ";"
        prelude = +""
        index += 1
      else
        prelude << css[index]
        index += 1
      end
    end
  end

  # An at-rule whose contents are not style rules at all.
  def skipped?(name) = name.match?(/\A@(keyframes|font-face|counter-style|property|-\w+-keyframes)\b/)

  def closing_brace(css, open)
    depth = 0
    index = open
    while index < css.length
      depth += 1 if css[index] == "{"
      if css[index] == "}"
        depth -= 1
        return index if depth.zero?
      end
      index += 1
    end
    raise "CssCascade found no closing brace for the block opening at #{open}"
  end

  # The last declaration of property in one rule body wins inside that rule.
  def declared(body, property)
    body.scan(/(?:\A|;)\s*#{Regexp.escape(property)}\s*:\s*([^;]+)/).flatten
        .last&.sub(/\s*!important\s*\z/, "")&.strip&.downcase
  end

  # The byte order mark dart-sass writes would otherwise be read as the first
  # character of the first selector, which is what makes it disappear.
  def strip_comments(css) = css.gsub(%r{/\*.*?\*/}m, "").delete("﻿")

  # Cheap and optimistic, so a rule that cannot touch this element at all is
  # dropped before the strict parse below ever sees it. Attributes and
  # pseudo-classes are ignored here and decided properly in {.matches?}.
  def plausible?(selector, target)
    last = selector.split(/[\s>+~]+/).reject(&:empty?).last.to_s
    tag = last[/\A[a-zA-Z][a-zA-Z0-9-]*/]
    return false if tag && !target.tag.to_s.casecmp?(tag)

    last.scan(/(?<![(\w-])\.([a-zA-Z0-9_-]+)/).flatten.all? { |name| target.classes.include?(name) }
  end

  def specificity(selector)
    @specificity ||= {}
    @specificity[selector] ||= weigh(selector)
  end

  def weigh(selector)
    parts(selector).reject { |part| part == ">" }
                   .flat_map { |part| pieces(part) }
                   .map { |piece| weight(piece) }
                   .reduce([0, 0, 0]) { |sum, one| [sum[0] + one[0], sum[1] + one[1], sum[2] + one[2]] }
  end

  # Ids, then classes and attributes and pseudo-classes, then types. :not, :is
  # and :has take their most specific argument, and :where takes nothing.
  def weight(piece)
    case piece
    when "*" then [0, 0, 0]
    when /\A#/ then [1, 0, 0]
    when /\A(\.|\[)/ then [0, 1, 0]
    when /\A::/ then [0, 0, 1]
    when /\A:where\(/i then [0, 0, 0]
    when /\A:(?:not|is|has)\((.*)\)\z/mi
      Regexp.last_match(1).split(",").map { |inner| weigh(inner.strip) }.max || [0, 0, 0]
    when /\A:/ then [0, 1, 0]
    else [0, 0, 1]
    end
  end

  def matches?(selector, chain, mode = nil)
    tokens = parts(selector)
    match_from(tokens, tokens.length - 1, chain, chain.length - 1, mode)
  end

  # Right to left, the way a browser does it: the rightmost compound has to be
  # the element itself, everything left of it an ancestor, and a root token a
  # mode gate that settles the match on its own instead of against the chain.
  def match_from(tokens, token_index, chain, chain_index, mode = nil)
    return true if token_index.negative?

    token = tokens[token_index]
    if root_token?(token)
      return false unless mode.nil? || root_mode(token).nil? || root_mode(token) == mode

      return token_index.zero?
    end
    return false if chain_index.negative?
    return false unless compound_matches?(token, chain[chain_index])

    case token_index.zero? ? nil : tokens[token_index - 1]
    when nil then true
    when ">" then match_from(tokens, token_index - 2, chain, chain_index - 1, mode)
    else
      # -1 stands for the document root beyond the chain's own elements, the
      # only position left of every real ancestor a root token can still
      # settle a match from.
      (-1...chain_index).to_a.reverse.any? { |up| match_from(tokens, token_index - 1, chain, up, mode) }
    end
  end

  def compound_matches?(compound, node)
    parts = pieces(compound)
    return false if node.pseudo && parts.none? { |part| part.start_with?("::") }

    parts.all? { |piece| piece_matches?(piece, node) }
  end

  def piece_matches?(piece, node)
    case piece
    when "*" then true
    when /\A#(.+)\z/m then attributes_of(node)["id"] == Regexp.last_match(1)
    when /\A\.(.+)\z/m then node.classes.include?(Regexp.last_match(1))
    when /\A\[(.+)\]\z/m then attribute_matches?(Regexp.last_match(1), node)
    when /\A::(.+)\z/ then node.pseudo == Regexp.last_match(1)
    when /\A:not\((.*)\)\z/mi
      Regexp.last_match(1).split(",").none? { |inner| compound_matches?(inner.strip, node) }
    when /\A:(?:is|where)\((.*)\)\z/mi
      Regexp.last_match(1).split(",").any? { |inner| compound_matches?(inner.strip, node) }
    when /\A:([\w-]+)/m then node.states.include?(Regexp.last_match(1))
    else node.tag.to_s.casecmp?(piece)
    end
  end

  # The class list is written as classes rather than as an attribute, so a
  # [class*="rb-"] is answered from the same place a .rb-table is.
  def attributes_of(node)
    { "class" => node.classes.join(" ") }.merge(node.attributes)
  end

  def attribute_matches?(text, node)
    name, operator, wanted = text.match(/\A\s*([\w-]+)\s*(?:([~^$*|]?=)\s*(.*?)\s*)?\z/m)&.captures
    raise "CssCascade cannot read the attribute selector [#{text}]" if name.nil?

    present = attributes_of(node)
    return present.key?(name) if operator.nil?

    actual = present[name]
    return false if actual.nil?

    compare(operator, actual, wanted.to_s.gsub(/\A["']|["']\z/, ""))
  end

  def compare(operator, actual, wanted)
    case operator
    when "=" then actual == wanted
    when "*=" then actual.include?(wanted)
    when "^=" then actual.start_with?(wanted)
    when "$=" then actual.end_with?(wanted)
    when "~=" then actual.split(/\s+/).include?(wanted)
    when "|=" then actual == wanted || actual.start_with?("#{wanted}-")
    end
  end

  # Compounds and the child combinator, split on the whitespace and > that sit
  # outside any bracket or paren. A sibling combinator raises: nothing here
  # uses one, and guessing at it would answer from half the rules.
  def parts(selector)
    found = []
    current = +""
    depth = 0
    selector.strip.each_char do |char|
      depth += 1 if "([".include?(char)
      depth -= 1 if ")]".include?(char)
      if depth.zero? && (char == ">" || char.match?(/\s/))
        found << current unless current.empty?
        found << ">" if char == ">"
        current = +""
      elsif depth.zero? && "+~".include?(char)
        raise "CssCascade cannot read #{selector.inspect}, which uses a sibling combinator"
      else
        current << char
      end
    end
    found << current unless current.empty?
    found
  end

  PIECE = /\*|\#[\w-]+|\.[\w-]+|\[[^\]]*\]|::[\w-]+|:[\w-]+\([^()]*\)|:[\w-]+|[a-zA-Z][\w-]*/

  # One compound broken into the simple selectors it is made of, checked to be
  # sure the whole of it was read.
  def pieces(compound)
    found = compound.scan(PIECE)
    raise "CssCascade cannot read the compound #{compound.inspect}" unless found.join == compound

    found
  end
end
