# frozen_string_literal: true

module Rubotty
  module Util
    # Builds a SQL LIKE pattern from a value that is not one. An unescaped
    # % or _ in the value would match more than the caller intended (not an
    # injection risk, since Sequel parameterises the pattern). Sequel writes
    # its own +ESCAPE '\'+ on every +Sequel.like+ with no option to change it,
    # so output from here is meant to be paired with {.like}.
    module LikePattern
      # The escape character. Not a backslash: SQLite gives it no default
      # meaning, Postgres and MySQL each read one differently inside a literal.
      ESCAPE = "!"

      METACHARACTERS = /[#{Regexp.escape(ESCAPE)}%_]/

      # +value+ with every LIKE metacharacter, and the escape character itself,
      # made literal.
      def self.escape(value)
        value.to_s.gsub(METACHARACTERS) { |char| "#{ESCAPE}#{char}" }
      end

      # A pattern matching any string containing +value+ literally.
      def self.contains(value) = "%#{escape(value)}%"

      # A pattern matching any string beginning with +value+ literally.
      def self.starts_with(value) = "#{escape(value)}%"

      # +column LIKE ? ESCAPE '!'+, standard SQL on all three backends.
      def self.like(column, pattern)
        ::Sequel.lit("#{column} LIKE ? ESCAPE '#{ESCAPE}'", pattern)
      end

      # The same, case-insensitively: SQLite's LIKE folds ASCII case, MariaDB's
      # collation here does not and Postgres follows the database's, so lowering
      # both sides is what makes the three agree.
      def self.like_lower(column, pattern)
        ::Sequel.lit("lower(#{column}) LIKE ? ESCAPE '#{ESCAPE}'", pattern)
      end
    end
  end
end
