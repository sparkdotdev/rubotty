# frozen_string_literal: true

# What the model-backed features cost, counted rather than guessed. One row per
# community, feature, metric, bucket and day: the scalar counters leave bucket
# empty, and the latency histogram fills it with the upper bound in
# milliseconds of the bucket a call landed in, so percentiles come back without
# ever keeping a per-call row. Counted by day because the analytics page it
# draws on offers windows from a day to ninety, and a day is the coarsest
# bucket that still answers all four.
Sequel.migration do
  change do
    create_table(:model_call_stats) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade

      String :feature, null: false, size: 32
      String :metric,  null: false, size: 32
      String :bucket,  null: false, default: "", size: 32

      Date :counted_on, null: false

      Bignum :value, null: false, default: 0

      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index %i[community_id feature metric bucket counted_on], unique: true, name: :model_call_stats_row_idx
      index [:counted_on], name: :model_call_stats_day_idx
    end
  end
end
