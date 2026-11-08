# frozen_string_literal: true

require "rack/utils"
require "json"
require "securerandom"

require "rubotty/dashboard/readme_renderer"

module Rubotty
  module Dashboard
    # The dashboard's whole control vocabulary: fifteen primitives, and every
    # screen composes from them. No primitive accepts a style, class or width
    # argument, so the three widths in one card that started this cannot be
    # written down.
    #
    # The set splits in two: {Identity} is typography, chrome and component
    # styling; {Layout} is navigation and page structure. The guest portal
    # takes {Identity} alone, so a layout primitive does not exist there.
    module Primitives
      # Argument names a primitive may never take. Presence of any of these is
      # how a screen would smuggle a bespoke width or colour back in, so the
      # vocabulary spec reads every signature and fails on one.
      FORBIDDEN_ARGUMENTS = %i[style class klass css width height colour color margin padding].freeze

      # HTML-escape one value. Primitives escape everything they interpolate,
      # so a caller never has to think about it.
      def self.escape(value) = Rack::Utils.escape_html(value.to_s)

      # Attributes as a string, skipping any whose value is nil or false, with
      # true rendering the bare attribute.
      def self.attributes(pairs)
        pairs.filter_map do |name, value|
          next nil if value.nil? || value == false
          next " #{name}" if value == true

          %( #{name}="#{escape(value)}")
        end.join
      end

      # How many slices a share-of-total chart draws before the tail rolls
      # into one. Matches RING_SLICES in assets/themes/runtime/chart.civet.
      RING_SLICES = 6
      RING_REST = "Other"

      # The rows a ring draws: no empty slices, and a tail past the palette
      # rolled into one rather than dropped. Applying this twice changes
      # nothing, which is what lets the server reduce and the client redraw.
      def self.ring_rows(rows)
        live = rows.reject { |row| row[:count] <= 0 }
        return live if live.length <= RING_SLICES

        rest = live.drop(RING_SLICES - 1).sum { |row| row[:count] }
        live.first(RING_SLICES - 1) + [{ label: RING_REST, count: rest }]
      end

      # How a value reaches a page. Primitives own their formatting, so a
      # duration is never a raw second count and a timestamp has one shape.
      module Format
        module_function

        # The one timestamp format. Everything absolute reads this way.
        TIMESTAMP = "%Y-%m-%d %H:%M UTC"

        # Where a hint cuts, with the whole of it kept on hover. A Field told
        # to wrap its hint ignores this and draws every word.
        HINT_LIMIT = 140

        # Words a label writes in capitals, so "External id" stops happening.
        INITIALISMS = %w[api id url uri utc rsvp faq ttl dm ip http https json yaml sql css html js
                         cli ui ok].freeze

        # Relative time steps, as seconds and the unit word.
        RELATIVE_STEPS = [[60, "minute"], [3600, "hour"], [86_400, "day"]].freeze

        # An absolute time, always UTC, always the same shape.
        def timestamp(value)
          return "" if value.nil?
          return value.to_s unless value.respond_to?(:strftime)

          value.getutc.strftime(TIMESTAMP)
        end

        # A recency column reads as a distance rather than a date, up to a
        # month; past that the date is the more useful thing.
        def relative(value, now: Time.now)
          return "" if value.nil?
          return value.to_s unless value.respond_to?(:to_time)

          seconds = (now.to_time - value.to_time).round
          return "in the future" if seconds.negative?
          return "just now" if seconds < 60
          return timestamp(value) if seconds >= 30 * 86_400

          step, word = RELATIVE_STEPS.reverse.find { |size, _| seconds >= size }
          count(seconds / step, word) + " ago"
        end

        # Seconds as human text. The humanizer already knows how, and it is
        # deliberately the only one that does.
        def duration(seconds) = ConfigHumanizer.duration(seconds)

        # A list of durations, which is where the raw second counts leaked out.
        def durations(values) = Array(values).map { |value| duration(value) }

        # A byte count the way a person reads one.
        def bytes(value)
          size = value.to_i.to_f
          unit = "B"
          %w[KB MB GB TB].each do |candidate|
            break if size < 1000

            size /= 1000.0
            unit = candidate
          end
          unit == "B" ? "#{size.to_i} B" : format("%.1f %s", size, unit)
        end

        # The one pluralisation, replacing five hand-rolled ones.
        def count(number, singular, plural = nil)
          whole = number.to_i
          "#{whole} #{whole == 1 ? singular : plural || "#{singular}s"}"
        end

        # Yes and No, never true and false.
        def boolean(value) = value ? "Yes" : "No"

        # Cut at a declared length, on a whole word where one is near the cut.
        def truncate(text, limit)
          body = text.to_s
          return body if body.length <= limit

          cut = body[0, limit]
          space = cut.rindex(" ")
          "#{space && space > limit - 20 ? cut[0, space] : cut}..."
        end

        # A label or a header: sentence case, no trailing colon, initialisms in
        # capitals, and any word the caller capitalised left alone.
        def label(text)
          words = text.to_s.tr("_", " ").strip.sub(/[:.]\z/, "").split(/\s+/)
          shaped = words.map { |word| INITIALISMS.include?(word.downcase) ? word.upcase : word }
          return "" if shaped.empty?

          shaped[0] = shaped[0].sub(/\A./, &:upcase)
          shaped.join(" ")
        end

        # An enum token as the reader sees it, for a select with no declared
        # label table of its own.
        def enum_label(token) = label(token.to_s.tr("-", " "))

        # Every value on a page goes through here, named by what it is.
        def value(raw, as: :text)
          case as
          when :timestamp then timestamp(raw)
          when :relative then relative(raw)
          when :duration then duration(raw)
          when :durations then durations(raw).join(", ")
          when :bytes then bytes(raw)
          when :boolean then boolean(raw)
          when :enum then enum_label(raw)
          when :text, :code then raw.to_s
          else raise ArgumentError, "unknown format #{as.inspect}"
          end
        end
      end

      # Where a rendered markdown document comes from: {Identity#prose} is
      # the one primitive that emits markup it did not escape. It takes no
      # markup argument, only a document name, since a keyword with HTML in
      # it is one somebody eventually fills from a community-supplied
      # string; the three documents render through a kramdown parser that
      # refuses raw HTML outright. {verified} then holds the resolved
      # markup to a second, independent element/attribute check.
      module Prose
        # The documents this primitive may draw, and what to say when a build
        # does not ship one. A name outside this list is not a document.
        DOCUMENTS = {
          readme: "README.md is not shipped alongside this build, so there is nothing to show.",
          scripting: "The scripting reference is not shipped alongside this build, so there is nothing to show.",
          licence: "LICENSE.MD is not shipped alongside this build, so there is nothing to show. " \
                   "The base licence is published at polyformproject.org/licenses/strict/1.0.0."
        }.freeze

        # What a markdown document is made of. A comment, a doctype, a script,
        # an iframe or a bare "<" is none of these and is refused.
        TAGS = %w[a blockquote br code dd del dl dt em h1 h2 h3 h4 h5 h6 hr img li ol p pre
                  strong sub sup table tbody td th thead tr ul].freeze

        # No style, no target, no rel, no data-anything, no on-anything: a
        # document describes itself and never reaches for behaviour on the page
        # around it. data-confirm matters most, since the layout wires the
        # destructive confirm step to any element carrying one.
        ATTRIBUTES = %w[alt class colspan dir height href id lang rowspan scope src start
                        title width].freeze

        # The attributes whose value is checked as well as its name.
        VALUES = {
          # A fenced block's language and nothing else, so a document cannot
          # wear a primitive's class name and be styled as one.
          "class" => /\Alanguage-[a-z0-9+#-]+\z/,
          "href" => %r{\A(?:https?://|mailto:|[#/])},
          "src" => %r{\A(?:https?://|data:image/)}
        }.freeze

        # One element, whole. An element that does not parse exactly this way
        # is refused rather than read as far as it goes, which is what turns a
        # value carrying its own ">" into a refusal instead of a half-read tag
        # with the rest of itself left on the page.
        ELEMENT = %r{\A<(/?)([a-z][a-z0-9]*)((?:\s+[a-zA-Z][a-zA-Z0-9-]*(?:="[^"<>]*")?)*)\s*/?>\z}
        ATTRIBUTE = /([a-zA-Z][a-zA-Z0-9-]*)(?:="([^"<>]*)")?/

        # One document's rendered markup, or +nil+ when this build does not
        # ship the file. +app_root+ is the dashboard's mount prefix, so a link
        # to a page this server serves points here rather than at the private
        # repository.
        def self.markup(document, app_root: nil)
          ReadmeRenderer.render(path: ReadmeRenderer.document_path(document), app_root: app_root)
        end

        # Whether the file is there at all, for a screen that draws nothing
        # rather than an empty state when it is not.
        def self.shipped?(document) = File.exist?(ReadmeRenderer.document_path(document))

        def self.absent(document) = DOCUMENTS.fetch(document)

        # The markup back, once every element in it is one this draws. What is
        # left with the elements taken out is text, and a "<" surviving in it
        # is a tag that did not close, which is refused rather than guessed at.
        def self.verified(markup)
          text = markup.to_s
          left = text.gsub(/<[^>]*>/) do |element|
            check_element!(element)
            ""
          end
          raise ArgumentError, "rendered markdown carries a stray < outside any element" if left.include?("<")

          text
        end

        # The verified markup's own top-level sections, each an { id:, text: }
        # pair a contents list can link to. Kramdown's auto_ids gives every
        # heading its anchor; this only reads the level-2 ones back out, since
        # a document long enough to need a contents list has too many level-3
        # ones to list them all and still fit on an index card.
        def self.contents(markup)
          markup.to_s.scan(%r{<h2 id="([^"]+)">(.*?)</h2>}m).map do |id, text|
            { id: id, text: text.gsub(/<[^>]*>/, "") }
          end
        end

        def self.check_element!(element)
          match = ELEMENT.match(element)
          raise ArgumentError, "rendered markdown carries #{element.inspect}, which is not an element" unless match

          name = match[2]
          raise ArgumentError, "rendered markdown carries a <#{name}>, outside the document vocabulary" unless
            TAGS.include?(name)
          return if match[1] == "/"

          match[3].scan(ATTRIBUTE) { |attribute, value| check_attribute!(name, attribute, value) }
        end

        def self.check_attribute!(tag, name, value)
          raise ArgumentError, "rendered markdown carries #{name}= on a <#{tag}>, which a document may not set" unless
            ATTRIBUTES.include?(name)

          pattern = VALUES[name]
          return if pattern.nil?

          tokens = value.to_s.split(/\s+/)
          return if !tokens.empty? && tokens.all? { |token| pattern.match?(token) }

          raise ArgumentError, "rendered markdown carries #{name}=#{value.inspect} on a <#{tag}>, which this will not draw"
        end
      end

      # Everything a theme styles rather than arranges. The guest portal gets
      # exactly this and nothing else.
      module Identity
        # The tones a Notice may carry. Empty is separate from info on purpose:
        # "here is what this page does" and "there is nothing here" looking
        # alike is the single most confusing thing on nine screens today.
        NOTICE_TONES = %i[info success warning danger empty].freeze

        # The tones a Status may carry, one per genuinely distinct state.
        STATUS_TONES = %i[good bad warn neutral unknown].freeze

        # A mark per tone, so a state is readable without colour. Under the
        # Ruby swatch the accent and the danger colour are the same red, which
        # is exactly the case colour alone cannot carry.
        STATUS_MARKS = { good: "+", bad: "x", warn: "!", neutral: "·", unknown: "?" }.freeze

        # Three button variants, and destructive is the one that has to differ
        # in shape rather than in hue.
        BUTTON_VARIANTS = %i[primary secondary destructive].freeze

        BUTTON_SIZES = %i[small medium].freeze

        # The nine control types, which is the irreducible set: every control
        # on the dashboard today is one of these.
        FIELD_TYPES = %i[text number secret select multiline code toggle choice checklist file].freeze

        # Three semantic sizes, chosen from what the field means rather than
        # from pixels. A port name is short, a name is medium, a URL is full.
        FIELD_SIZES = %i[short medium full].freeze

        # A Form is an edit (POST, primary submit), a filter (GET, secondary
        # submit), or an action: a POST whose whole visible content is one
        # button, so themes can distinguish it from a genuine edit form.
        FORM_VARIANTS = %i[edit filter action].freeze
        FILTER_LABELS = %w[Search Filter].freeze

        # What a toggle Field offers, as a select rather than a checkbox: a
        # checkbox that submits nothing when unticked has already caused a bug.
        TOGGLE_OPTIONS = [["true", "Yes"], ["false", "No"]].freeze

        # The data shapes a Chart may be asked to draw. The server never names
        # a visual form.
        CHART_SHAPES = %i[categorical_distribution time_series share_of_total].freeze

        # Past seven columns a table stops being read and starts being scanned
        # for one cell, which is a different control.
        MAX_COLUMNS = 7

        # The class names this half of the set emits, and the whole list of
        # them. The render-time spec holds every response to this.
        CLASSES = %w[
          rb-notice rb-notice--info rb-notice--success rb-notice--warning rb-notice--danger
          rb-notice--empty rb-notice-mark
          rb-table rb-table-scroll rb-table-actions rb-align-end
          rb-table-toolbar rb-table-filter-field rb-table-count
          rb-form rb-form--edit rb-form--filter rb-form--action rb-form-fields rb-form-body rb-form-actions rb-form-submit
          rb-field rb-field--short rb-field--medium rb-field--full rb-field-label
          rb-field-required rb-field-hint rb-field-control rb-field-options rb-field-option
          rb-button rb-button--primary rb-button--secondary rb-button--destructive rb-button--small
          rb-button--flat rb-button-mark
          rb-mapping-actions rb-mapping-preset
          rb-status rb-status--good rb-status--bad rb-status--warn rb-status--neutral
          rb-status--unknown rb-status-mark
          rb-tag rb-tags
          rb-kv rb-kv--inline rb-kv--stacked rb-kv-key rb-kv-value
          rb-stats rb-stat rb-stat-value rb-stat-label rb-stat-detail
          rb-chart rb-chart-title rb-chart-figure rb-chart-table
          rb-chart-svg rb-chart-label rb-chart-value rb-chart-tick
          rb-code rb-code--inline rb-code--block
          rb-prose rb-prose-toc
        ].freeze

        # The permission answer every Button spends. A surface that draws
        # Buttons answers this itself; there is no default, so nothing gets a
        # live button by having forgotten to have a permission model.
        def may?(_action, community:)
          raise NotImplementedError, "a surface drawing Buttons must answer may?(action, community:)"
        end

        # 3. Notice. An inline message: the flash, the empty state, the
        # explanatory lede, the one-off warning.
        #
        # @param text [String] the message
        # @param tone [Symbol] one of {NOTICE_TONES}
        def notice(text, tone: :info)
          check!(NOTICE_TONES, tone, "notice tone")
          mark = tone == :empty ? "" : %(<span class="rb-notice-mark" aria-hidden="true"></span>)
          %(<p class="rb-notice rb-notice--#{tone}"#{tone == :danger ? ' role="alert"' : ""}>) +
            "#{mark}#{Primitives.escape(text)}</p>"
        end

        # 4. Table. Columns and rows as data, with the empty state delegated
        # to Notice rather than written by hand.
        # @param columns [Array<Hash>] key:, header:, align: :start|:end,
        #   format: a {Format.value} name, tone: a {STATUS_TONES} key that
        #   draws the cell as a Status pill rather than bare text
        # @param rows [Array<Hash>] one hash per row, keyed by the column keys
        # @param empty [String] what to say when there are no rows
        # @param actions [Proc, nil] row to a run of Buttons, right-aligned
        def table(columns:, rows:, empty:, actions: nil)
          if columns.length + (actions ? 1 : 0) > MAX_COLUMNS
            raise ArgumentError, "a table draws at most #{MAX_COLUMNS} columns, asked for #{columns.length}"
          end
          return notice(empty, tone: :empty) if Array(rows).empty?

          head = columns.map { |column| table_header(column) }.join
          head += %(<th class="rb-align-end">Actions</th>) if actions
          rows = Array(rows)
          body = rows.map { |row| table_row(columns, row, actions) }.join
          table_toolbar(rows.length) +
            %(<div class="rb-table-scroll"><table class="rb-table"><thead><tr>#{head}</tr></thead>) +
            "<tbody>#{body}</tbody></table></div>"
        end

        # 5. Form. A group of Fields and one action footer, always last.
        # @param action, fields, submit, hidden [String, Hash] the post
        #   target, rendered Fields, rendered submit Button, and plumbing
        # @param body, actions [String, nil] named Sections for a longer
        #   task form, and optional secondary controls before the submit
        # @param validation [String, nil] what to show while pressing submit
        # @param variant [Symbol] one of {FORM_VARIANTS}
        # @param enctype [String, nil] "multipart/form-data" for a :file field
        def form(action:, submit:, fields: "", body: nil, actions: "", validation: nil, variant: :edit,
                 hidden: {}, enctype: nil)
          check!(FORM_VARIANTS, variant, "form variant")
          fields = yield if block_given?
          method = variant == :filter ? "get" : "post"
          plumbing = hidden.map do |name, value|
            %(<input type="hidden"#{Primitives.attributes(name: name, value: value)}>)
          end.join
          footer = form_footer(submit: submit, actions: actions, validation: validation)
          content = body.nil? ? %(<div class="rb-form-fields">#{fields}</div>) : %(<div class="rb-form-body">#{body}</div>)
          %(<form class="rb-form rb-form--#{variant}" method="#{method}") +
            %( action="#{Primitives.escape(action)}"#{Primitives.attributes(enctype: enctype)}>#{plumbing}) +
            content +
            "#{footer}</form>"
        end

        # 6. Field: one labelled control, the only way a control reaches a page.
        # @param name [String] the submitted name
        # @param label [String] shown above the control, sentence case
        # @param type, size one of {FIELD_TYPES} and {FIELD_SIZES}, from meaning
        # @param options [Array, Hash, nil] value/label pairs or bare tokens,
        #   humanised, for select, choice and checklist
        # @param hint [String, nil] help text, cut at {Format::HINT_LIMIT} unless +hint_wrap+
        # @param min, max, step a :number's scale, off the schema; see {#field_input}
        def field(name:, label:, type: :text, value: nil, size: :medium, options: nil,
                  hint: nil, hint_wrap: false, required: false, enabled: true,
                  min: nil, max: nil, step: nil)
          check!(FIELD_TYPES, type, "field type")
          check!(FIELD_SIZES, size, "field size")

          mark = required ? %(<span class="rb-field-required" title="Required">*</span>) : ""
          %(<div class="rb-field rb-field--#{size}">) +
            %(<label class="rb-field-label" for="#{Primitives.escape(field_id(name))}">) +
            "#{Primitives.escape(Format.label(label))}#{mark}</label>" +
            field_control(name, type, value, options, enabled, min: min, max: max, step: step) +
            field_hint(hint, hint_wrap) +
            "</div>"
        end

        # 7. Button: every one carries the grant it spends and the +community+
        # it is spent in ({Role::DEPLOYMENT} for a deployment-wide page), and
        # draws flat where the role may not press it.
        # @param action [Symbol, Array<Symbol>] the grant this button spends
        # @param variant [Symbol] one of {BUTTON_VARIANTS}; size, one of {BUTTON_SIZES}
        # @param to [String, nil] drawn as an anchor; +new_tab+ opens it apart
        # @param confirm [String, nil] required for :destructive
        # @param formaction [String, nil] a second submit target, for a Form's two routes
        def button(label, action:, community:, variant: :primary, size: :medium, to: nil, name: nil,
                   value: nil, enabled: true, confirm: nil, new_tab: false, formaction: nil)
          check!(BUTTON_VARIANTS, variant, "button variant")
          check!(BUTTON_SIZES, size, "button size")
          confirm = destructive_confirm(label, variant, confirm)
          permitted = Array(action).any? { |one| may?(one, community: community) }
          live = enabled && permitted
          shared = button_attributes(action, variant, size, live, permitted, confirm)
          body = button_body(label, variant)
          return anchor_button(to, shared, body, live, new_tab) if to

          "<button#{Primitives.attributes(type: "submit", name: name, value: value, formaction: formaction)}" \
            "#{shared}#{live ? "" : " disabled"}>#{body}</button>"
        end

        # 8. Status, whose helper is called +state+ because Sinatra already
        # owns +status+ on the response. A state pill whose tone comes from the
        # state rather than from the string, and which carries a mark so it
        # survives being read in one colour.
        #
        # @param text [String] the state, from a declared vocabulary
        # @param tone [Symbol] one of {STATUS_TONES}
        def state(text, tone: :unknown)
          check!(STATUS_TONES, tone, "status tone")
          %(<span class="rb-status rb-status--#{tone}">) +
            %(<span class="rb-status-mark" aria-hidden="true">#{STATUS_MARKS.fetch(tone)}</span>) +
            "#{Primitives.escape(text)}</span>"
        end

        # 9. Tag. A label that is not a state: a platform, a kind, a matched
        # word, a maturity marker.
        def tag(text) = %(<span class="rb-tag">#{Primitives.escape(text)}</span>)

        # A run of Tags, which is all a list of them is.
        def tags(values)
          list = Array(values)
          return "" if list.empty?

          %(<span class="rb-tags">#{list.map { |item| tag(item) }.join}</span>)
        end

        # 10. KeyValues. Label and formatted value pairs. Every value goes
        # through {Format}, which is where a raw second count dies.
        #
        # @param pairs [Array<Array>, Hash] label to value, or
        #   [label, value, format] triples
        # @param variant [Symbol] :inline for a cell or a header, :stacked for
        #   one pair per line
        def key_values(pairs, variant: :stacked)
          check!(%i[inline stacked], variant, "key values variant")
          rendered = normalise_pairs(pairs).map do |label, raw, as|
            %(<div class="rb-kv-key">#{Primitives.escape(Format.label(label))}</div>) +
              %(<div class="rb-kv-value">#{key_value_body(raw, as)}</div>)
          end.join
          return "" if rendered.empty?

          %(<div class="rb-kv rb-kv--#{variant}">#{rendered}</div>)
        end

        # 11. StatRow. The number, caption and optional detail grid.
        #
        # @param stats [Array<Array>] [value, caption, detail] triples. Detail
        #   is optional, so existing value and caption pairs draw unchanged.
        #   A value is a number or a formatted string; a Status is not a stat
        #   and raises.
        def stat_row(stats)
          cells = Array(stats).map do |value, caption, detail|
            raise ArgumentError, "a stat value is a number, not a control" if value.to_s.include?("<")

            %(<div class="rb-stat"><div class="rb-stat-value">#{Primitives.escape(value)}</div>) +
              %(<div class="rb-stat-label">#{Primitives.escape(caption)}</div>) +
              (detail.nil? || detail == "" ? "" : %(<div class="rb-stat-detail">#{Primitives.escape(detail)}</div>)) +
              %(</div>)
          end.join
          %(<div class="rb-stats">#{cells}</div>)
        end

        # 12. Chart. The server describes the data and its shape, never the
        # visual form, and the data table always ships alongside because the
        # figure is marked aria-hidden and carries no numbers a reader can
        # reach.
        #
        # @param rows [Array<Hash>] { label:, count: }
        # @param shape [Symbol] one of {CHART_SHAPES}
        def chart(rows, shape:, title: nil, empty: "Nothing yet.", limit: 10)
          check!(CHART_SHAPES, shape, "chart shape")
          data = Array(rows).map { |row| { label: row[:label].to_s, count: row[:count].to_i } }
          # A share is capped by its own rule rather than by limit, or the tail
          # would be dropped and every percentage drawn against the wrong total.
          data = shape == :share_of_total ? Primitives.ring_rows(data) : data.first(limit)
          return notice(empty, tone: :empty) if data.empty?

          id = "rb-chart-#{SecureRandom.hex(6)}"
          heading = title ? %(<figcaption class="rb-chart-title">#{Primitives.escape(title)}</figcaption>) : ""
          %(<figure class="rb-chart">#{heading}) +
            %(<div class="rb-chart-figure" id="#{id}" aria-hidden="true" data-shape="#{shape}") +
            %( data-chart="#{Primitives.escape(JSON.generate(data))}"></div>) +
            chart_table(data) + "</figure>"
        end

        # 13. Code. Read-only code, inline or as a block.
        def code(text, variant: :block)
          check!(%i[inline block], variant, "code variant")
          tag_name = variant == :inline ? "code" : "pre"
          %(<#{tag_name} class="rb-code rb-code--#{variant}">#{Primitives.escape(text)}</#{tag_name}>)
        end

        # 15. Prose: a rendered markdown document, drawn through the
        # swatch's typography (headings, links, tables, blockquotes, fenced
        # code) that none of the other fourteen can express. It names a
        # document rather than taking markup; {Prose} is where that
        # reasoning lives.
        #
        # @param document [Symbol] one of {Prose::DOCUMENTS}' keys
        # @param app_root [String, nil] the dashboard's mount prefix
        def prose(document:, app_root: nil)
          check!(Prose::DOCUMENTS.keys, document, "prose document")
          markup = Prose.markup(document, app_root: app_root)
          return notice(Prose.absent(document), tone: :empty) if markup.nil?

          verified = Prose.verified(markup)
          prose_toc(Prose.contents(verified)) + %(<div class="rb-prose">#{verified}</div>)
        end

        private

        # A document's own sections, listed once at its top, for the two
        # document screens long enough that scrolling was the only way to
        # find one. Drawn from headings a kramdown render already gave an
        # id, so nothing here invents an anchor of its own; a document with
        # one section or none gets no list, since a single link explains
        # nothing a heading does not already say.
        def prose_toc(sections)
          return "" if sections.length < 2

          items = sections.map { |section| %(<li><a href="##{section[:id]}">#{section[:text]}</a></li>) }.join
          %(<nav class="rb-prose-toc"><p>Contents</p><ul>#{items}</ul></nav>)
        end

        # The one action footer, and the order it always reads in: the
        # validation a reader needs while pressing the control, then the
        # subordinate controls, then the single primary submit, last.
        #
        # @param submit [String] the one primary Button
        # @param actions [String] subordinate controls, drawn before it
        # @param validation [String, nil] plain text, drawn as an info Notice
        def form_footer(submit:, actions: "", validation: nil)
          check_footer!(actions)
          note = validation.nil? ? "" : notice(validation, tone: :info)
          submit_row = %(<div class="rb-form-submit">#{submit}</div>)
          return submit_row if note.empty? && actions.to_s.empty?

          %(<div class="rb-form-actions">#{note}#{actions}#{submit_row}</div>)
        end

        # What a footer refuses. A second primary makes two controls look like
        # the way forward, and a destructive control sharing a footer with a
        # submit is one mis-click from the thing it cannot undo, which is why
        # it goes in its own action Form instead.
        def check_footer!(actions)
          text = actions.to_s
          raise ArgumentError, "a destructive control is its own action Form, not a footer action" if
            text.include?(%(data-destructive="true"))
          raise ArgumentError, "the submit is the footer's one primary action" if
            text.include?("rb-button--primary")
        end

        # Whether a destructive Button was given the confirm it requires.
        def destructive_confirm(label, variant, confirm)
          return confirm unless variant == :destructive

          confirm || "#{label}? This cannot be undone."
        end

        def button_attributes(action, variant, size, live, permitted, confirm)
          Primitives.attributes(
            class: "rb-button rb-button--#{variant}#{size == :small ? " rb-button--small" : ""}#{live ? "" : " rb-button--flat"}",
            "data-grant": Array(action).join(" "),
            # ARIA and data attributes carry a value; only an HTML boolean
            # attribute like disabled is written bare.
            "data-destructive": ("true" if variant == :destructive),
            "data-confirm": (confirm if variant == :destructive && live),
            "aria-disabled": ("true" unless live),
            title: ("Read only: you cannot change this here." unless permitted)
          )
        end

        # The destructive mark, which is what makes the variant readable with
        # no colour at all.
        def button_body(label, variant)
          mark = variant == :destructive ? %(<span class="rb-button-mark" aria-hidden="true">!</span>) : ""
          "#{mark}#{Primitives.escape(Format.label(label))}"
        end

        # A Button that navigates is the same Button, emitted as an anchor, and
        # loses its href rather than its shape when the role may not follow it.
        def anchor_button(destination, shared, body, live, new_tab = false)
          href = live ? %( href="#{Primitives.escape(destination)}") : ""
          window = new_tab && live ? %( target="_blank" rel="noopener") : ""
          %(<a#{href}#{window}#{shared}#{live ? "" : ' role="link"'}>#{body}</a>)
        end

        # A live filter over the rows already on the page, no request, plus the
        # count it keeps current as a reader narrows it: the affordance the
        # mockup draws above every list, missing from Table until now.
        def table_toolbar(count)
          %(<div class="rb-table-toolbar">) +
            %(<input class="rb-table-filter-field" type="search" data-table-filter autocomplete="off" ) +
            %(aria-label="Filter this list" placeholder="Filter this list">) +
            %(<span class="rb-table-count">#{count} item#{count == 1 ? "" : "s"}</span></div>)
        end

        def table_header(column)
          align = column[:align] == :end ? ' class="rb-align-end"' : ""
          %(<th#{align}>#{Primitives.escape(Format.label(column.fetch(:header)))}</th>)
        end

        def table_row(columns, row, actions)
          cells = columns.map { |column| table_cell(column, row) }.join
          if actions
            cells += %(<td class="rb-table-actions"#{Primitives.attributes("data-l": "Actions")}>) +
                     "#{actions.call(row)}</td>"
          end
          "<tr>#{cells}</tr>"
        end

        def table_cell(column, row)
          raw = row[column.fetch(:key)]
          text = Format.value(raw, as: column.fetch(:format, :text))
          align = column[:align] == :end ? ' class="rb-align-end"' : ""
          data = Primitives.attributes("data-l": Format.label(column.fetch(:header)), "data-format": column[:format])
          %(<td#{align}#{data}>#{cell_body(column, row, text)}</td>)
        end

        def cell_body(column, row, text)
          return code(text, variant: :inline) if column[:format] == :code
          return state(text, tone: row.fetch(column[:tone], :unknown)) if column[:tone]

          Primitives.escape(text)
        end

        # The accessible half of a Chart, and the floor every theme's backend
        # falls back to.
        def chart_table(data)
          rows = data.map do |row|
            %(<tr><th scope="row">#{Primitives.escape(row[:label])}</th>) +
              %(<td class="rb-align-end">#{Primitives.escape(row[:count])}</td></tr>)
          end.join
          %(<table class="rb-chart-table"><thead><tr><th>Label</th>) +
            %(<th class="rb-align-end">Count</th></tr></thead><tbody>#{rows}</tbody></table>)
        end

        def field_id(name) = "rb-field-#{name.to_s.gsub(/[^A-Za-z0-9_-]/, "-")}"

        # Longer than the display limit is cut with the whole of it kept on
        # hover, which is the fallback a table cell already carries. tabindex
        # reaches the same text on a tap, since touch never triggers hover.
        # +wrap+ is for a form with the room to read the whole of it instead.
        def field_hint(hint, wrap = false)
          return "" if hint.nil?

          text = hint.to_s
          whole = wrap || text.length <= Format::HINT_LIMIT
          return %(<p class="rb-field-hint">#{Primitives.escape(text)}</p>) if whole

          cut = Format.truncate(text, Format::HINT_LIMIT - 3)
          %(<p class="rb-field-hint" title="#{Primitives.escape(text)}" tabindex="0">#{Primitives.escape(cut)}</p>)
        end

        def field_control(name, type, value, options, enabled, min: nil, max: nil, step: nil)
          case type
          when :select, :toggle then field_select(name, type, value, options, enabled)
          when :multiline, :code then field_textarea(name, type, value, enabled)
          when :choice then field_group(name, "radio", value, options, enabled)
          when :checklist then field_group(name, "checkbox", value, options, enabled)
          else field_input(name, type, value, enabled, min: min, max: max, step: step)
          end
        end

        # The bounds ride only on a number, which is the one control they mean
        # anything to. A number with no step is stepped by 1 whatever it holds,
        # so a fractional value both walks off its own scale and reads as
        # invalid to the browser.
        def field_input(name, type, value, enabled, min: nil, max: nil, step: nil)
          kind = { text: "text", number: "number", secret: "password", file: "file" }.fetch(type)
          bounds = type == :number ? { min: min, max: max, step: step } : {}
          # A file input's value comes from what the user picks, never from
          # the server; browsers ignore a `value` attribute on one anyway.
          "<input#{Primitives.attributes(
            class: "rb-field-control", type: kind, id: field_id(name), name: name,
            value: (value unless type == :file), **bounds, disabled: (true unless enabled)
          )}>"
        end

        def field_select(name, type, value, options, enabled)
          pairs = type == :toggle ? TOGGLE_OPTIONS : normalise_options(options)
          items = pairs.map do |option, label|
            selected = option.to_s == value.to_s ? " selected" : ""
            %(<option value="#{Primitives.escape(option)}"#{selected}>#{Primitives.escape(label)}</option>)
          end.join
          "<select#{Primitives.attributes(
            class: "rb-field-control", id: field_id(name), name: name, disabled: (true unless enabled)
          )}>#{items}</select>"
        end

        def field_textarea(name, type, value, enabled)
          "<textarea#{Primitives.attributes(
            class: "rb-field-control", id: field_id(name), name: name,
            spellcheck: (false if type == :code), disabled: (true unless enabled)
          )}>#{Primitives.escape(value)}</textarea>"
        end

        def field_group(name, kind, value, options, enabled)
          chosen = Array(value).map(&:to_s)
          items = normalise_options(options).map.with_index do |(option, label), index|
            id = "#{field_id(name)}-#{index}"
            %(<label class="rb-field-option" for="#{id}">) +
              "<input#{Primitives.attributes(
                type: kind, id: id, name: kind == "checkbox" ? "#{name}[]" : name, value: option,
                checked: (true if chosen.include?(option.to_s)), disabled: (true unless enabled)
              )}>#{Primitives.escape(label)}</label>"
          end.join
          %(<div class="rb-field-options" role="group">#{items}</div>)
        end

        # Options as value/label pairs, humanising a bare token so no select
        # ever shows one.
        def normalise_options(options)
          case options
          when Hash then options.map { |option, label| [option, label] }
          when Array
            options.map { |entry| entry.is_a?(Array) ? entry : [entry, Format.enum_label(entry)] }
          else raise ArgumentError, "this control needs options"
          end
        end

        def normalise_pairs(pairs)
          source = pairs.is_a?(Hash) ? pairs.to_a : Array(pairs)
          source.map do |entry|
            label, raw, as = entry
            [label, raw, as || :text]
          end
        end

        # A list value reads as Tags; everything else is formatted text.
        def key_value_body(raw, as)
          return tags(Format.durations(raw)) if as == :durations
          return tags(raw.map { |item| Format.value(item, as: as) }) if raw.is_a?(Array)

          Primitives.escape(Format.value(raw, as: as))
        end

        def check!(allowed, given, what)
          return if allowed.include?(given)

          raise ArgumentError, "unknown #{what} #{given.inspect}, expected one of #{allowed.join(", ")}"
        end
      end

      # What a theme contributes as arrangement: the navigation model and the
      # shape of a page. The guest portal is one chat view rather than 47 dense
      # config screens, so it consumes none of this and its own shell stands in.
      module Layout
        # The page frame's two variants. Wide is the scripting reference alone.
        PAGE_VARIANTS = %i[default wide].freeze

        # A Section is titled and boxed, plain and boxed for a single form, or
        # collapsible for the detail nobody opens by default.
        SECTION_VARIANTS = %i[default plain collapsible].freeze

        # A collapsible Section's own disclosure marker, which side it draws
        # on: the default reads chevron-then-heading, and a summary that is
        # itself a row of controls (a switch, a title, a chevron of its own
        # on the far side) wants the marker last instead. A data attribute
        # rather than a second class, so a theme still styles this off the
        # one rb-section--collapsible rule.
        SECTION_CHEVRON_SIDES = %i[start end].freeze

        CLASSES = %w[
          rb-page rb-page--default rb-page--wide rb-page-title rb-page-lede rb-page-body
          rb-page-header rb-page-actions
          rb-section rb-section--default rb-section--plain rb-section--collapsible
          rb-section-title rb-section-body rb-actions-row
          rb-tabs rb-tab rb-tab--current
        ].freeze

        # 1. Page. The outer frame: one h1, the lede, then the sections. The
        # title names the object and the page's job goes in the lede.
        #
        # @param title [String] the object this page is about
        # @param lede [String, nil] one paragraph on what the page does
        # @param actions [String, nil] a screen's own right-aligned controls, next to the title
        # @param sections [String] the rendered Sections
        # @param variant [Symbol] one of {PAGE_VARIANTS}
        def page(title:, sections: "", lede: nil, actions: nil, variant: :default)
          unless PAGE_VARIANTS.include?(variant)
            raise ArgumentError, "unknown page variant #{variant.inspect}"
          end

          sections = yield if block_given?
          intro = lede ? %(<p class="rb-page-lede">#{Primitives.escape(lede)}</p>) : ""
          title_h1 = %(<h1 class="rb-page-title">#{Primitives.escape(title)}</h1>)
          header = actions ? %(<div class="rb-page-header">#{title_h1}<div class="rb-page-actions">#{actions}</div></div>) : title_h1
          %(<div class="rb-page rb-page--#{variant}">) +
            %(#{header}#{intro}) +
            %(<div class="rb-page-body">#{sections}</div></div>)
        end

        # 2. Section. A titled block, and the only heading level inside a page.
        # A screen that needs a third level is two screens.
        #
        # @param title [String, nil] a noun, sentence case, no trailing stop
        # @param body [String] the rendered content
        # @param variant [Symbol] one of {SECTION_VARIANTS}
        # @param summary [String, nil] collapsible only; trusted markup, not
        #   escaped, so a disclosure's own heading can be more than a string
        def section(title: nil, body: "", variant: :default, open: false, summary: nil, chevron: :start)
          unless SECTION_VARIANTS.include?(variant)
            raise ArgumentError, "unknown section variant #{variant.inspect}"
          end
          unless SECTION_CHEVRON_SIDES.include?(chevron)
            raise ArgumentError, "unknown section chevron side #{chevron.inspect}"
          end
          raise ArgumentError, "a titled Section is what a title is for" if title.nil? && variant == :default

          body = yield if block_given?
          return collapsible_section(title, body, open, summary, chevron) if variant == :collapsible

          heading = title ? %(<h2 class="rb-section-title">#{Primitives.escape(title)}</h2>) : ""
          %(<section class="rb-section rb-section--#{variant}">#{heading}) +
            %(<div class="rb-section-body">#{body}</div></section>)
        end

        # 14. TabLinks. An in-page filter expressed as links, which is one
        # control rather than the two identical helpers it replaces.
        #
        # @param links [Array<Array>] [href, label, key] triples
        # @param current [Object] the key that is showing
        def tab_links(links, current:)
          items = Array(links).map do |href, label, key|
            marker = key.to_s == current.to_s
            %(<a class="rb-tab#{marker ? " rb-tab--current" : ""}" href="#{Primitives.escape(href)}") +
              %(#{marker ? ' aria-current="page"' : ""}>#{Primitives.escape(label)}</a>)
          end.join
          %(<nav class="rb-tabs">#{items}</nav>)
        end

        private

        def collapsible_section(title, body, open, summary, chevron)
          head = summary || Primitives.escape(title)
          %(<details class="rb-section rb-section--collapsible" data-chevron="#{chevron}"#{open ? " open" : ""}>) +
            %(<summary class="rb-section-title">#{head}</summary>) +
            %(<div class="rb-section-body">#{body}</div></details>)
        end
      end

      # The chrome around a page: navigation, brand, breadcrumbs, the scope
      # switcher, the identity block, and the region a page draws inside.
      # No emitter here: a theme draws this region itself, since the four
      # themes differ structurally (sidebar, window title bar, rail,
      # dropdown menus), not just by colour. What's shared is the
      # vocabulary of PIECES, not their arrangement: a theme nests them
      # however its design needs but may not invent a fifteenth, since a
      # piece nothing else can style is chrome no other theme can match.
      module Shell
        ROLES = %i[root brand scope nav crumbs identity search content].freeze

        # The one slot every theme owes: the element the page itself is moved
        # into once the chrome is drawn.
        CONTENT_SLOT = "rb-shell-content"

        CLASSES = %w[
          rb-shell rb-shell--open rb-shell-backdrop rb-shell-side rb-shell-main
          rb-shell-topbar rb-shell-topbar-start rb-shell-topbar-end
          rb-shell-brand rb-shell-brand-name rb-shell-brand-meta rb-shell-drift
          rb-shell-scopes rb-shell-scope rb-shell-scope--current
          rb-shell-workspace rb-shell-workspace-button rb-shell-workspace-name rb-shell-workspace-meta
          rb-shell-menu rb-shell-menu--open rb-shell-menu-label rb-shell-menu-item rb-shell-menu-item--current
          rb-shell-nav rb-shell-group rb-shell-group--collapsed rb-shell-group-head
          rb-shell-group-label rb-shell-list
          rb-shell-link rb-shell-link--current rb-shell-badge rb-shell-count
          rb-shell-identity rb-shell-identity-name rb-shell-identity-role rb-shell-avatar
          rb-shell-dot rb-shell-dot--live rb-shell-dot--off
          rb-shell-crumbs rb-shell-crumb rb-shell-crumb--current rb-shell-crumb-sep
          rb-shell-search rb-shell-search-field rb-shell-icon rb-shell-icon-button
          rb-shell-toggle rb-shell-content rb-shell-footer rb-shell-status
          rb-shell-stats rb-shell-stat
        ]

        # A master-detail chrome's list pane: the current view's own
        # collection, drawn beside the nav rather than inside it, named apart
        # from rb-shell-list, which Series A's nav group already holds. Not
        # every theme draws one, the same latitude rb-shell-side already gets.
        LIST_PANE = %w[
          rb-shell-pane rb-shell-pane-head rb-shell-pane-title rb-shell-pane-count
          rb-shell-pane-empty rb-shell-filter rb-shell-filter-field
          rb-shell-rows rb-shell-row
          rb-shell-row-dot rb-shell-row-dot--good rb-shell-row-dot--warn
          rb-shell-row-dot--bad rb-shell-row-dot--neutral
          rb-shell-row-title rb-shell-row-sub rb-shell-row-meta
        ].freeze

        CLASSES.concat(LIST_PANE).freeze
      end

      # Every class name any primitive emits, plus the shell vocabulary a theme
      # draws its own chrome from. This is what a rendered response is held to
      # and what a stylesheet has to carry a rule for.
      CLASSES = (Identity::CLASSES + Layout::CLASSES + Shell::CLASSES).sort.freeze

      # The fifteen, each mapped to the helper that draws it, so the count is
      # written down in one place rather than counted off a file. Status is the
      # one whose helper carries a different name, since Sinatra owns +status+.
      NAMES = {
        Page: :page, Section: :section, Notice: :notice, Table: :table, Form: :form,
        Field: :field, Button: :button, Status: :state, Tag: :tag, KeyValues: :key_values,
        StatRow: :stat_row, Chart: :chart, Code: :code, TabLinks: :tab_links, Prose: :prose
      }.freeze
    end
  end
end
