# frozen_string_literal: true

require_relative "glosser"
require_relative "translator"

module Tell
  # Thread-safe cache for Glosser and TranslatorChain instances.
  # Shared at the Sinatra app level so objects survive across requests,
  # avoiding per-request HTTP client and connection pool setup.
  class EnginePool
    def initialize
      @glossers = {}
      @glosser_mutex = Mutex.new
      @translators = {}
      @translator_mutex = Mutex.new
    end

    # Return a cached Glosser for the given model_id, creating one if needed.
    def glosser(model_id)
      @glosser_mutex.synchronize do
        @glossers[model_id] ||= begin
          key = ENV["ANTHROPIC_API_KEY"]
          raise "Gloss requires ANTHROPIC_API_KEY" unless key
          Glosser.new(key, model: model_id)
        end
      end
    end

    # Return a cached TranslatorChain for the given config attributes.
    # Cache key uses engine names + timeout only — api_keys are fixed per
    # engine for the lifetime of the process (ENV-based), so engines alone
    # are sufficient to identify the chain.
    def translator(engines:, api_keys:, timeout:)
      cache_key = [engines, timeout]
      @translator_mutex.synchronize do
        @translators[cache_key] ||= Tell.build_translator_chain(
          engines, api_keys, timeout: timeout
        )
      end
    end
  end
end
