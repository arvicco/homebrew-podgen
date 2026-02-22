# frozen_string_literal: true

require_relative "openai_engine"
require_relative "elevenlabs_engine"
require_relative "groq_engine"
require_relative "reconciler"

module Transcription
  class EngineManager
    REGISTRY = {
      "open" => OpenaiEngine,
      "elab" => ElevenlabsEngine,
      "groq" => GroqEngine
    }.freeze

    def initialize(engine_codes:, language: "sl", target_language: nil, logger: nil)
      @engine_codes = engine_codes
      @language = language
      @target_language = target_language
      @logger = logger
    end

    # Single engine: returns { text:, segments:, speech_start:, speech_end:, cleaned: }
    # Comparison mode (2+ engines): returns { primary:, all: { "open" => {...}, ... }, errors: {}, reconciled: }
    def transcribe(audio_path)
      if @engine_codes.length == 1
        result = build_engine(@engine_codes.first).transcribe(audio_path)
        result[:cleaned] = run_cleanup(result[:text])
        result
      else
        transcribe_comparison(audio_path)
      end
    end

    private

    def transcribe_comparison(audio_path)
      results = {}
      errors = {}

      threads = @engine_codes.map do |code|
        Thread.new(code) do |c|
          Thread.current[:engine] = c
          engine = build_engine(c)
          log("Starting engine: #{c}")
          start = Time.now
          results[c] = engine.transcribe(audio_path)
          elapsed = (Time.now - start).round(2)
          log("Engine '#{c}' completed in #{elapsed}s")
        rescue => e
          errors[c] = e.message
          log("Engine '#{c}' failed: #{e.message}")
        end
      end

      threads.each(&:join)

      primary_code = @engine_codes.first
      primary_result = results[primary_code]

      unless primary_result
        raise "Primary engine '#{primary_code}' failed: #{errors[primary_code]}"
      end

      comparison = {
        primary: primary_result,
        all: results,
        errors: errors,
        reconciled: nil
      }

      # Reconcile if 2+ engines succeeded
      if results.size >= 2
        begin
          texts = results.transform_values { |r| r[:text] }
          comparison[:reconciled] = build_reconciler.reconcile(texts)
        rescue => e
          log("Reconciliation failed (non-fatal): #{e.message}")
        end
      end

      comparison
    end

    def run_cleanup(text)
      build_reconciler.cleanup(text)
    rescue => e
      log("Cleanup failed (non-fatal): #{e.message}")
      nil
    end

    def build_reconciler
      Reconciler.new(language: @target_language || @language, logger: @logger)
    end

    def build_engine(code)
      klass = REGISTRY[code]
      raise "Unknown transcription engine: #{code}" unless klass

      klass.new(language: @language, logger: @logger)
    end

    def log(message)
      if @logger
        @logger.log("[EngineManager] #{message}")
      else
        puts "[EngineManager] #{message}"
      end
    end
  end
end
