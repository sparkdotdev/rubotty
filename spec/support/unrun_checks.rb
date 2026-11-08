# frozen_string_literal: true

# The last word in a run, so a skip cannot read as a pass.
#
# rspec's summary line is what gets read, and "1204 examples, 0 failures, 96
# pending" looks clean even when all 96 never executed. Work has been reported
# verified on exactly that misreading, so this prints after the summary,
# grouped by reason, one line per missing interpreter instead of ninety.
# What's left is genuinely optional (Lua, zbar, tesseract, a real database,
# live gateway credentials); the theme specs fail here instead, see theme_toolchain.rb.
class UnrunChecks
  RSpec::Core::Formatters.register self, :example_pending, :close

  attr_reader :output

  def initialize(output)
    @output = output
    @reasons = Hash.new(0)
  end

  def example_pending(notification)
    reason = notification.example.execution_result.pending_message
    @reasons[reason.to_s.strip.empty? ? "no reason given" : reason] += 1
  end

  def close(_notification)
    return if @reasons.empty?

    output.puts "\nNot everything ran. #{@reasons.values.sum} example(s) skipped themselves, for these reasons:"
    @reasons.sort_by { |reason, count| [-count, reason] }.each do |reason, count|
      output.puts format("  %<count>4d  %<reason>s", count: count, reason: reason)
    end
    output.puts "The summary above counts only what executed.\n\n"
  end
end

RSpec.configure { |config| config.add_formatter(UnrunChecks) }
