# frozen_string_literal: true

module Fakes
  # Stands in for {Rubotty::Adapters::Telegram::BotApi}: records every request
  # and replies from a scripted queue.
  class TelegramHttp
    Request = Struct.new(:method_name, :params)

    def initialize
      @responses = Hash.new { |hash, key| hash[key] = [] }
      @default = { "ok" => true, "result" => { "message_id" => 1 } }
      @requests = []
    end

    attr_reader :requests

    # Queue a successful response for one call to +method_name+.
    def on(method_name, result)
      @responses[method_name] << { "ok" => true, "result" => result }
      self
    end

    # Queue a Telegram style error.
    def error_on(method_name, code:, description:, parameters: nil)
      payload = { "ok" => false, "error_code" => code, "description" => description }
      payload["parameters"] = parameters if parameters
      @responses[method_name] << payload
      self
    end

    def default_result(result)
      @default = { "ok" => true, "result" => result }
      self
    end

    # Params are recorded as they cross the wire, so a symbol key and a symbol
    # keyed nested hash read back as the strings every spec asserts on.
    def call(method_name, params)
      @requests << Request.new(method_name, JSON.parse(JSON.generate(params)))
      @responses[method_name].shift || @default
    end

    def calls(method_name)
      @requests.select { |request| request.method_name == method_name }
    end

    def last(method_name) = calls(method_name).last

    def called?(method_name) = calls(method_name).any?
  end

  # Stands in for Rubotty::Adapters::ApiWrapper::Client: records every #post
  # call and answers whatever has been queued, a plain 200 by default, so
  # neither the adapter contract nor the adapter's own spec ever opens a
  # real socket.
  class ApiWrapperClient
    Call = Struct.new(:type, :data, keyword_init: true)

    def initialize
      @calls = []
      @responses = []
    end

    attr_reader :calls

    def queue(response) = @responses << response

    def post(type:, data:)
      @calls << Call.new(type: type, data: data)
      @responses.shift || Rubotty::Adapters::ApiWrapper::Client::Response.new(status: 200, body: "")
    end
  end

  # Collects messages instead of dispatching them.
  class RecordingDispatcher
    def initialize
      @messages = []
    end

    attr_reader :messages

    def call(message)
      @messages << message
      message
    end
    alias << call

    def last = @messages.last
  end

  # A minimal adapter for router and dispatcher specs: records what it was asked
  # to deliver and hands back predictable ids.
  class RecordingAdapter < Rubotty::Adapters::Base
    class << self
      def adapter_name = :fake

      def account_schema
        Rubotty::Config::Schema.define do
          field :token_env, :string, required: true, env: true
        end
      end

      def endpoint_schema
        Rubotty::Config::Schema.define do
          field :room_key, :string, required: true
        end
      end
    end

    CAPABILITIES = Rubotty::Adapters::Capabilities.new(edits: true, deletes: true, replies: true).freeze

    def initialize(account: "default", settings: {}, dispatcher: nil, logger: nil, endpoints: [],
                   own_id: "bot-1", admin_dm: false, admin_dm_delete: true, admin_dm_delete_succeeds: true)
      super(account: account, settings: settings, dispatcher: dispatcher,
            logger: logger || Rubotty::Log.null, endpoints: endpoints)
      @own_id = own_id
      @delivered = []
      @edited = []
      @deleted = []
      @counter = 0
      @fail_with = nil
      @admin_dm = admin_dm
      @admin_dm_delete = admin_dm_delete
      @admin_dm_delete_succeeds = admin_dm_delete_succeeds
      @dms_sent = []
      @dms_deleted = []
    end

    attr_reader :delivered, :edited, :deleted, :dms_sent, :dms_deleted

    def fail_next(error) = (@fail_with = error)

    def capabilities = CAPABILITIES

    def own_account_id = @own_id

    def start = self

    def stop = self

    def running? = true

    def deliver(message, endpoint)
      raise_pending!
      @counter += 1
      @delivered << [endpoint.id, message]
      Rubotty::Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: "d#{@counter}")
    end

    def edit(message, endpoint, native_id)
      raise_pending!
      @edited << [endpoint.id, native_id, message]
      Rubotty::Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: native_id)
    end

    def delete(endpoint, native_id)
      raise_pending!
      @deleted << [endpoint.id, native_id]
      nil
    end

    def delivered_to(endpoint_id)
      @delivered.select { |(id, _)| id == endpoint_id }.map(&:last)
    end

    # ------------------------------------------------------------------
    # admin DM
    # ------------------------------------------------------------------

    def supports_admin_dm? = @admin_dm

    def supports_admin_dm_delete? = @admin_dm_delete

    def send_admin_dm(native_id, text)
      raise_pending!
      return nil unless @admin_dm
      return nil if text.to_s.strip.empty?

      @counter += 1
      @dms_sent << { native_id: native_id, text: text }
      Rubotty::Core::DmReceipt.new(native_id: "dm#{@counter}", channel_ref: "chan-#{native_id}")
    end

    def delete_admin_dm(receipt)
      raise_pending!
      return false if receipt.nil? || !@admin_dm_delete_succeeds

      @dms_deleted << receipt.native_id
      true
    end

    private

    def raise_pending!
      return if @fail_with.nil?

      error = @fail_with
      @fail_with = nil
      raise error
    end
  end

  # An adapter that also does reactions and moderation.
  class ReactingAdapter < RecordingAdapter
    CAPABILITIES = Rubotty::Adapters::Capabilities.new(
      edits: true, deletes: true, replies: true, reactions: true, custom_reactions: true,
      moderation: Rubotty::Core::Moderation::ACTIONS
    ).freeze

    def initialize(**)
      super
      @syncs = []
      @moderations = []
    end

    attr_reader :syncs, :moderations

    def capabilities = CAPABILITIES

    def sync_reactions(endpoint, native_id, desired:, previous: [])
      raise_pending!
      @syncs << { endpoint_id: endpoint.id, native_id: native_id,
                  desired: desired, previous: previous }
      nil
    end

    def moderate(command, endpoint, native_id)
      @moderations << {
        action: command.action, endpoint_id: endpoint.id,
        native_id: native_id, target_user_id: command.target_user_id, arguments: command.arguments
      }
      # Mirror the real adapters: a delete action removes the target message,
      # while pin, ban and the rest leave it in place.
      delete(endpoint, native_id) if command.action == :delete && native_id
      Rubotty::Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :done)
    end
  end
end
