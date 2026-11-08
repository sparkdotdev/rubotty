# frozen_string_literal: true

module Rubotty
  module Config
    # A small declarative schema for YAML fragments. Reports EVERY problem in one
    # pass, and lets adapters contribute fragments at runtime (see
    # {Adapters::Base.endpoint_schema}).
    #
    # Error messages carry the YAML path:
    #
    #   rooms[2].endpoints[0].chat_id: expected an integer, got "abc"
    class Schema
      Field = Struct.new(
        :name, :type, :required, :default, :one_of, :element_type, :schema, :variants,
        :description, :env_backed, :validator, :empty_means_unset, :multiline, :range, :step,
        keyword_init: true
      )

      TYPES = %i[string integer float boolean symbol array hash duration any].freeze

      def self.define(&block)
        schema = new
        schema.instance_eval(&block) if block
        schema
      end

      def initialize
        @fields = {}
        @allow_unknown = false
      end

      attr_reader :fields

      # Permit keys the schema does not declare. Off by default: a typo in a config
      # key is one of the most common and most confusing operator errors.
      def allow_unknown!(value = true)
        @allow_unknown = value
        self
      end

      def allow_unknown? = @allow_unknown

      # Declare a field.
      # @param of [Symbol, Schema, Array<Symbol, Schema>] element type for :array, a nested schema, or a scalar-or-mapping shorthand list
      # @param env [Boolean] names an environment variable instead of holding a value directly; used for secrets
      # @param empty_means_unset [Boolean] treats an explicit empty value as unset so the default fires; off, since [] is usually deliberate
      # @param multiline [Boolean] a :string field long enough to need a wrapping textarea, not a one-line input; a display hint only
      # @param range [Range, nil] the values this field accepts, enforced here and
      #   carried to the form so a control cannot offer what the loader refuses
      # @param step [Numeric, nil] how finely it moves, for that control alone
      def field(name, type = :string, required: false, default: nil, one_of: nil,
                of: nil, env: false, desc: nil, empty_means_unset: false, multiline: false,
                range: nil, step: nil, &validator)
        raise ArgumentError, "unknown schema type #{type.inspect}" unless TYPES.include?(type)

        element_type, schema, variants = element_contract(of)
        @fields[name.to_sym] = Field.new(
          name: name.to_sym, type: type, required: required, default: default,
          one_of: one_of, element_type: element_type, schema: schema, variants: variants,
          description: desc, env_backed: env, validator: validator,
          empty_means_unset: empty_means_unset, multiline: multiline, range: range, step: step
        )
        self
      end

      # Validate and coerce +input+.
      #
      # @param input [Hash, nil]
      # @param path [String] YAML path prefix for error messages
      # @return [Result]
      def call(input, path: "")
        problems = []
        input = {} if input.nil?
        unless input.is_a?(Hash)
          return Result.new(nil, ["#{path.empty? ? "(root)" : path}: expected a mapping, got #{describe(input)}"])
        end

        normalised = input.each_with_object({}) { |(key, value), out| out[key.to_s.to_sym] = value }
        output = {}

        @fields.each_value do |field|
          key_path = join(path, field.name)
          present = normalised.key?(field.name)
          value = normalised[field.name]
          unset = !present || value.nil? || (field.empty_means_unset && empty_value?(value))

          if unset
            if field.required
              problems << "#{key_path}: is required"
            elsif !field.default.nil?
              output[field.name] = field.default
            elsif present
              output[field.name] = nil
            end
            next
          end

          coerced, problem = coerce(field, value, key_path)
          if problem
            problems << problem
            next
          end

          if field.one_of && !field.one_of.include?(coerced)
            problems << "#{key_path}: must be one of #{field.one_of.map(&:to_s).join(", ")}, got #{coerced.inspect}"
            next
          end

          # For the schemas that are actually run: the YAML config loader's own.
          # A feature's config_schema is never called against stored settings,
          # so the same bound is enforced again at the one write seam every
          # surface goes through, in ControlPlane::FeatureControls.
          if field.range && !field.range.cover?(coerced)
            problems << "#{key_path}: must be between #{field.range.first} and #{field.range.last}, " \
                        "got #{coerced.inspect}"
            next
          end

          if field.validator
            extra = field.validator.call(coerced, key_path)
            if extra
              problems.concat(Array(extra))
              next
            end
          end

          output[field.name] = coerced
        end

        unless @allow_unknown
          (normalised.keys - @fields.keys).each do |unknown|
            problems << "#{join(path, unknown)}: unknown key#{suggestion(unknown)}"
          end
        end

        if @allow_unknown
          (normalised.keys - @fields.keys).each { |key| output[key] = normalised[key] }
        end

        Result.new(output, problems)
      end

      # Merge another schema's fields into this one.
      def merge(other)
        combined = self.class.new
        combined.allow_unknown!(@allow_unknown || other.allow_unknown?)
        @fields.each_value { |f| combined.fields[f.name] = f }
        other.fields.each_value { |f| combined.fields[f.name] = f }
        combined
      end

      private

      def element_contract(of)
        return [nil, of, nil] if of.is_a?(Schema)
        return [of, nil, nil] unless of.is_a?(Array)

        unless of.all? { |entry| entry.is_a?(Schema) || TYPES.include?(entry) }
          raise ArgumentError, "array element variants must be schema types or nested schemas"
        end

        [nil, nil, of]
      end

      def join(path, key)
        path.empty? ? key.to_s : "#{path}.#{key}"
      end

      # "", [] and {} all count as empty; anything without its own #empty?
      # (an integer, a boolean) never does.
      def empty_value?(value)
        value.respond_to?(:empty?) && value.empty?
      end

      # Suggest a correction for a likely typo, only when the key is close to a known one.
      def suggestion(unknown)
        candidate = @fields.keys.min_by { |known| distance(unknown.to_s, known.to_s) }
        return "" if candidate.nil?

        d = distance(unknown.to_s, candidate.to_s)
        return "" if d > [3, candidate.to_s.length / 2].min

        ". Did you mean #{candidate}?"
      end

      def distance(a, b)
        return b.length if a.empty?
        return a.length if b.empty?

        previous = (0..b.length).to_a
        a.each_char.with_index do |char_a, i|
          current = [i + 1]
          b.each_char.with_index do |char_b, j|
            current << [previous[j + 1] + 1, current[j] + 1, previous[j] + (char_a == char_b ? 0 : 1)].min
          end
          previous = current
        end
        previous.last
      end

      def coerce(field, value, path)
        case field.type
        when :string then coerce_string(value, path)
        when :integer then coerce_integer(value, path)
        when :float then coerce_float(value, path)
        when :boolean then coerce_boolean(value, path)
        when :symbol then coerce_symbol(value, path)
        when :duration then coerce_duration(value, path)
        when :array then coerce_array(field, value, path)
        when :hash then coerce_hash(field, value, path)
        when :any then [value, nil]
        else [value, nil]
        end
      end

      def coerce_string(value, path)
        return [value, nil] if value.is_a?(String)
        return [value.to_s, nil] if value.is_a?(Numeric) || value.is_a?(Symbol)

        [nil, "#{path}: expected a string, got #{describe(value)}"]
      end

      def coerce_integer(value, path)
        return [value, nil] if value.is_a?(Integer)

        if value.is_a?(String) && value.match?(/\A-?\d+\z/)
          [Integer(value, 10), nil]
        else
          [nil, "#{path}: expected an integer, got #{describe(value)}"]
        end
      end

      def coerce_float(value, path)
        return [value.to_f, nil] if value.is_a?(Numeric)

        [nil, "#{path}: expected a number, got #{describe(value)}"]
      end

      def coerce_boolean(value, path)
        return [value, nil] if [true, false].include?(value)

        [nil, "#{path}: expected true or false, got #{describe(value)}"]
      end

      def coerce_symbol(value, path)
        return [value.to_sym, nil] if value.is_a?(String) || value.is_a?(Symbol)

        [nil, "#{path}: expected a name, got #{describe(value)}"]
      end

      # Accepts either "24 hours" style strings or a plain number of seconds.
      DURATION_UNITS = {
        "s" => 1, "sec" => 1, "secs" => 1, "second" => 1, "seconds" => 1,
        "m" => 60, "min" => 60, "mins" => 60, "minute" => 60, "minutes" => 60,
        "h" => 3600, "hr" => 3600, "hrs" => 3600, "hour" => 3600, "hours" => 3600,
        "d" => 86_400, "day" => 86_400, "days" => 86_400,
        "w" => 604_800, "week" => 604_800, "weeks" => 604_800
      }.freeze

      def coerce_duration(value, path)
        return [value.to_i, nil] if value.is_a?(Numeric)

        unless value.is_a?(String)
          return [nil, "#{path}: expected a duration such as \"24 hours\", got #{describe(value)}"]
        end

        match = value.strip.downcase.match(/\A(\d+)\s*([a-z]*)\z/)
        return [nil, "#{path}: cannot read #{value.inspect} as a duration"] if match.nil?

        amount = match[1].to_i
        unit = match[2]
        return [amount, nil] if unit.empty?

        multiplier = DURATION_UNITS[unit]
        if multiplier.nil?
          return [nil, "#{path}: unknown time unit #{unit.inspect}, use one of " \
                       "seconds, minutes, hours, days, weeks"]
        end

        [amount * multiplier, nil]
      end

      def coerce_array(field, value, path)
        return [nil, "#{path}: expected a list, got #{describe(value)}"] unless value.is_a?(Array)

        problems = []
        out = value.each_with_index.map do |element, index|
          element_path = "#{path}[#{index}]"
          if field.schema
            result = field.schema.call(element, path: element_path)
            problems.concat(result.problems)
            result.value
          elsif field.variants
            coerce_array_variant(field, element, element_path, problems)
          elsif field.element_type
            coerced, problem = coerce(Field.new(name: field.name, type: field.element_type), element, element_path)
            problems << problem if problem
            coerced
          else
            element
          end
        end
        problems.empty? ? [out, nil] : [nil, problems]
      end

      def coerce_array_variant(field, element, path, problems)
        attempts = field.variants.map do |variant|
          if variant.is_a?(Schema)
            result = variant.call(element, path: path)
            [result.value, result.problems]
          else
            value, problem = coerce(Field.new(name: field.name, type: variant), element, path)
            [value, Array(problem).compact]
          end
        end
        accepted = attempts.find { |_value, errors| errors.empty? }
        return accepted.first if accepted

        problems.concat(attempts.flat_map(&:last).uniq)
        nil
      end

      def coerce_hash(field, value, path)
        return [nil, "#{path}: expected a mapping, got #{describe(value)}"] unless value.is_a?(Hash)
        return [symbolize(value), nil] if field.schema.nil?

        result = field.schema.call(value, path: path)
        result.problems.empty? ? [result.value, nil] : [nil, result.problems]
      end

      def symbolize(hash)
        hash.each_with_object({}) { |(key, value), out| out[key.to_s.to_sym] = value }
      end

      def describe(value)
        case value
        when nil then "nothing"
        when Hash then "a mapping"
        when Array then "a list"
        when String then value.inspect
        else value.inspect
        end
      end
    end

    # The outcome of validating one fragment.
    class Result
      attr_reader :value, :problems

      def initialize(value, problems)
        @value = value
        @problems = problems.flatten.compact
      end

      def valid? = @problems.empty?

      def merge(other)
        Result.new(value, problems + other.problems)
      end
    end
  end
end
