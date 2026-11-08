# frozen_string_literal: true

module Rubotty
  module OpenArc
    # One deployment-wide OpenArc connection. The control-plane store is read
    # for every request, so an administrator can rotate its address, key or
    # model without restarting the bridge.
    class Settings
      # What a deployment runs before anybody picks a model on the Integrations
      # page, so a connection saved before the choice existed behaves as it did.
      DEFAULT_MODEL = "Qwen3-4B-Instruct-2507-int4_asym-awq-ov"

      # Everything /openarc/load has to be told before it will put a model back,
      # which is the same set the Integrations page's load form asks an operator
      # for. cache_dir is absent because it is optional in both places.
      SPEC_FIELDS = %w[model_path model_name model_type engine device].freeze

      # @param store [#url, #api_key, #model, #reload_spec, nil] the
      #   Integrations-page adapter
      def initialize(store: nil)
        @store = store
      end

      def url = presence(@store&.url)

      def api_key = presence(@store&.api_key)

      # The model every completion names.
      def model = chosen_model || DEFAULT_MODEL

      # Whether a model was really chosen, as against falling back, so the
      # Integrations page can say nothing has been picked rather than implying
      # the default was somebody's decision.
      def model_chosen? = !chosen_model.nil?

      def configured? = !url.nil?

      # What it takes to put {#model} back after the server dropped it: the
      # load form's own fields, kept from a load that worked rather than typed
      # again, so what is replayed is what this server has already accepted.
      # Nil unless the whole recipe is there AND it names the model completions
      # ask for, since reloading another model would put back what nobody asked
      # for and leave the failure exactly where it was.
      #
      # @return [Hash, nil] string-keyed, ready to splat at Client#load_model
      def reload_spec
        raw = stored_reload_spec
        return nil unless raw

        spec = SPEC_FIELDS.to_h { |field| [field, presence(raw[field])] }
        return nil if spec.any? { |_, value| value.nil? }
        return nil unless spec["model_name"] == model

        cache_dir = presence(raw["cache_dir"])
        cache_dir ? spec.merge("cache_dir" => cache_dir) : spec
      end

      # Whether a model this deployment finds missing can be put back without
      # an operator being present to do it.
      def reloadable? = !reload_spec.nil?

      # The recipe as it is stored, whole or not and whatever model it names,
      # for a page that has to show an operator what is kept rather than decide
      # whether to act on it. {#reload_spec} is the one to act on.
      #
      # @return [Hash, nil]
      def stored_reload_spec
        return nil unless @store.respond_to?(:reload_spec)

        raw = @store.reload_spec
        raw.is_a?(Hash) && !raw.empty? ? raw : nil
      end

      private

      # Older stores predate the model field, so the store is asked whether it
      # carries one rather than assumed to.
      def chosen_model
        return nil unless @store.respond_to?(:model)

        presence(@store.model)
      end

      def presence(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end
    end
  end
end
