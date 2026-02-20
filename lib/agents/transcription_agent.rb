# frozen_string_literal: true

require "httparty"
require "json"

class TranscriptionAgent
  MAX_RETRIES = 3
  TIMEOUT = 300 # 5 minutes

  # Models that support verbose_json with segments/timestamps.
  # gpt-4o-transcribe family only supports json/text — no segments.
  VERBOSE_MODELS = %w[whisper-1].freeze

  def initialize(language: "sl", logger: nil)
    @language = language
    @logger = logger
    @api_key = ENV.fetch("OPENAI_API_KEY") { raise "OPENAI_API_KEY not set" }
    @model = ENV.fetch("WHISPER_MODEL", "gpt-4o-mini-transcribe")
  end

  # Transcribes an audio file via OpenAI transcription API.
  #
  # For whisper-1: returns { text:, segments: [...], speech_start:, speech_end: }
  # For gpt-4o-*-transcribe: returns { text:, segments: [] }
  def transcribe(audio_path)
    raise "Audio file not found: #{audio_path}" unless File.exist?(audio_path)

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
      raise "TranscriptionAgent failed after #{retries} attempts: #{e.message}"
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

  def retryable?(error)
    message = error.message.to_s
    message.include?("429") || message.include?("503") ||
      error.is_a?(Net::OpenTimeout) || error.is_a?(Net::ReadTimeout) ||
      error.is_a?(Errno::ETIMEDOUT)
  end

  def log(message)
    if @logger
      @logger.log("[TranscriptionAgent] #{message}")
    else
      puts "[TranscriptionAgent] #{message}"
    end
  end
end
