# frozen_string_literal: true

require "spec_helper"

# The swatch layer rots quietly: a role added to $roles for one
# theme's benefit leaves every other swatch short of it, and nothing
# visibly breaks (var() just resolves to nothing). So the contract is
# held here: every swatch fills every role, in both modes, at WCAG AA.
RSpec.describe "the swatch contract" do
  SWATCH_MODES = %w[light dark].freeze

  # AA is 4.5:1 for body text. The focus ring is not text, so it is held to the
  # 3:1 that WCAG asks of a non text indicator.
  SWATCH_AA_TEXT = 4.5
  SWATCH_AA_NON_TEXT = 3.0

  # The roles drawn as words on one of the two backgrounds. danger, success,
  # warning and info are in here because a state is written far more often than
  # it is painted: "degraded" has to be legible before it has to be orange.
  SWATCH_TEXT_ROLES = %w[
    content-text header-text muted-text faint-text danger success warning info
  ].freeze
  SWATCH_SURFACES = %w[background surface].freeze

  # The roles used as a solid fill behind a label, which is the whole job of
  # on-accent: one colour that reads on every one of them.
  SWATCH_FILLS = %w[accent-primary accent-secondary danger success warning info].freeze

  # What each ink step is drawn on beyond the two backgrounds above. The panel
  # fills carry body and label text; faint-text stops at the lighter one,
  # because a micro-label never sits inside a status pill.
  SWATCH_INK_GROUNDS = {
    "content-text" => %w[fill fill-strong],
    "muted-text" => %w[fill fill-strong],
    "faint-text" => %w[fill]
  }.freeze

  # How far a theme mixes a tone into the surface behind it before writing the
  # tone back on top: the composition a pill and a notice actually draw, which
  # a contrast check against the page background misses entirely. Command
  # Centre's numbers, the only theme that tints today; the other three write
  # tones straight onto surface, so a swatch clearing these clears those too.
  SWATCH_TONE_TINTS = { "light" => 0.12, "dark" => 0.19 }.freeze
  SWATCH_TONE_ROLES = %w[danger success warning].freeze

  # color-mix(in srgb, tone p%, ground), which interpolates on the gamma
  # encoded channels rather than linear ones.
  def composite(tone, ground, share)
    pair = [tone, ground].map { |hex| hex.delete_prefix("#").scan(/../).map { |part| part.to_i(16) } }
    mixed = pair[0].zip(pair[1]).map { |one, other| ((one * share) + (other * (1 - share))).round }

    format("#%02x%02x%02x", *mixed)
  end

  # A series colour is a bar or a slice, so it is a graphical object rather than
  # text, and 3:1 is what WCAG asks of one of those.
  SWATCH_AA_GRAPHIC = 3.0

  # Two series have to be told apart at a glance across a whole chart, so this is
  # checked over every pair rather than only neighbours: series 1 and series 4
  # share a chart exactly as often as 1 and 2 do, and 15 comparisons is free.
  # The shipped palettes sit above 38, so 25 leaves room to retune without
  # letting anything genuinely confusable through.
  SWATCH_SERIES_DISTINCT = 25.0

  it "keeps the role set in one place, which is what every swatch is measured against" do
    expect(Swatches.roles).to include("background", "surface", "border-bright", "on-accent", "overlay-scrim")
  end

  it "gives every role one rendering weight" do
    expect(Swatches.weights.keys).to match_array(Swatches.roles)
    expect(Swatches.weights.values).to all(match(/\A(?:ink|ground|rule|fill)\z/))
  end

  it "keeps each role at the weight its declaration allows" do
    css = CssCascade.fallback_vocabulary
    offenders = Swatches.weight_offences(css)

    expect(offenders).to be_empty, offenders.join("\n")
  end

  it "reports a solid ink used as a ground before contrast is measured" do
    css = ".pill { background: var(--rb-success); color: var(--rb-on-accent); }"

    expect(Swatches.weight_offences(css)).to contain_exactly(
      ".pill: background uses success, an ink role behind text"
    )
  end

  it "reports grounds used as ink or a rule" do
    css = ".chip { color: var(--rb-surface); border-color: var(--rb-fill); }"

    expect(Swatches.weight_offences(css)).to contain_exactly(
      ".chip: color uses surface, a ground role",
      ".chip: border uses fill, a ground role"
    )
  end

  Swatches.names.each do |name|
    describe "the #{name} swatch" do
      let(:swatch) { Swatches.read(name) }

      it "paints light and dark differently, rather than shipping one set twice" do
        expect(swatch.fetch("light")).not_to eq(swatch.fetch("dark"))
      end

      SWATCH_MODES.each do |mode|
        context "in #{mode}" do
          let(:colours) { swatch.fetch(mode) }

          it "fills every role, with nothing missing and nothing unknown" do
            expect(colours.keys).to match_array(Swatches.roles)
          end

          # Contrast against a translucent colour depends on whatever is behind
          # it, so the scrim is the only role allowed to carry alpha.
          it "keeps every colour opaque apart from the scrim" do
            single = colours.except("overlay-scrim", "series")
            loose = single.reject { |_role, value| value.match?(Swatches::OPAQUE) }

            expect(loose).to be_empty
            expect(Swatches.series(colours)).to all(match(Swatches::OPAQUE))
            expect(colours.fetch("overlay-scrim")).to start_with("rgba(")
          end

          it "carries a full series palette, at the length the contract sets" do
            expect(Swatches.series(colours).length).to eq(Swatches.series_length)
          end

          # So a single series chart reads as part of the page rather than as a
          # colour arriving from nowhere.
          it "opens the series palette on the primary accent" do
            expect(Swatches.series(colours).first).to eq(colours.fetch("accent-primary"))
          end

          it "keeps every series colour visible against both backgrounds" do
            offenders = Swatches.series(colours).each_with_index.to_a.product(SWATCH_SURFACES)
                                .filter_map do |(colour, index), surface|
              ratio = Swatches.contrast(colour, colours.fetch(surface))
              format("series-%d on %s is %.2f:1", index + 1, surface, ratio) if ratio < SWATCH_AA_GRAPHIC
            end

            expect(offenders).to be_empty,
                                 "under #{SWATCH_AA_GRAPHIC}:1 in #{name} #{mode}:\n#{offenders.join("\n")}"
          end

          it "keeps every pair of series colours apart" do
            offenders = Swatches.series(colours).combination(2).filter_map do |one, other|
              distance = Swatches.delta_e(one, other)
              format("%s and %s are %.1f apart", one, other, distance) if distance < SWATCH_SERIES_DISTINCT
            end

            expect(offenders).to be_empty,
                                 "under dE #{SWATCH_SERIES_DISTINCT} in #{name} #{mode}:\n#{offenders.join("\n")}"
          end

          it "clears AA for every text role on both backgrounds" do
            offenders = SWATCH_TEXT_ROLES.product(SWATCH_SURFACES).filter_map do |text, surface|
              ratio = Swatches.contrast(colours.fetch(text), colours.fetch(surface))
              format("%s on %s is %.2f:1", text, surface, ratio) if ratio < SWATCH_AA_TEXT
            end

            expect(offenders).to be_empty, "under #{SWATCH_AA_TEXT}:1 in #{name} #{mode}:\n#{offenders.join("\n")}"
          end

          it "clears AA for every ink step on the panel fills as well as the backgrounds" do
            offenders = SWATCH_INK_GROUNDS.flat_map do |text, grounds|
              grounds.filter_map do |ground|
                ratio = Swatches.contrast(colours.fetch(text), colours.fetch(ground))
                format("%s on %s is %.2f:1", text, ground, ratio) if ratio < SWATCH_AA_TEXT
              end
            end

            expect(offenders).to be_empty, "under #{SWATCH_AA_TEXT}:1 in #{name} #{mode}:\n#{offenders.join("\n")}"
          end

          # A tone is almost never drawn on the page background. It paints a
          # tint of itself and writes itself back on top, in a pill at 10.5px
          # and a notice at 12.5px, so this is where AA has to hold and where
          # two of Clay's three tones were failing while passing on white.
          it "clears AA for every tone on the tint of itself a theme draws it on" do
            share = SWATCH_TONE_TINTS.fetch(mode)
            offenders = SWATCH_TONE_ROLES.filter_map do |role|
              tone = colours.fetch(role)
              ground = composite(tone, colours.fetch("surface"), share)
              ratio = Swatches.contrast(tone, ground)
              format("%s on its own %d%% tint %s is %.2f:1", role, (share * 100).round, ground, ratio) if ratio < SWATCH_AA_TEXT
            end

            expect(offenders).to be_empty, "under #{SWATCH_AA_TEXT}:1 in #{name} #{mode}:\n#{offenders.join("\n")}"
          end

          it "clears AA for a label on every filled colour" do
            offenders = SWATCH_FILLS.filter_map do |fill|
              ratio = Swatches.contrast(colours.fetch("on-accent"), colours.fetch(fill))
              format("on-accent on %s is %.2f:1", fill, ratio) if ratio < SWATCH_AA_TEXT
            end

            expect(offenders).to be_empty, "under #{SWATCH_AA_TEXT}:1 in #{name} #{mode}:\n#{offenders.join("\n")}"
          end

          it "leaves the focus ring visible against both backgrounds" do
            offenders = SWATCH_SURFACES.filter_map do |surface|
              ratio = Swatches.contrast(colours.fetch("focus-ring"), colours.fetch(surface))
              format("focus-ring on %s is %.2f:1", surface, ratio) if ratio < SWATCH_AA_NON_TEXT
            end

            expect(offenders).to be_empty,
                                 "under #{SWATCH_AA_NON_TEXT}:1 in #{name} #{mode}:\n#{offenders.join("\n")}"
          end
        end
      end
    end
  end
end
