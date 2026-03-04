# frozen_string_literal: true

require "httparty"
require "json"
require "base64"
require_relative "colors"

module Tell
  def self.build_tts(engine, config)
    case engine
    when "elevenlabs" then ElevenlabsTts.new(config)
    when "google"     then GoogleTts.new(config)
    else raise "Unknown tts_engine: #{engine}"
    end
  end

  class ElevenlabsTts
    BASE_URL = "https://api.elevenlabs.io/v1/text-to-speech"
    MAX_RETRIES = 2
    RETRIABLE_CODES = [429, 503].freeze

    def initialize(config)
      @api_key       = config.api_key
      @voice_id      = config.voice_id
      @model_id      = config.model_id
      @output_format = config.output_format
    end

    def synthesize(text)
      url = "#{BASE_URL}/#{@voice_id}?output_format=#{@output_format}"

      body = {
        text: text,
        model_id: @model_id,
        voice_settings: {
          stability: 0.5,
          similarity_boost: 0.75,
          style: 0.0,
          use_speaker_boost: true
        }
      }

      retries = 0
      begin
        retries += 1

        response = HTTParty.post(
          url,
          headers: {
            "xi-api-key" => @api_key,
            "Content-Type" => "application/json"
          },
          body: body.to_json,
          timeout: 60
        )

        case response.code
        when 200
          response.body
        when *RETRIABLE_CODES
          raise RetriableError, "HTTP #{response.code}: #{parse_error(response)}"
        else
          raise "ElevenLabs TTS failed: HTTP #{response.code}: #{parse_error(response)}"
        end

      rescue RetriableError, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET => e
        if retries <= MAX_RETRIES
          sleep_time = 2**retries
          $stderr.puts Colors.status("Retry #{retries}/#{MAX_RETRIES} in #{sleep_time}s: #{e.message}")
          sleep(sleep_time)
          retry
        else
          raise "ElevenLabs TTS failed after #{MAX_RETRIES} retries: #{e.message}"
        end
      end
    end

    private

    def parse_error(response)
      parsed = JSON.parse(response.body)
      detail = parsed["detail"]
      detail.is_a?(Hash) ? "#{detail['code']}: #{detail['message']}" : detail.to_s
    rescue JSON::ParserError
      response.body[0..200]
    end

    class RetriableError < StandardError; end
  end

  class GoogleTts
    BASE_URL = "https://texttospeech.googleapis.com/v1/text:synthesize"
    MAX_RETRIES = 2
    RETRIABLE_CODES = [429, 503].freeze

    # Map ISO 639-1 codes to Google BCP-47 language codes
    LANGUAGE_CODES = {
      "sl" => "sl-SI", "en" => "en-US", "de" => "de-DE", "fr" => "fr-FR",
      "es" => "es-ES", "it" => "it-IT", "pt" => "pt-BR", "nl" => "nl-NL",
      "pl" => "pl-PL", "ja" => "ja-JP", "ko" => "ko-KR", "zh" => "cmn-CN",
      "ru" => "ru-RU", "uk" => "uk-UA", "cs" => "cs-CZ", "hr" => "hr-HR",
      "sr" => "sr-RS", "bg" => "bg-BG", "sk" => "sk-SK", "ro" => "ro-RO",
      "hu" => "hu-HU", "tr" => "tr-TR", "ar" => "ar-XA", "hi" => "hi-IN",
      "th" => "th-TH", "vi" => "vi-VN", "id" => "id-ID", "fi" => "fi-FI",
      "sv" => "sv-SE", "da" => "da-DK", "no" => "nb-NO", "el" => "el-GR",
      "he" => "he-IL"
    }.freeze

    def initialize(config)
      @api_key       = config.tts_api_key
      @voice_name    = config.voice_id
      @language_code = config.google_language_code
    end

    def synthesize(text)
      url = "#{BASE_URL}?key=#{@api_key}"

      body = {
        input: { text: text },
        voice: { languageCode: @language_code, name: @voice_name },
        audioConfig: { audioEncoding: "MP3" }
      }

      retries = 0
      begin
        retries += 1

        response = HTTParty.post(
          url,
          headers: { "Content-Type" => "application/json" },
          body: body.to_json,
          timeout: 60
        )

        case response.code
        when 200
          data = JSON.parse(response.body)
          Base64.decode64(data["audioContent"])
        when *RETRIABLE_CODES
          raise RetriableError, "HTTP #{response.code}: #{parse_error(response)}"
        else
          raise "Google TTS failed: HTTP #{response.code}: #{parse_error(response)}"
        end

      rescue RetriableError, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET => e
        if retries <= MAX_RETRIES
          sleep_time = 2**retries
          $stderr.puts Colors.status("Retry #{retries}/#{MAX_RETRIES} in #{sleep_time}s: #{e.message}")
          sleep(sleep_time)
          retry
        else
          raise "Google TTS failed after #{MAX_RETRIES} retries: #{e.message}"
        end
      end
    end

    private

    def parse_error(response)
      parsed = JSON.parse(response.body)
      err = parsed["error"]
      err.is_a?(Hash) ? "#{err['code']}: #{err['message']}" : parsed.to_s
    rescue JSON::ParserError
      response.body[0..200]
    end

    class RetriableError < StandardError; end
  end
end
