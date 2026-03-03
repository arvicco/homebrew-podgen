# frozen_string_literal: true

require "yaml"

module Tell
  class Config
    REQUIRED_KEYS = %w[original_language target_language voice_id].freeze
    VALID_TRANSLATION_ENGINES = %w[deepl claude openai].freeze
    VALID_TTS_ENGINES = %w[elevenlabs google].freeze
    CONFIG_PATH = File.expand_path("~/.tell.yml")

    TRANSLATION_API_KEYS = {
      "deepl"  => { config: "deepl_auth_key",    env: "DEEPL_AUTH_KEY" },
      "claude" => { config: "anthropic_api_key",  env: "ANTHROPIC_API_KEY" },
      "openai" => { config: "openai_api_key",     env: "OPENAI_API_KEY" }
    }.freeze

    attr_reader :original_language, :target_language, :voice_id,
                :translation_engine, :tts_engine,
                :model_id, :output_format,
                :api_key, :tts_api_key, :google_language_code

    def initialize(overrides: {})
      data = load_config
      validate!(data)

      @original_language  = overrides[:from] || data["original_language"]
      @target_language    = overrides[:to]   || data["target_language"]
      @voice_id           = overrides[:voice] || data["voice_id"]
      @translation_engine = data.fetch("translation_engine", "deepl")
      @tts_engine         = overrides[:tts_engine] || data.fetch("tts_engine", "elevenlabs")
      @model_id           = data.fetch("model_id", "eleven_multilingual_v2")
      @output_format      = data.fetch("output_format", "mp3_44100_128")

      validate_translation_engine!
      validate_tts_engine!
      resolve_translation_api_key!(data)
      resolve_tts_api_key!(data)
    end

    def engine_api_key
      @engine_api_key
    end

    private

    def load_config
      unless File.exist?(CONFIG_PATH)
        raise <<~MSG
          Config file not found: #{CONFIG_PATH}

          Create ~/.tell.yml with:

            original_language: en
            target_language: sl
            voice_id: "your_voice_id"
            tts_engine: elevenlabs        # elevenlabs | google
            translation_engine: deepl     # deepl | claude | openai

          ElevenLabs example:
            voice_id: "elevenlabs_voice_id"
            # ELEVENLABS_API_KEY env required

          Google TTS example:
            tts_engine: google
            voice_id: "sl-SI-Wavenet-A"
            # google_language_code: sl-SI  # auto-derived from target_language if omitted
            # google_api_key: "..."        # or GOOGLE_API_KEY env
        MSG
      end

      YAML.load_file(CONFIG_PATH) || {}
    end

    def validate!(data)
      missing = REQUIRED_KEYS.select { |k| data[k].nil? || data[k].to_s.empty? }
      return if missing.empty?

      raise "Missing required config keys in #{CONFIG_PATH}: #{missing.join(', ')}"
    end

    def validate_translation_engine!
      return if VALID_TRANSLATION_ENGINES.include?(@translation_engine)

      raise "Invalid translation_engine '#{@translation_engine}'. Must be one of: #{VALID_TRANSLATION_ENGINES.join(', ')}"
    end

    def validate_tts_engine!
      return if VALID_TTS_ENGINES.include?(@tts_engine)

      raise "Invalid tts_engine '#{@tts_engine}'. Must be one of: #{VALID_TTS_ENGINES.join(', ')}"
    end

    def resolve_translation_api_key!(data)
      key_info = TRANSLATION_API_KEYS[@translation_engine]
      @engine_api_key = data[key_info[:config]] || ENV[key_info[:env]]

      return if @engine_api_key

      raise "#{@translation_engine} translation requires #{key_info[:env]} (set in env or as '#{key_info[:config]}' in #{CONFIG_PATH})"
    end

    def resolve_tts_api_key!(data)
      case @tts_engine
      when "elevenlabs"
        @api_key = data["elevenlabs_api_key"] || ENV["ELEVENLABS_API_KEY"]
        raise "ElevenLabs requires ELEVENLABS_API_KEY" unless @api_key
      when "google"
        @api_key = nil
        @tts_api_key = data["google_api_key"] || ENV["GOOGLE_API_KEY"]
        raise "Google TTS requires GOOGLE_API_KEY (set in env or as 'google_api_key' in #{CONFIG_PATH})" unless @tts_api_key
        @google_language_code = data["google_language_code"] || derive_google_language_code
      end
    end

    def derive_google_language_code
      require_relative "tts"
      GoogleTts::LANGUAGE_CODES.fetch(@target_language) do
        raise "No Google language code mapping for '#{@target_language}'. Set 'google_language_code' explicitly in #{CONFIG_PATH}"
      end
    end
  end
end
