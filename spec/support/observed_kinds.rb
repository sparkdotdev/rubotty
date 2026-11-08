# frozen_string_literal: true

# Features::Pipeline hands a message to a feature only when that feature's own
# observes list names the kind, so a kind quietly dropped from the list switches
# the behaviour off for real traffic while the feature's own specs, which call it
# directly, carry on passing. The macros below close that gap: each drives one
# real message of one observed kind through a real Pipeline and fails with a
# sentence naming what stopped working. They live in the feature's own spec, under
# `describe "every kind it observes, driven through the real pipeline"`, so they
# run against the wiring already set up there.
module ObservedKinds
  # Says which of the two things went wrong: the list stopped naming the kind, or
  # it still names it and whatever sat behind it is gone.
  def observed_kind_failure(feature, kind, purpose)
    if feature.observes.include?(kind)
      return "#{feature} was handed a :#{kind} by the pipeline and did not hold up its end of this: #{purpose}."
    end

    "#{feature}.observes no longer names :#{kind}, so Features::Pipeline never hands it one and this stops " \
      "happening on every deployment, whatever the rest of this file still says: #{purpose}."
  end

  # The example-group side of {ObservedKinds}.
  module Macros
    # One example per observed kind: the block drives a real message of +kind+
    # through a real Pipeline and returns what the feature did with it, an empty
    # result meaning nothing. +purpose+ says what that kind buys a room.
    def observes_kind(kind, purpose, &evidence)
      observed_kinds_covered << kind
      it "#{kind}: #{purpose}" do
        expect(instance_exec(&evidence))
          .not_to be_empty, observed_kind_failure(described_class, kind, purpose)
      end
    end

    # For an observed kind whose whole point is to STOP something, a swallowed
    # reaction being the usual case: the block returns what got past the feature,
    # and anything at all there means the swallow is gone.
    def swallows_kind(kind, purpose, &evidence)
      observed_kinds_covered << kind
      it "#{kind}: #{purpose}" do
        expect(instance_exec(&evidence))
          .to be_empty, observed_kind_failure(described_class, kind, purpose)
      end
    end

    # The same for a kind deliberately left OFF the list, where adding it is the
    # regression: the block drives one through and must come back with nothing.
    def ignores_kind(kind, purpose, &evidence)
      it "#{kind}: #{purpose}" do
        expect(instance_exec(&evidence))
          .to be_empty, "#{described_class}.observes now names :#{kind}, so this no longer holds: #{purpose}."
      end
    end

    # Catches a kind added to observes with no example above to hold it up.
    def covers_every_observed_kind
      covered = observed_kinds_covered.dup
      it "has an example for every kind it observes" do
        missing = described_class.observes - covered
        expect(missing).to be_empty,
                           "#{described_class} observes #{missing.map(&:inspect).join(", ")} with nothing here " \
                           "driving one through the pipeline, so dropping it again would go unnoticed."
      end
    end

    # Per example group, so nested groups keep their own tally.
    def observed_kinds_covered = @observed_kinds_covered ||= []
  end
end

RSpec.configure do |config|
  config.include ObservedKinds
  config.extend ObservedKinds::Macros
end
