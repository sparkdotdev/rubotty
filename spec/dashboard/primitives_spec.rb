# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"

# The primitives themselves: the two properties that have to hold structurally
# rather than by convention, and the shape of the fifteen.
RSpec.describe Rubotty::Dashboard::Primitives do
  # A surface that draws everything, with a permission model of its own.
  def surface(granted: %i[manage_rooms], layout: true)
    Class.new do
      include Rubotty::Dashboard::Primitives::Identity
      include Rubotty::Dashboard::Primitives::Layout if layout

      define_method(:allowed) { granted }
      def may?(action, community:) = allowed.include?(action)
    end.new
  end

  # A surface with no permission model at all, which is what a new page written
  # without thinking about the gate would be.
  def ungoverned
    Class.new { include Rubotty::Dashboard::Primitives::Identity }.new
  end

  describe "the permission gate" do
    it "will not draw a button without naming the grant it spends" do
      expect { surface.button("Delete", community: :a_community) }.to raise_error(ArgumentError, /action/)
    end

    # A grant and the community it is spent in are one answer rather than two:
    # a control drawn live is a control an operator will press.
    it "will not draw a button without naming the community it is spent against" do
      expect { surface.button("Delete", action: :manage_rooms) }.to raise_error(ArgumentError, /community/)
    end

    it "says on the element which grant it spent, so a raw one is findable" do
      expect(surface.button("Save", action: :manage_rooms, community: :a_community)).to include('data-grant="manage_rooms"')
    end

    it "draws flat, disabled and explained when the role may not press it" do
      drawn = surface.button("Save", action: :moderate_user, community: :a_community)

      expect(drawn).to include("rb-button--flat")
      expect(drawn).to include(" disabled")
      expect(drawn).to include('aria-disabled="true"')
      expect(drawn).to include("Read only: you cannot change this here.")
    end

    it "refuses to answer the question at all on a surface that has no answer" do
      expect { ungoverned.button("Save", action: :manage_rooms, community: :a_community) }
        .to raise_error(NotImplementedError, /may\?/)
    end

    it "keeps a navigating button the same control, emitted as an anchor" do
      live = surface.button("Config", action: :manage_rooms, community: :a_community, to: "/rooms")
      flat = surface.button("Config", action: :moderate_user, community: :a_community, to: "/rooms")

      expect(live).to start_with("<a")
      expect(live).to include('href="/rooms"')
      expect(live).to include("rb-button rb-button--primary")
      expect(flat).not_to include("href=")
      expect(flat).to include("rb-button--flat")
    end

    it "spends any one of several grants where the route authorises the one picked" do
      drawn = surface.button("Set", action: %i[moderate_user manage_rooms], community: :a_community)

      expect(drawn).to include('data-grant="moderate_user manage_rooms"')
      expect(drawn).not_to include("rb-button--flat")
    end
  end

  # Under the Ruby swatch accent-primary and danger are the same red, so a
  # destructive control that signals with hue signals nothing. WCAG asks for
  # this anyway.
  describe "a destructive button" do
    let(:drawn) { surface.button("Delete room", action: :manage_rooms, community: :a_community, variant: :destructive) }

    it "carries a mark of its own, which no other variant has" do
      expect(drawn).to include('class="rb-button-mark" aria-hidden="true">!')
      expect(surface.button("Save", action: :manage_rooms, community: :a_community)).not_to include("rb-button-mark")
    end

    it "says outright that it is destructive, for anything reading the markup" do
      expect(drawn).to include('data-destructive="true"')
    end

    it "asks before it fires, which the other two variants never do" do
      expect(drawn).to include("data-confirm=")
      expect(surface.button("Save", action: :manage_rooms, community: :a_community)).not_to include("data-confirm")
    end

    it "takes the caller's wording for the confirm when there is one" do
      asked = surface.button("Delete room", action: :manage_rooms, community: :a_community, variant: :destructive,
                                            confirm: "Deleting a room unmaps its channels. Go on?")

      expect(asked).to include("Deleting a room unmaps its channels. Go on?")
    end

    it "differs from primary in more than one way at once" do
      primary = surface.button("Delete room", action: :manage_rooms, community: :a_community)

      # Shape, marking and interaction, so a reader who cannot tell the two reds
      # apart still can.
      expect(drawn).not_to eq(primary)
      %w[rb-button--destructive rb-button-mark data-destructive data-confirm].each do |signal|
        expect(drawn).to include(signal)
        expect(primary).not_to include(signal)
      end
    end

    it "does not offer a confirm on a button nobody may press" do
      expect(surface.button("Delete", action: :moderate_user, community: :a_community, variant: :destructive))
        .not_to include("data-confirm")
    end
  end

  describe "a small button" do
    it "draws the dense control class without changing its variant or grant" do
      drawn = surface.button("Enable", action: :manage_rooms, community: :a_community, variant: :secondary, size: :small)

      expect(drawn).to include("rb-button--secondary rb-button--small")
      expect(drawn).to include('data-grant="manage_rooms"')
    end

    it "keeps a small navigating button as an anchor" do
      drawn = surface.button("Open", action: :manage_rooms, community: :a_community, size: :small, to: "/rooms")

      expect(drawn).to start_with("<a")
      expect(drawn).to include("rb-button--small")
    end

    it "refuses a measurement instead of a declared control size" do
      expect { surface.button("Save", action: :manage_rooms, community: :a_community, size: :"24px") }
        .to raise_error(ArgumentError, /button size/)
    end
  end

  # A second submit target for the one form Save and Test connection share,
  # so a connection is tried exactly as typed rather than only what is saved.
  describe "a button with a second target" do
    it "carries formaction rather than posting back to its form's own action" do
      drawn = surface.button("Test connection", action: :manage_rooms, community: :a_community, formaction: "/integrations/openarc/test")

      expect(drawn).to include('formaction="/integrations/openarc/test"')
      expect(drawn).to start_with("<button")
    end

    it "leaves an ordinary button with no formaction at all" do
      expect(surface.button("Save", action: :manage_rooms, community: :a_community)).not_to include("formaction")
    end

    it "still spends its own grant and nothing about the navigating shape changes" do
      drawn = surface.button("Test connection", action: :moderate_user, community: :a_community, formaction: "/integrations/openarc/test")

      expect(drawn).to include(" disabled")
      expect(drawn).to include("rb-button--flat")
    end
  end

  describe "the identity and layout split" do
    it "gives the guest surface identity and no navigation model at all" do
      guest = ungoverned

      expect(guest).to respond_to(:notice, :field, :tag, :code)
      expect(guest).not_to respond_to(:page)
      expect(guest).not_to respond_to(:section)
      expect(guest).not_to respond_to(:tab_links)
    end

    it "splits the fifteen with nothing in both halves" do
      identity = described_class::Identity.public_instance_methods(false)
      layout = described_class::Layout.public_instance_methods(false)

      expect(identity & layout).to be_empty
      expect(layout).to match_array(%i[page section tab_links])
    end

    it "declares a class list per half, and the whole set is their sum plus the shell" do
      expect(described_class::CLASSES)
        .to match_array(described_class::Identity::CLASSES + described_class::Layout::CLASSES +
                        described_class::Shell::CLASSES)
      expect(described_class::CLASSES.uniq.length).to eq(described_class::CLASSES.length)
    end

    # The shell has no emitter here on purpose: a theme draws its own chrome,
    # because the four differ structurally rather than by colour. What is held
    # in common is the vocabulary of pieces, so it is declared here and nowhere
    # in the fifteen.
    it "declares the shell vocabulary without adding a sixteenth primitive" do
      expect(described_class::NAMES.length).to eq(15)
      expect(described_class::Shell::CLASSES).to all(start_with("rb-shell"))
      expect(described_class::Shell::CLASSES).to include(described_class::Shell::CONTENT_SLOT)
      expect(described_class::Shell).not_to respond_to(:shell)
    end
  end

  describe "Notice" do
    it "draws exactly five tones and refuses a sixth" do
      described_class::Identity::NOTICE_TONES.each do |tone|
        expect(surface.notice("x", tone: tone)).to include("rb-notice--#{tone}")
      end
      expect { surface.notice("x", tone: :neutral) }.to raise_error(ArgumentError, /notice tone/)
    end

    it "keeps an empty state from looking like an explanation" do
      expect(surface.notice("Nothing here.", tone: :empty)).not_to include("rb-notice-mark")
      expect(surface.notice("What this page does.", tone: :info)).to include("rb-notice-mark")
    end
  end

  describe "Status" do
    it "gives every tone a mark, so a state survives being read in one colour" do
      marks = described_class::Identity::STATUS_TONES.map do |tone|
        surface.state("x", tone: tone)[/rb-status-mark" aria-hidden="true">([^<]*)</, 1]
      end

      expect(marks.uniq.length).to eq(described_class::Identity::STATUS_TONES.length)
    end

    it "refuses a tone outside the five" do
      expect { surface.state("x", tone: :discovered) }.to raise_error(ArgumentError, /status tone/)
    end
  end

  describe "Form" do
    it "draws all three variants and nothing else" do
      described_class::Identity::FORM_VARIANTS.each do |variant|
        drawn = surface.form(action: "/x", submit: "Go", variant: variant)

        expect(drawn).to include(%(rb-form rb-form--#{variant}))
      end
      expect { surface.form(action: "/x", submit: "Go", variant: :bogus) }
        .to raise_error(ArgumentError, /form variant/)
    end

    it "posts an edit or action form, and only a filter gets" do
      expect(surface.form(action: "/x", submit: "Go", variant: :edit)).to include(%(method="post"))
      expect(surface.form(action: "/x", submit: "Go", variant: :action)).to include(%(method="post"))
      expect(surface.form(action: "/x", submit: "Go", variant: :filter)).to include(%(method="get"))
    end

    it "puts optional secondary controls and the submit in one action footer" do
      drawn = surface.form(action: "/x", fields: "Fields", actions: "Cancel", submit: "Save")

      expect(drawn).to include('<div class="rb-form-actions">Cancel<div class="rb-form-submit">Save</div></div>')
    end

    it "keeps a one-button form's existing submit row" do
      drawn = surface.form(action: "/x", submit: "Save")

      expect(drawn).not_to include("rb-form-actions")
      expect(drawn).to include('<div class="rb-form-submit">Save</div>')
    end

    it "uses named Sections as one task form body without changing ordinary field forms" do
      drawn = surface.form(action: "/x", body: "<section>Target</section>", submit: "Save")

      expect(drawn).to include('<div class="rb-form-body"><section>Target</section></div>')
      expect(drawn).not_to include("rb-form-fields")
    end

    it "draws the validation first in the footer, so it is crossed on the way to the submit" do
      drawn = surface.form(action: "/x", validation: "Name is required.", actions: "Cancel", submit: "Save")
      footer = drawn[%r{<div class="rb-form-actions">.*</div></form>}m]

      expect(footer).to include("Name is required.")
      expect(footer.index("rb-notice")).to be < footer.index("Cancel")
      expect(footer.index("Cancel")).to be < footer.index("rb-form-submit")
    end

    it "opens the footer row for validation alone, with no secondary control beside it" do
      drawn = surface.form(action: "/x", validation: "Nothing here is cleared on save.", submit: "Save")

      expect(drawn).to include("rb-form-actions")
      expect(drawn).to include("rb-notice--info")
    end

    it "keeps a plain submit row when there is neither validation nor a secondary control" do
      drawn = surface.form(action: "/x", submit: "Save")

      expect(drawn).not_to include("rb-form-actions")
      expect(drawn).not_to include("rb-notice")
    end

    it "refuses a destructive control in the footer, which belongs in its own action Form" do
      remove = surface.button("Remove", action: :manage_platforms, community: :a_community, variant: :destructive)

      expect { surface.form(action: "/x", actions: remove, submit: "Save") }
        .to raise_error(ArgumentError, /its own action Form/)
    end

    it "refuses a second primary, so one control is the way forward" do
      another = surface.button("Save and enable", action: :manage_scripts, community: :a_community)

      expect { surface.form(action: "/x", actions: another, submit: "Save") }
        .to raise_error(ArgumentError, /one primary action/)
    end
  end

  describe "StatRow" do
    it "draws an optional detail below a stat's value and label" do
      drawn = surface.stat_row([[18, "endpoints", "2 this week"]])

      expect(drawn).to include(
        '<div class="rb-stat-value">18</div><div class="rb-stat-label">endpoints</div>' \
        '<div class="rb-stat-detail">2 this week</div>'
      )
    end

    it "keeps an existing value and label pair at two lines" do
      drawn = surface.stat_row([[18, "endpoints"]])

      expect(drawn).to eq(
        '<div class="rb-stats"><div class="rb-stat"><div class="rb-stat-value">18</div>' \
        '<div class="rb-stat-label">endpoints</div></div></div>'
      )
    end
  end

  describe "Field" do
    it "draws all nine control types and nothing else" do
      described_class::Identity::FIELD_TYPES.each do |type|
        options = %i[select choice checklist].include?(type) ? %w[one two] : nil
        drawn = surface.field(name: "x", label: "Something", type: type, options: options)

        expect(drawn).to include("rb-field-control").or include("rb-field-options")
      end
      expect { surface.field(name: "x", label: "X", type: :colourpicker) }
        .to raise_error(ArgumentError, /field type/)
    end

    it "takes its width from what the field means, in three steps" do
      described_class::Identity::FIELD_SIZES.each do |size|
        expect(surface.field(name: "x", label: "X", size: size)).to include("rb-field--#{size}")
      end
      expect { surface.field(name: "x", label: "X", size: :"215px") }
        .to raise_error(ArgumentError, /field size/)
    end

    # A number with no step is stepped by 1 whatever it holds, which walked a
    # confidence of 0.8 down to -0.2 and made 0.8 itself read as invalid.
    it "carries the bounds a number was given" do
      drawn = surface.field(name: "minimum_confidence", label: "Minimum confidence", type: :number,
                            value: "0.8", min: 0.0, max: 1.0, step: 0.05)

      expect(drawn).to include(%(min="0.0"), %(max="1.0"), %(step="0.05"))
    end

    it "leaves a number nobody bounded exactly as it was" do
      drawn = surface.field(name: "limit", label: "Lines", type: :number, value: "200")

      expect(drawn).not_to include("min=", "max=", "step=")
    end

    # They mean nothing to a text box, and writing them onto one would be a
    # promise the control cannot keep.
    it "never puts bounds on a control that is not a number" do
      drawn = surface.field(name: "who", label: "Who", type: :text, value: "ada",
                            min: 0.0, max: 1.0, step: 0.05)

      expect(drawn).not_to include("min=", "max=", "step=")
    end

    it "marks required and leaves optional unmarked, which is one convention" do
      expect(surface.field(name: "x", label: "X", required: true)).to include("rb-field-required")
      expect(surface.field(name: "x", label: "X")).not_to include("rb-field-required")
    end

    it "renders a boolean as a select, since a checkbox submits nothing when unticked" do
      expect(surface.field(name: "on", label: "On", type: :toggle)).to include("<select")
    end
  end

  describe "Page and Section" do
    it "draws one h1 and puts the page's job in the lede" do
      drawn = surface.page(title: "Rooms", lede: "What a room is for.")

      expect(drawn.scan("<h1").length).to eq(1)
      expect(drawn).to include("rb-page-lede")
    end

    it "offers one heading level inside a page" do
      drawn = surface.section(title: "Operators", body: "x")

      expect(drawn).to include("<h2")
      expect(drawn).not_to include("<h3")
    end

    it "will not draw a default Section with no title" do
      expect { surface.section(body: "x") }.to raise_error(ArgumentError, /title/)
      expect(surface.section(body: "x", variant: :plain)).to include("rb-section--plain")
    end

    # A collapsible Section's summary is escaped text by default, the same as
    # every other title, but takes trusted markup instead when the disclosure
    # itself is a row of controls rather than a string (Features: a toggle
    # switch and a description beside the name).
    describe "a collapsible Section's own summary" do
      it "escapes a plain title the same as any other Section" do
        drawn = surface.section(title: "<b>hi</b>", body: "x", variant: :collapsible)

        expect(drawn).to include("&lt;b&gt;hi&lt;/b&gt;")
        expect(drawn).not_to include("<b>hi</b>")
      end

      it "draws trusted markup in place of the escaped title when summary is given" do
        drawn = surface.section(title: "ignored", body: "x", variant: :collapsible,
                                summary: '<span data-x="1">rich</span>')

        expect(drawn).to include('<summary class="rb-section-title"><span data-x="1">rich</span></summary>')
      end

      it "reads the disclosure marker at the start by default and at the end when asked" do
        leading = surface.section(title: "Help", body: "x", variant: :collapsible)
        trailing = surface.section(title: "Help", body: "x", variant: :collapsible, chevron: :end)

        expect(leading).to include('data-chevron="start"')
        expect(trailing).to include('data-chevron="end"')
      end

      it "refuses an unknown chevron side" do
        expect { surface.section(title: "Help", body: "x", variant: :collapsible, chevron: :middle) }
          .to raise_error(ArgumentError, /chevron/)
      end
    end
  end

  describe "Table and Chart" do
    it "puts the actions column last and to the right" do
      drawn = surface.table(columns: [{ key: :a, header: "A" }], rows: [{ a: "1" }],
                            empty: "Nothing.", actions: ->(_) { "act" })

      expect(drawn).to include('<th class="rb-align-end">Actions</th>')
      expect(drawn.index("rb-table-actions")).to be > drawn.index('<td data-l="A">1</td>')
    end

    # A column of states draws the Status pill rather than the bare word, and
    # the tone travels as data on the row beside the value: the surface that
    # counted is the only one that knows whether "Loud, DMed 2" went well.
    it "draws a column declaring a tone as a Status pill, toned from the row" do
      columns = [{ key: :how, header: "How", tone: :how_tone }]
      rows = [{ how: "Loud, DMed 2", how_tone: :good }, { how: "Quiet", how_tone: :neutral }]
      drawn = surface.table(columns: columns, rows: rows, empty: "Nothing.")

      expect(drawn).to include(%(<td data-l="How"><span class="rb-status rb-status--good">))
      expect(drawn).to include(%(<td data-l="How"><span class="rb-status rb-status--neutral">))
      expect(drawn).to include("Loud, DMed 2</span></td>")
      expect(drawn).not_to include('<td data-l="How">Quiet</td>')
    end

    it "leaves a column with no tone as the plain text it was" do
      drawn = surface.table(columns: [{ key: :how, header: "How" }], rows: [{ how: "Quiet" }], empty: "Nothing.")

      expect(drawn).to include('<td data-l="How">Quiet</td>')
      expect(drawn).not_to include("rb-status")
    end

    # The label lets a stylesheet build a phone card layout, one column per
    # line with its own heading; a theme had no way to do this before.
    it "carries its column's label on every cell, so a stylesheet can draw one per row on a phone" do
      columns = [{ key: :a, header: "Room name" }, { key: :b, header: "Message count" }]
      drawn = surface.table(columns: columns, rows: [{ a: "general", b: "12" }], empty: "Nothing.")

      expect(drawn).to include('<td data-l="Room name">general</td>')
      expect(drawn).to include('<td data-l="Message count">12</td>')
    end

    it "carries its column's format on the cell too, so a stylesheet can target it directly" do
      columns = [{ key: :seen, header: "Last seen", format: :relative }, { key: :name, header: "Name" }]
      drawn = surface.table(columns: columns, rows: [{ seen: Time.now, name: "x" }], empty: "Nothing.")

      expect(drawn).to include('data-l="Last seen" data-format="relative"')
      expect(drawn).to include('<td data-l="Name">x</td>')
    end

    it "leaves data-format off a column that names no format at all" do
      drawn = surface.table(columns: [{ key: :name, header: "Name" }], rows: [{ name: "x" }], empty: "Nothing.")

      expect(drawn).not_to include("data-format")
    end

    it "labels the actions cell the same way the actions header reads" do
      drawn = surface.table(columns: [{ key: :a, header: "A" }], rows: [{ a: "1" }],
                            empty: "Nothing.", actions: ->(_) { "act" })

      expect(drawn).to include('<td class="rb-table-actions" data-l="Actions">')
    end

    it "names a data shape rather than a visual form, and always ships the table" do
      drawn = surface.chart([{ label: "a", count: 2 }], shape: :categorical_distribution)

      expect(drawn).to include('data-shape="categorical_distribution"')
      expect(drawn).to include("rb-chart-table")
      expect(drawn).to include('aria-hidden="true"')
      expect { surface.chart([], shape: :pie) }.to raise_error(ArgumentError, /chart shape/)
    end
  end

  describe "escaping" do
    it "escapes everything it interpolates, in every primitive that takes text" do
      nasty = %(<script>alert("x")</script>)

      expect(surface.notice(nasty)).not_to include("<script>")
      expect(surface.tag(nasty)).not_to include("<script>")
      expect(surface.state(nasty)).not_to include("<script>")
      expect(surface.code(nasty)).not_to include("<script>")
      expect(surface.button(nasty, action: :manage_rooms, community: :a_community)).not_to include("<script>")
      expect(surface.page(title: nasty)).not_to include("<script>")
    end
  end

  # The one primitive that emits markup it did not escape, so the two things
  # standing between it and an injection are both checked here: it takes no
  # markup argument to fill, and it holds what it resolves to a closed set of
  # elements and attributes.
  describe "Prose" do
    let(:documents) do
      documents = %i[readme licence]
      documents << :scripting if File.exist?(Rubotty::Dashboard::ReadmeRenderer.scripting_path)
      documents
    end

    it "takes a document name and no markup at all, so nothing can hand it a string" do
      expect(described_class::Identity.instance_method(:prose).parameters.map(&:last))
        .to match_array(%i[document app_root])
    end

    it "draws every shipped document through the one wrapper" do
      documents.each do |document|
        drawn = surface.prose(document: document)

        expect(drawn).to include(%(<div class="rb-prose">))
        expect(drawn.length).to be > 1000
      end
    end

    it "refuses a document outside the three" do
      expect { surface.prose(document: :secrets) }.to raise_error(ArgumentError, /prose document/)
    end

    # A real render of every shipped document, rather than a sample: the scan
    # below is only worth having if the documents this repo actually ships
    # pass it, and a build whose licence grew a raw <div> should fail here
    # instead of on somebody's screen.
    it "passes every shipped document through its own scan" do
      documents.each do |document|
        markup = Rubotty::Dashboard::Primitives::Prose.markup(document)

        expect { Rubotty::Dashboard::Primitives::Prose.verified(markup) }.not_to raise_error
      end
    end

    # Shipped documents have enough level-2 headings for a contents list.
    it "draws a contents list ahead of the document, linking each of its own sections" do
      documents.each do |document|
        drawn = surface.prose(document: document)
        sections = Rubotty::Dashboard::Primitives::Prose.contents(
          Rubotty::Dashboard::Primitives::Prose.markup(document)
        )

        expect(drawn.index(%(<nav class="rb-prose-toc">))).to be < drawn.index(%(<div class="rb-prose">))
        sections.each { |section| expect(drawn).to include(%(href="##{section[:id]}")) }
      end
    end

    it "draws no contents list for a document with fewer than two sections" do
      allow(Rubotty::Dashboard::Primitives::Prose).to receive(:markup).and_return("<h2 id=\"a\">A</h2><p>x</p>")

      expect(surface.prose(document: :readme)).not_to include("rb-prose-toc")
    end

    it "says so quietly when a build does not ship the file" do
      allow(Rubotty::Dashboard::Primitives::Prose).to receive(:markup).and_return(nil)

      expect(surface.prose(document: :readme)).to include("rb-notice--empty")
    end

    {
      "a script tag" => "<p>hi</p><script>alert(1)</script>",
      "an inline style" => %(<p style="color: red">x</p>),
      "a javascript: link" => %(<a href="javascript:alert(1)">x</a>),
      "an event handler smuggled past a value's own quote" => %(<a title="x>" onclick="steal()">x</a>),
      "a class belonging to a primitive" => %(<p class="rb-button">x</p>),
      "a confirm step the layout would wire up" => %(<p data-confirm="Sure?">x</p>),
      "a comment" => "<!-- <script> -->",
      "a bare angle bracket outside any element" => "a < b",
      "an element outside the markdown vocabulary" => "<div>x</div>"
    }.each do |what, markup|
      it "refuses #{what}" do
        expect { Rubotty::Dashboard::Primitives::Prose.verified(markup) }
          .to raise_error(ArgumentError, /rendered markdown/)
      end
    end

    it "draws the elements a rendered document is actually made of" do
      markup = %(<h2 id="a">A</h2><p>text <code class="language-lua">y</code> ) +
               %(<a href="#a">z</a> <img src="data:image/png;base64,AA" alt="" width="20"></p>) +
               "<hr /><table><tbody><tr><td>1</td></tr></tbody></table>"

      expect(Rubotty::Dashboard::Primitives::Prose.verified(markup)).to eq(markup)
    end
  end
end
