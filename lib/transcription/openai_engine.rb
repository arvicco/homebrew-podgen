# frozen_string_literal: true

require "httparty"
require "json"
require_relative "base_engine"

module Transcription
  class OpenaiEngine < BaseEngine
    # Models that support verbose_json with segments/timestamps.
    # gpt-4o-transcribe family only supports json/text — no segments.
    VERBOSE_MODELS = %w[whisper-1].freeze

    def initialize(language: "sl", logger: nil)
      super
      @api_key = ENV.fetch("OPENAI_API_KEY") { raise "OPENAI_API_KEY not set" }
      @model = ENV.fetch("WHISPER_MODEL", "gpt-4o-mini-transcribe")
    end

    def engine_name
      "open"
    end

    def transcribe(audio_path)
      validate_audio!(audio_path)

      size_mb = (File.size(audio_path) / (1024.0 * 1024)).round(2)
      log("Transcribing #{audio_path} (#{size_mb} MB, model: #{@model}, language: #{@language})")

      retries = 0
      begin
        retries += 1
        start = Time.now

        verbose = VERBOSE_MODELS.include?(@model)
        body = {
          file: File.open(audio_path, "rb"),
          model: @model,
          language: @language,
          response_format: verbose ? "verbose_json" : "json"
        }

        response = HTTParty.post(
          "https://api.openai.com/v1/audio/transcriptions",
          headers: { "Authorization" => "Bearer #{@api_key}" },
          multipart: true,
          body: body,
          timeout: TIMEOUT
        )

        elapsed = (Time.now - start).round(2)

        unless response.success?
          raise "Transcription API error #{response.code}: #{response.body}"
        end

        result = JSON.parse(response.body)
        transcript = result["text"]

        if verbose
          parse_verbose_result(result, transcript, elapsed)
        else
          log("Transcription complete in #{elapsed}s (#{transcript.length} chars)")
          { text: transcript, speech_start: 0.0, speech_end: 0.0, segments: [] }
        end

      rescue => e
        if retries <= MAX_RETRIES && retryable?(e)
          sleep_time = 2**retries
          log("Error (attempt #{retries}/#{MAX_RETRIES}): #{e.message}. Retrying in #{sleep_time}s...")
          sleep(sleep_time)
          retry
        end
        raise "OpenaiEngine failed after #{retries} attempts: #{e.message}"
      end
    end

    private

    def parse_verbose_result(result, transcript, elapsed)
      duration = result["duration"]&.round(1)
      segments = result["segments"] || []

      parsed_segments = segments.map do |s|
        {
          start: s["start"].to_f,
          end: s["end"].to_f,
          text: s["text"].to_s,
          no_speech_prob: s["no_speech_prob"].to_f,
          compression_ratio: s["compression_ratio"].to_f,
          avg_logprob: s["avg_logprob"].to_f
        }
      end

      speech_start = parsed_segments.any? ? parsed_segments.first[:start] : 0.0
      speech_end = parsed_segments.any? ? parsed_segments.last[:end] : (duration || 0.0)

      log("Transcription complete in #{elapsed}s (audio duration: #{duration}s, #{transcript.length} chars, #{parsed_segments.length} segments)")
      log("Speech boundaries: #{speech_start.round(1)}s → #{speech_end.round(1)}s")

      { text: transcript, speech_start: speech_start, speech_end: speech_end, segments: parsed_segments }
    end
  end
end
