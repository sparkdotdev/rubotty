# frozen_string_literal: true

require "spec_helper"
require "rack/mock"
require "stringio"
require "tempfile"

RSpec.describe Rubotty::Util::BodyLimit, "streamed input" do
  let(:input_class) do
    Class.new(StringIO) do
      attr_reader :bytes_read, :read_sizes
      def initialize(bytes)
        super(bytes.b)
        @bytes_read, @read_sizes = 0, []
      end
      def read(*args)
        @read_sizes << args.first
        super.tap { |bytes| @bytes_read += bytes.to_s.bytesize }
      end
    end
  end

  def request_env(body, length: nil, type: "application/octet-stream")
    input = input_class.new(body)
    env = Rack::MockRequest.env_for("/finite", method: "POST", "CONTENT_TYPE" => type)
    env["rack.input"] = input
    length.nil? ? env.delete("CONTENT_LENGTH") : env["CONTENT_LENGTH"] = length.to_s
    [env, input]
  end

  def consuming_app(limit: 100, &reader)
    described_class.new(lambda { |env|
      reader ? reader.call(env["rack.input"]) : env["rack.input"].read
      [200, { "content-type" => "text/plain" }, ["ok"]]
    }, max: limit)
  end

  it "caps an unknown-length body's actual bytes at the limit plus its one-byte check" do
    env, input = request_env("x" * 1_000)

    expect(consuming_app.call(env).first).to eq(413)
    expect(input.bytes_read).to eq(101)
    expect(input.read_sizes).to all(be <= 101)
  end

  it "does not trust an understated declared length" do
    env, input = request_env("x" * 1_000, length: 1)

    expect(consuming_app.call(env).first).to eq(413)
    expect(input.bytes_read).to eq(101)
  end

  it "bounds a consumer's oversized individual read before calling the underlying IO" do
    env, input = request_env("x" * 1_000)

    expect(consuming_app { |stream| stream.read(1_000_000) }.call(env).first).to eq(413)
    expect(input.read_sizes).to eq([101])
    expect(input.bytes_read).to eq(101)
  end

  it "rejects a malformed declared length without reading or dispatching" do
    env, input = request_env("x" * 1_000, length: "10invalid")
    reached = false
    result = consuming_app { reached = true }.call(env)

    expect(result.first).to eq(400)
    expect(reached).to be(false)
    expect(input.bytes_read).to eq(0)
  end

  it "keeps a body at its exact cap valid even when it is read twice" do
    env, input = request_env("x" * 100)
    result = consuming_app do |stream|
      expect(stream.read).to eq("x" * 100)
      stream.rewind
      buffer = +"old"
      expect(stream.read(nil, buffer)).to equal(buffer)
      expect(buffer).to eq("x" * 100)
      expect(stream.read).to eq("")
      expect(stream.read(1, buffer)).to be_nil
      expect(buffer).to eq("")
    end.call(env)

    expect(result.first).to eq(200)
    expect(input.bytes_read).to eq(200)
  end

  it "caps gets and each instead of exposing the underlying unbounded line reader" do
    env, input = request_env("a\n" * 100)

    expect(consuming_app { |stream| stream.each.to_a }.call(env).first).to eq(413)
    expect(input.bytes_read).to eq(101)
  end

  it "does not expose rewind for an input that cannot rewind" do
    source = Object.new
    bytes = "abc".b
    source.define_singleton_method(:read) { |size| bytes.empty? ? nil : bytes.slice!(0, size) }
    input = described_class::Input.new(source, 3)

    expect(input).not_to respond_to(:rewind)
    expect(input.read).to eq("abc")
  end

  it "keeps the rejection when an inner app catches the input limit exception" do
    env, input = request_env("x" * 1_000)
    app = consuming_app do |stream|
      begin
        stream.read
      rescue described_class::TooLarge
        nil
      end
    end

    expect(app.call(env).first).to eq(413)
    expect(input.bytes_read).to eq(101)
  end

  it "cleans partial multipart files on malformed input as well as size rejection" do
    body = "--finite\r\nContent-Disposition: form-data; name=\"file\"; filename=\"fixture.bin\"\r\n\r\n#{'x' * (32 * 1024)}"
    env, = request_env(body, type: "multipart/form-data; boundary=finite")
    env["rack.multipart.buffer_size"] = 4 * 1024
    created = []
    env["rack.multipart.tempfile_factory"] = lambda do |*|
      Tempfile.new("finite-malformed-body").tap { |file| created << [file, file.path] }
    end
    app = described_class.new(->(request) { Rack::Request.new(request).POST; [200, {}, ["ok"]] }, max: 128 * 1024)

    expect { app.call(env) }.to raise_error(EOFError)
    expect(created).not_to be_empty
    created.each do |file, path|
      expect(file).to be_closed
      expect(File.exist?(path)).to be(false)
    end
  ensure
    created&.each { |file, _| file.close! }
  end

  it "cleans partial multipart tempfiles when actual bytes exceed the cap" do
    boundary = "finite-local-boundary"
    body = "--#{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"fixture.bin\"\r\n" \
           "Content-Type: application/octet-stream\r\n\r\n#{'x' * (256 * 1024)}\r\n--#{boundary}--\r\n"
    env, input = request_env(body, type: "multipart/form-data; boundary=#{boundary}")
    env["rack.multipart.buffer_size"] = 16 * 1024
    created = []
    original_factory = lambda do |*|
      Tempfile.new("finite-body-limit").tap { |file| created << [file, file.path] }
    end
    env["rack.multipart.tempfile_factory"] = original_factory
    inner = ->(request) { Rack::Request.new(request).POST; [200, {}, ["ok"]] }
    app = described_class.new(inner, max: 128 * 1024)

    expect(app.call(env).first).to eq(413)
    expect(input.bytes_read).to eq(128 * 1024 + 1)
    expect(created).not_to be_empty
    created.each do |file, path|
      expect(file).to be_closed
      expect(File.exist?(path)).to be(false)
    end
    expect(env["rack.tempfiles"]).to eq([])
    expect(env["rack.multipart.tempfile_factory"]).to equal(original_factory)
  ensure
    created&.each { |file, _| file.close! }
  end
end
