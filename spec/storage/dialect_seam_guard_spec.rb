# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Storage::Dialect exists so that exactly one file in lib/ knows how a backend spells an
# upsert: ON CONFLICT ... DO UPDATE on Postgres and SQLite, ON DUPLICATE KEY UPDATE on
# MySQL/MariaDB. The rule has been broken twice and reached production both times, since a
# raw call is valid SQLite and stays green locally, so this checks the source directly.
RSpec.describe "the storage dialect seam" do
  let(:lib_root) { File.expand_path("../../lib", __dir__) }

  # The one file allowed to name a dialect's own upsert spelling.
  let(:seam) { File.join(lib_root, "rubotty/storage/dialect.rb") }

  # insert_conflict is Postgres/SQLite only and on_duplicate_key_update is
  # MySQL/MariaDB only; each raises NoMethodError on the other's dataset.
  let(:forbidden) { %w[insert_conflict on_duplicate_key_update] }

  # Every offending call site under +root+ as "path:line: source", ignoring any
  # mention that falls after a "#", which is prose about the seam.
  def offences(root, allow: [])
    Dir.glob(File.join(root, "**", "*.rb")).sort.reject { |path| allow.include?(path) }.flat_map do |path|
      File.readlines(path, encoding: "UTF-8").each_with_index.filter_map do |line, index|
        column = line.index(Regexp.union(forbidden))
        next if column.nil?
        # A "#" at or before the match means the mention is in a comment.
        next if line[0...column].include?("#")

        "#{path.delete_prefix("#{root}/")}:#{index + 1}: #{line.strip}"
      end
    end
  end

  def guidance(found)
    <<~MESSAGE
      A dialect-specific upsert is being called outside the seam:

      #{found.join("\n")}

      #insert_conflict is the Postgres/SQLite spelling (ON CONFLICT DO UPDATE)
      and #on_duplicate_key_update is the MySQL/MariaDB one (ON DUPLICATE KEY
      UPDATE). Neither exists on the other's dataset, so calling one directly
      raises NoMethodError on a backend production actually runs while the local
      SQLite suite stays green. That has now shipped broken twice.

      Use Rubotty::Storage::Dialect#upsert instead:

        @dialect = Rubotty::Storage::Dialect.for(db)   # in the constructor
        @dialect.upsert(dataset, target: %i[a b], update: %i[c d]).insert(row)

      where target: is the unique key that conflicts and update: is the list of
      columns to overwrite with the values the insert proposed. If you need a
      dialect difference the seam does not cover yet, add it to
      lib/rubotty/storage/dialect.rb rather than branching at the call site.
    MESSAGE
  end

  it "is the only place in lib/ that spells a backend's own upsert" do
    found = offences(lib_root, allow: [seam])
    expect(found).to be_empty, -> { guidance(found) }
  end

  # The same detection over a throwaway tree holding one real raw call and one
  # comment about it, so the guard is watched flagging the call and sparing prose.
  it "flags a raw call and ignores a comment about one" do
    Dir.mktmpdir("rubotty-seam-guard") do |dir|
      File.write(File.join(dir, "raw_store.rb"), <<~RUBY)
        def add(row)
          dataset.insert_conflict(target: %i[a b], update: { a: 1 }).insert(row)
        end
      RUBY
      File.write(File.join(dir, "prose.rb"), <<~RUBY)
        # Postgres spells the upsert #insert_conflict; MariaDB uses
        # #on_duplicate_key_update instead, so both go through the seam.
        def add(row) = @dialect.upsert(dataset, target: %i[a b], update: %i[c]).insert(row)
      RUBY

      found = offences(dir)
      expect(found.size).to eq(1)
      expect(found.first).to start_with("raw_store.rb:2:")
      expect(guidance(found)).to include("Rubotty::Storage::Dialect#upsert")
    end
  end
end
