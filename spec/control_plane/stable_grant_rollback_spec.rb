# frozen_string_literal: true

require "spec_helper"

RSpec.describe "stable grant migration rollback on SQLite", :control_plane do
  let(:db) { Sequel.sqlite }
  after { db.disconnect }

  include_examples "stable grant rollback safety"
end
