# frozen_string_literal: true

module Rubotty
  module Util
    # Limits bytes actually read from rack.input as well as declared length.
    # Runs outside the framework, before multipart parsing can spool the body.
    class BodyLimit
      class TooLarge < StandardError
        def initialize(limit)
          super("That request body is larger than this endpoint accepts (#{limit} bytes).")
        end
      end

      # Reads are bounded before asking the underlying IO for bytes. A rewind
      # revisits the same body offsets rather than charging a second copy.
      class Input
        CHUNK_BYTES = 64 * 1024
        attr_reader :exceeded

        def initialize(input, limit)
          @input, @limit, @offset, @exceeded = input, limit, 0, false
          if input.respond_to?(:rewind)
            define_singleton_method(:rewind) do
              result = @input.rewind
              @offset = 0
              result
            end
          end
        end

        def read(length = nil, buffer = nil)
          raise TypeError, "length must be an Integer or nil" unless length.nil? || length.is_a?(Integer)
          raise ArgumentError, "negative length" if length && length.negative?
          raise TypeError, "buffer must be a String" unless buffer.nil? || buffer.is_a?(String)
          raise TooLarge, @limit if @exceeded

          data = if length.nil?
                   all = String.new(encoding: Encoding::BINARY)
                   while (chunk = read_chunk(CHUNK_BYTES))
                     break if chunk.empty?

                     all << chunk
                   end
                   all
                 elsif length.zero?
                   "".b
                 else
                   read_chunk(length)
                 end
          buffer.replace(data || "") if buffer
          data.nil? ? nil : (buffer || data)
        end

        def gets
          line = String.new(encoding: Encoding::BINARY)
          while (byte = read(1))
            line << byte
            break if byte == "\n"
          end
          line unless line.empty?
        end

        def each
          return enum_for(:each) unless block_given?

          while (line = gets)
            yield line
          end
          self
        end

        def close
          @input.close if @input.respond_to?(:close)
        end

        private

        def read_chunk(requested)
          raise TooLarge, @limit if @exceeded

          data = @input.read([requested, @limit - @offset + 1].min)
          return nil if data.nil?

          @offset += data.bytesize
          if @offset > @limit
            @exceeded = true
            raise TooLarge, @limit
          end
          data.b
        end
      end

      # Limits and rule values may be callables of the trusted environment.
      # A response callback receives status, message and environment.
      def initialize(app, max:, rules: [], response: nil)
        @app = app
        @max = max
        @rules = rules
        @response = response
      end

      def call(env)
        configured = false
        limit = limit_for(env)
        declared = env["CONTENT_LENGTH"].to_s.strip
        unless declared.empty? || /\A[0-9]+\z/.match?(declared)
          return refuse(400, "Invalid Content-Length.", env)
        end
        return refuse(413, TooLarge.new(limit).message, env) if !declared.empty? && declared.to_i > limit

        original_input = env["rack.input"]
        input = original_input && Input.new(original_input, limit)
        env["rack.input"] = input if input
        had_factory = env.key?("rack.multipart.tempfile_factory")
        original_factory = env["rack.multipart.tempfile_factory"]
        created = []
        require "rack/multipart"
        factory = original_factory || ::Rack::Multipart::Parser::TEMPFILE_FACTORY
        env["rack.multipart.tempfile_factory"] = lambda do |*args|
          factory.call(*args).tap { |file| created << file }
        end
        configured = true

        result = @app.call(env)
        if input&.exceeded
          result[2].close if result[2].respond_to?(:close)
          cleanup(env, created)
          return refuse(413, TooLarge.new(limit).message, env)
        end
        cleanup(env, created) if result[0].to_i >= 400
        result
      rescue TooLarge => e
        cleanup(env, created || [])
        refuse(413, e.message, env)
      rescue StandardError
        cleanup(env, created || [])
        raise
      ensure
        env["rack.input"] = original_input if defined?(original_input) && original_input
        if configured
          had_factory ? env["rack.multipart.tempfile_factory"] = original_factory : env.delete("rack.multipart.tempfile_factory")
        end
      end

      private

      def limit_for(env)
        rule = @rules.find { |pattern, _| pattern.match?(env["PATH_INFO"].to_s) }
        value = rule ? rule.last : @max
        limit = (value.respond_to?(:call) ? value.call(env) : value).to_i
        raise ArgumentError, "body limit must be positive" unless limit.positive?

        limit
      end

      def cleanup(env, created)
        (created + Array(env["rack.tempfiles"])).uniq.each do |file|
          if file.respond_to?(:close!)
            file.close!
          else
            file.close if file.respond_to?(:close)
            file.unlink if file.respond_to?(:unlink)
          end
        rescue IOError, SystemCallError
          nil
        end
        env["rack.tempfiles"] = []
      end

      def refuse(status, message, env)
        return @response.call(status, message, env) if @response

        body = "#{message}\n"
        [status,
         { "content-type" => "text/plain", "content-length" => body.bytesize.to_s, "connection" => "close" },
         [body]]
      end
    end
  end
end
