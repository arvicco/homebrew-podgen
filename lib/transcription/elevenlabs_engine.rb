# frozen_string_literal: true

require "httparty"
require "json"
require_relative "base_engine"
require_relative "../timestamp_persister"

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
      log_transcription_start(audio_path)

      with_engine_retries do
        start = Time.now

        audio_file = File.open(audio_path, "rb")
        body = {
          file: audio_file,
          model_id: @model,
          language_code: @language,
          timestamps_granularity: "word"
        }

        response = begin
          HTTParty.post(
            ENDPOINT,
            headers: { "xi-api-key" => @api_key },
            multipart: true,
            body: body,
            timeout: TIMEOUT
          )
        ensure
          audio_file.close
        end

        elapsed = (Time.now - start).round(2)

        unless response.success?
          raise ApiError.for(response.code, "ElevenLabs Scribe API error #{response.code}: #{response.body}")
        end

        result = JSON.parse(response.body)
        transcript = result["text"] || ""
        segments = build_segments_from_words(result["words"] || [])
        speech_start, speech_end = speech_boundaries(segments)

        log("Transcription complete in #{elapsed}s (#{transcript.length} chars, #{segments.length} segments)")

        { text: transcript, speech_start: speech_start, speech_end: speech_end, segments: segments }
      end
    end

    private

    # Engine segment contract: start/end/text plus the whisper-style quality
    # fields every engine returns (see BaseEngine#parse_segments). Scribe has
    # no such scores, so they default to 0.0.
    QUALITY_DEFAULTS = { no_speech_prob: 0.0, compression_ratio: 0.0, avg_logprob: 0.0 }.freeze

    # Aggregates word-level timestamps into sentence-level segments via the
    # shared TimestampPersister builder (P4-3), then adds QUALITY_DEFAULTS.
    def build_segments_from_words(words)
      TimestampPersister.build_segments_from_words(words).map { |seg| seg.merge(QUALITY_DEFAULTS) }
    end
  end
end
