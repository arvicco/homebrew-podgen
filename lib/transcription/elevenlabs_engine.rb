# frozen_string_literal: true

require "httparty"
require "json"
require_relative "base_engine"

module Transcription
  class ElevenlabsEngine < BaseEngine
    ENDPOINT = "https://api.elevenlabs.io/v1/speech-to-text"

    def initialize(language: "sl", logger: nil)
      super
      @api_key = ENV.fetch("ELEVENLABS_API_KEY") { raise "ELEVENLABS_API_KEY not set" }
      @model = ENV.fetch("ELEVENLABS_SCRIBE_MODEL", "scribe_v2")
    end

    def engine_name
      "elab"
    end

    def transcribe(audio_path)
      validate_audio!(audio_path)

      size_mb = (File.size(audio_path) / (1024.0 * 1024)).round(2)
      log("Transcribing #{audio_path} (#{size_mb} MB, model: #{@model}, language: #{@language})")

      retries = 0
      begin
        retries += 1
        start = Time.now

        body = {
          file: File.open(audio_path, "rb"),
          model_id: @model,
          language_code: @language,
          timestamps_granularity: "word"
        }

        response = HTTParty.post(
          ENDPOINT,
          headers: { "xi-api-key" => @api_key },
          multipart: true,
          body: body,
          timeout: TIMEOUT
        )

        elapsed = (Time.now - start).round(2)

        unless response.success?
          raise "ElevenLabs Scribe API error #{response.code}: #{response.body}"
        end

        result = JSON.parse(response.body)
        transcript = result["text"] || ""

        segments = build_segments_from_words(result["words"] || [])

        speech_start = segments.any? ? segments.first[:start] : 0.0
        speech_end = segments.any? ? segments.last[:end] : 0.0

        log("Transcription complete in #{elapsed}s (#{transcript.length} chars, #{segments.length} segments)")

        { text: transcript, speech_start: speech_start, speech_end: speech_end, segments: segments }

      rescue => e
        if retries <= MAX_RETRIES && retryable?(e)
          sleep_time = 2**retries
          log("Error (attempt #{retries}/#{MAX_RETRIES}): #{e.message}. Retrying in #{sleep_time}s...")
          sleep(sleep_time)
          retry
        end
        raise "ElevenlabsEngine failed after #{retries} attempts: #{e.message}"
      end
    end

    private

    # Aggregates word-level timestamps into sentence-level segments.
    # Splits on sentence-ending punctuation (.!?).
    def build_segments_from_words(words)
      return [] if words.empty?

      segments = []
      current_words = []
      current_start = nil

      words.each do |w|
        text = w["text"] || w["word"] || ""
        word_start = w["start"].to_f
        word_end = w["end"].to_f

        current_start ||= word_start
        current_words << text

        if text.match?(/[.!?]\s*$/)
          segments << {
            start: current_start,
            end: word_end,
            text: current_words.join(" ").strip,
            no_speech_prob: 0.0,
            compression_ratio: 0.0,
            avg_logprob: 0.0
          }
          current_words = []
          current_start = nil
        end
      end

      # Flush remaining words as a final segment
      if current_words.any?
        last_word = words.last
        segments << {
          start: current_start,
          end: last_word["end"].to_f,
          text: current_words.join(" ").strip,
          no_speech_prob: 0.0,
          compression_ratio: 0.0,
          avg_logprob: 0.0
        }
      end

      segments
    end
  end
end
