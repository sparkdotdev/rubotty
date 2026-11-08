# frozen_string_literal: true

require "spec_helper"
require "sequel"

# Issue #1799. Both REST relay queues took a community and a room, asserted
# nothing about the pair, and wrote them straight into a pending row that the
# API adapter later drains and posts into. The action queue additionally took a
# bare message id with no check that the message belonged to the room.
RSpec.describe "the API relay queues holding a community and a room together", :control_plane do
  let(:plane) { colliding_control_plane }
  let(:models) { plane[1] }
  let(:seeded) { plane[2] }

  let(:alpha) { models.community.where(slug: CollidingCommunities::ALPHA[:slug]).first }
  let(:beta) { models.community.where(slug: CollidingCommunities::BETA[:slug]).first }
  # Both are keyed "general", which is the shape production has and the reason
  # a room key alone never says which tenant was meant.
  let(:alpha_room) { models.room[seeded[:alpha][:room_id]] }
  let(:beta_room) { models.room[seeded[:beta][:room_id]] }

  def ref_for(room, native_id = "42")
    Rubotty::Core::MessageRef.new(Rubotty::Adapters::Api.endpoint_key_for(room.id), native_id)
  end

  describe Rubotty::ControlPlane::ApiMessages do
    subject(:messages) { described_class.new(models: models) }

    it "queues a post into a room its own community owns" do
      row = messages.enqueue(community: beta, room: beta_room, body: "hello")

      expect(row.room_id).to eq(beta_room.id)
      expect(row.community_id).to eq(beta.id)
    end

    it "refuses to queue a post into another community's room" do
      expect { messages.enqueue(community: beta, room: alpha_room, body: "hello") }
        .to raise_error(ArgumentError, /belongs to community/)
    end

    it "writes no row at all when it refuses" do
      begin
        messages.enqueue(community: beta, room: alpha_room, body: "hello")
      rescue ArgumentError
        nil
      end

      expect(models.api_pending_message.count).to be_zero
    end
  end

  describe Rubotty::ControlPlane::ApiMessageActions do
    subject(:actions) { described_class.new(models: models) }

    it "queues an edit of a message its own room minted" do
      row = actions.enqueue_edit(community: beta, room: beta_room, message: ref_for(beta_room), body: "fixed")

      expect(row.message_id).to eq("42")
      expect(row.room_id).to eq(beta_room.id)
    end

    it "refuses an action aimed at another community's room" do
      expect { actions.enqueue_delete(community: beta, room: alpha_room, message: ref_for(alpha_room)) }
        .to raise_error(ArgumentError, /belongs to community/)
    end

    # The second pair, which nothing checked at all: a ref minted in one room
    # said nothing about the room the row names.
    it "refuses a message ref another room minted, even inside the right community" do
      expect { actions.enqueue_delete(community: beta, room: beta_room, message: ref_for(alpha_room)) }
        .to raise_error(ArgumentError, /was not minted for room/)
    end

    it "refuses a bare id where the room-bound ref belongs" do
      expect { actions.enqueue_delete(community: beta, room: beta_room, message: "42") }
        .to raise_error(ArgumentError, /was not minted for room/)
    end

    it "holds a reaction to the same two pairs" do
      expect { actions.enqueue_reaction_add(community: beta, room: beta_room, message: ref_for(alpha_room),
                                            reaction: { emoji: "\u{1F44D}" }) }
        .to raise_error(ArgumentError, /was not minted for room/)
    end

    it "writes no row at all when it refuses" do
      begin
        actions.enqueue_delete(community: beta, room: alpha_room, message: ref_for(alpha_room))
      rescue ArgumentError
        nil
      end

      expect(models.api_pending_message_action.count).to be_zero
    end
  end
end
