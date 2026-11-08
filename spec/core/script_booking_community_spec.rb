# frozen_string_literal: true

require "spec_helper"
require "sequel"

# Issue #1791. Core::Router booked script jobs with no community: argument, so
# scheduled_jobs.community was NULL for every rubotty.schedule and every
# open_round close_after, while the matching cancel passed the slug and could
# never match a NULL row. Driven against the real store, which is where it broke.
RSpec.describe Rubotty::Core::Router, "booking a script job against its own community", :control_plane do
  let(:plane) { colliding_control_plane }
  let(:db) { plane[0] }
  let(:models) { plane[1] }
  let(:alpha) { models.community.where(slug: CollidingCommunities::ALPHA[:slug]).first }
  let(:beta) { models.community.where(slug: CollidingCommunities::BETA[:slug]).first }

  let(:store) { Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db) }
  let(:scheduler) do
    Rubotty::Core::DurableScheduler.new(store: store, session_id: "s", logger: Rubotty::Log.null)
  end
  let(:scripts) { Rubotty::ControlPlane::Scripts.new(models: models, logger: Rubotty::Log.null) }

  # Both tenants own a script of the same name and a room keyed "general", so
  # nothing in a booking's payload alone says which community it belongs to.
  before do
    [alpha, beta].each do |community|
      scripts.save(community: community, name: "quiz", kind: "callback",
                   source: "return nil", trigger_type: "always")
    end
  end

  def booker(community)
    described_class.allocate.send(:script_schedule_handler, community, scripts, scheduler,
                                  { generation: 0, script_name: "quiz",
                                    room_key: CollidingCommunities::SHARED_ROOM_KEY })
  end

  def canceller(community)
    described_class.allocate.send(:script_unschedule_handler, community, scheduler,
                                  { script_name: "quiz", room_key: CollidingCommunities::SHARED_ROOM_KEY })
  end

  def book(community, tag: "rounds")
    booker(community).call({ "after" => 60, "tag" => tag })
  end

  def booked_communities = db[:scheduled_jobs].select_map(:community).sort

  it "writes the booking against the community that asked, never as an unattributed row" do
    book(alpha)

    expect(booked_communities).to eq([alpha.slug])
  end

  # The broken half of the issue: the cancel could never match its own row.
  it "lets a script unschedule the booking it made" do
    book(alpha)

    expect(canceller(alpha).call("rounds")).to eq(1)
    expect(booked_communities).to be_empty
  end

  it "leaves another tenant's identically tagged booking standing" do
    book(alpha)
    book(beta)

    expect(canceller(beta).call("rounds")).to eq(1)
    expect(booked_communities).to eq([alpha.slug])
  end

  it "cancels nothing at all for a tag this community never booked" do
    book(alpha)

    expect(canceller(beta).call("rounds")).to be_zero
    expect(booked_communities).to eq([alpha.slug])
  end

  # Belt and braces at the fire point, for a row written by an older build or
  # edited by hand: the column and the payload each name a community, and a
  # wake runs only where they agree.
  describe "waking a booking whose two communities disagree" do
    let(:runtime) { Rubotty::Core::Runtime.allocate }
    let(:row) { Struct.new(:id, :community, :payload) }

    it "refuses a job booked to one community whose payload names another" do
      expect(runtime.send(:script_job_agrees?, row.new(1, "alpha", {}), "beta")).to be(false)
    end

    it "wakes one whose column and payload agree" do
      expect(runtime.send(:script_job_agrees?, row.new(1, "alpha", {}), "alpha")).to be(true)
    end

    # An unattributed row predates the booking sites carrying a community, so
    # there is nothing to compare it against and it still runs.
    it "wakes an older booking that carries no community column at all" do
      expect(runtime.send(:script_job_agrees?, row.new(1, nil, {}), "alpha")).to be(true)
    end
  end

  describe "an open_round close_after booking" do
    # #round is consulted only for a fresher closes_at; nil falls back to the
    # close_after the script asked for, which is all this needs.
    let(:participation) { Class.new { def round(community:, room_key:) = nil }.new }

    def book_close(community)
      described_class.allocate.send(:book_round_close, participation, community,
                                    CollidingCommunities::SHARED_ROOM_KEY, nil, scheduler,
                                    7, 60, "quiz", nil)
    end

    it "carries the community too, so a per-tenant sweep can see it" do
      book_close(beta)

      expect(booked_communities).to eq([beta.slug])
    end

    it "is cancellable by its own community and not by the other" do
      book_close(alpha)
      book_close(beta)

      cancelled = scheduler.cancel(kind: Rubotty::Features::Scripts::LATER_KIND,
                                   community: beta.slug) { |payload| payload["tag"] == "round-7" }
      expect(cancelled).to eq(1)
      expect(booked_communities).to eq([alpha.slug])
    end
  end
end
