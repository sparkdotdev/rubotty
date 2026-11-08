# frozen_string_literal: true

require "spec_helper"

# The migration chain run against a database with rows in it, the half
# spec/migrations_round_trip_spec.rb cannot reach: a migration that backfills
# a column or loops over rows does nothing on an empty schema. An invented
# deployment is walked up to head, back down and up again on every backend.
RSpec.describe "the control-plane migrations, over a database with rows in it" do
  # Every [table, column] whose null-ness or type came back different from a fresh build.
  def loosened(fresh, rolled)
    fresh.flat_map do |table, shape|
      shape[:columns].filter_map do |name, info|
        [table, name] if rolled.dig(table, :columns, name) != info
      end
    end.sort
  end

  # The rooms the fixture describes, in the form the census reads them back in.
  def seeded_rooms
    ProdShapedFixture::ROOMS.map { |room| [room[:community], room[:room_key], room[:channels].sort] }
                            .sort_by { |row| [row[0], row[1]] }
  end

  # Each guest invite with the room its channel belongs to, which migration 016
  # works out for itself from room_channels.
  def seeded_invites
    ProdShapedFixture::GUEST_INVITES.map do |invite|
      room = ProdShapedFixture::ROOMS.find { |candidate| candidate[:channels].include?(invite[:channel]) }
      [invite[:community], room[:room_key], invite[:channel], invite[:nickname], invite[:token_hash]]
    end.sort_by { |row| row.map(&:to_s) }
  end

  MigrationChainTrip::BACKENDS.each do |backend|
    context "on #{backend[:name]}", if: MigrationChainTrip.available?(backend) do
      # One walk of the chain for every example below it, roughly 250 migration steps.
      before(:context) { @trip = MigrationChainTrip.observe(backend) }

      it "seeds a database that actually has rows in it" do
        counts = @trip[:climbed][:counts]

        expect(counts[:communities]).to eq(ProdShapedFixture::COMMUNITIES.size)
        expect(counts[:channels]).to eq(ProdShapedFixture::CHANNELS.size)
        expect(counts[:rooms]).to eq(ProdShapedFixture::ROOMS.size)
        expect(counts[:room_channels]).to eq(ProdShapedFixture::ROOMS.sum { |r| r[:channels].size })
        expect(counts[:guest_invites]).to eq(ProdShapedFixture::GUEST_INVITES.size)
        expect(counts[:operators]).to eq(ProdShapedFixture::PEOPLE.size)
        # Migration 045 moves a guest upload's bytes to the object store and deletes
        # the rows that held them, so zero is what a correct chain leaves here.
        expect(counts[:guest_uploads]).to eq(0)
      end

      it "climbs to the schema a fresh build makes" do
        fresh = @trip[:fresh][:top]
        climbed = @trip[:climbed][:shapes]

        expect(climbed.keys).to eq(fresh.keys)
        fresh.each_key do |table|
          expect(climbed[table]).to eq(fresh[table]), "#{table} differs from a fresh build"
        end
      end

      # Migration 015 adds platform_connections.settings as TEXT NOT NULL defaulting
      # to "{}". Sequel's shared MySQL adapter strips a TEXT column's default, so
      # without Storage::Dialect's MysqlTextDefaults the rows that already existed
      # come out holding "" and every later JSON.parse of them fails.
      it "fills a column added with a default on every row that was already there" do
        settings = @trip[:climbed][:census][:connections].map(&:last)

        expect(settings).to all(eq("{}"))
        expect(settings.size).to eq(ProdShapedFixture::CONNECTIONS.size)
      end

      # Migration 012 re-parents feature_settings from channels onto rooms, keeping
      # the newest by updated_at where rows collapse onto one room. The fixture puts
      # three word_filter rows on one room's three channels so that collapse runs.
      it "re-scopes the feature settings onto rooms and collapses the ones sharing a room" do
        settings = @trip[:climbed][:census][:feature_settings]
        word_filter = settings.select { |row| row[2] == "word_filter" }

        expect(word_filter)
          .to eq([["harbourside", "general", "word_filter", true, "{\"list\":[\"discord\"]}"]])
        # Three rows became one, so the table is two rows shorter than it was seeded.
        expect(settings.size).to eq(ProdShapedFixture::FEATURE_SETTINGS.size - 2)
        # Every room-scoped row names a room that exists.
        rooms = @trip[:climbed][:census][:rooms].map { |_, room_key, _| room_key }
        expect(settings.filter_map { |row| row[1] }.uniq - rooms).to be_empty
      end

      # Migration 016 does the same for a guest session, reading each row's channel
      # to find its room. A guest left without a room cannot reach anything.
      it "re-scopes every guest session onto the room its channel belongs to" do
        census = @trip[:climbed][:census]

        expect(census[:guest_invites]).to eq(seeded_invites)
        # The feed rows follow their invite's channel into the same rooms.
        expect(census[:guest_messages].group_by(&:first).transform_values(&:size))
          .to eq(seeded_invites.to_h { |row| [row[1], ProdShapedFixture::FEED_ROWS_PER_INVITE] })
      end

      # Both re-scoping migrations read room_channels, so check they left it alone.
      it "keeps every room bridged to the endpoints it was seeded with" do
        expect(@trip[:climbed][:census][:rooms]).to eq(seeded_rooms)
      end

      # Migration 032 gives every memo a room and 034 rewrites every memo into a
      # scope, both row by row, so an empty script_memos would pass without either
      # migration doing anything.
      it "gives every script memo the room and the scope the reshapes add" do
        memos = @trip[:climbed][:scripts][:memos]

        expect(memos.map(&:first)).to eq(ProdShapedFixture::MEMOS.map { |m| m[:key] }.sort)
        # 032's default room, since these were written before rooms reached a memo.
        expect(memos.map { |row| row[2] }).to all(eq(""))
        # 034 makes every existing memo private to the script that wrote it.
        expect(memos.map(&:last)).to all(match(/\As:\d+\z/))
      end

      it "rolls back to the tables, columns and indexes of the seed version" do
        fresh = @trip[:fresh][:floor]
        rolled = @trip[:floor][:shapes]
        floor = ProdShapedFixture::FLOOR

        expect(rolled.keys).to eq(fresh.keys)
        fresh.each do |table, shape|
          expect(rolled[table][:indexes]).to eq(shape[:indexes]),
                                             "#{table} indexes differ from a fresh #{floor}"
          # Sorted, because column ORDER is not part of the shape: a column a `down`
          # puts back lands at the end of the table rather than where it used to sit.
          expect(rolled[table][:columns].keys.sort).to eq(shape[:columns].keys.sort),
                                                      "#{table} columns differ from a fresh #{floor}"
        end
      end

      # The documented exception: migration 016's `down` leaves channel_id nullable
      # on the three guest tables, because live code may have written a guest row
      # with no channel and there is no honest value to backfill one with. Named one
      # at a time so the exception stays exactly three columns wide.
      it "relaxes only the three guest columns migration 016 will not tighten again" do
        expect(loosened(@trip[:fresh][:floor], @trip[:floor][:shapes]))
          .to eq([%i[guest_invites channel_id], %i[guest_messages channel_id],
                  %i[guest_uploads channel_id]])
      end

      # Migration 081 seeds one deployment-wide feature_settings row absent from
      # the fixture, present at head but never below FLOOR (081 hasn't run there
      # yet); every other table's count round-trips exactly.
      it "rolls back without dropping a row from the tables the seed version has" do
        floor = @trip[:floor][:counts]
        expect(floor.merge(feature_settings: floor[:feature_settings] + 1)).to eq(@trip[:climbed][:counts])
      end

      it "climbs again to the same schema and the same rows" do
        expect(@trip[:reclimbed][:shapes]).to eq(@trip[:climbed][:shapes])
        expect(@trip[:reclimbed][:census]).to eq(@trip[:climbed][:census])
      end

      # Rolling back past migration 031 drops the script tables, so they come back
      # empty. Asserted so it does not read as the fixture failing to seed them.
      it "leaves the script layer behind when it rolls below the migration that made it" do
        expect(@trip[:reclimbed][:scripts].values).to all(be_empty)
      end
    end
  end
end
