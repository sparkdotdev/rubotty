# frozen_string_literal: true

Sequel.migration do
  up do
    long_text = Rubotty::Storage::Dialect.for(self).long_text
    next if long_text.nil?

    alter_table(:community_scripts) do
      set_column_type :source, long_text, null: false
      set_column_type :yaml_data, long_text
    end
  end

  down do
    next if Rubotty::Storage::Dialect.for(self).long_text.nil?

    alter_table(:community_scripts) do
      set_column_type :source, String, text: true, null: false
      set_column_type :yaml_data, String, text: true
    end
  end
end
