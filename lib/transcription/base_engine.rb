# frozen_string_literal: true

require "json"
require "net/http"
require_relative "../loggable"
require_relative "../http_retryable"

module Transcription
  # A non-2xx STT response; #status is the HTTP code (P8-3). Built through
  # ApiError.for so 429/503 arrive as RetriableApiError and retry is decided
  # by class, never by digits in the message text. The message carries the
  # status plus the body's identifier-shaped error type/code fields, never
  # the error text or raw body: it is logged, and OpenAI's 401 text echoes
  # a masked key.
  class ApiError < StandardError
    attr_reader :status

    def self.for(status, message)
      klass = HttpRetryable::RETRIABLE_CODES.include?(status.to_i) ? RetriableApiError : ApiError
      klass.new(message, status: status)
    end

    def initialize(message = nil, status: nil)
      super(message)
      @status = status&.to_i
    end
  end

  class RetriableApiError < ApiError; end

  class BaseEngine
    include Loggable
    include Retryable
    MAX_RETRIES = 3
    TIMEOUT = 300 # 5 minutes
    RETRYABLE_ERRORS = [RetriableApiError, Net::OpenTimeout, Net::ReadTimeout, Errno::ETIMEDOUT].freeze

    def initialize(language: "sl", logger: nil)
      @language = language
      @logger = logger
    end

    def transcribe(_audio_path)
      raise NotImplementedError, "#{self.class}#transcribe must be implemented"
    end

    def engine_name
      raise NotImplementedError, "#{self.class}#engine_name must be implemented"
    end

    private

    def validate_audio!(audio_path)
      raise "Audio file not found: #{audio_path}" unless File.exist?(audio_path)
    end

    # Same contract as Retryable#with_retries (it is that loop): MAX_RETRIES
    # retries after the first attempt (3 => up to 4 attempts). retryable:
    # RETRYABLE_ERRORS; anything else, and the last retryable error on
    # give-up, propagates with its class intact.
    def with_engine_retries(&)
      with_retries(max: MAX_RETRIES, on: RETRYABLE_ERRORS,
        label: self.class.name.split("::").last, reraise: true, &)
    end

    # ApiError for a non-2xx response: "<prefix> <status>" plus, when the
    # JSON body has them, its error type/code (OpenAI/Groq error.type and
    # error.code, ElevenLabs detail.status/code) — never message text.
    def api_error(prefix, response)
      fields = error_fields(response.body)
      suffix = fields.empty? ? "" : " (#{fields.join(", ")})"
      ApiError.for(response.code, "#{prefix} #{response.code}#{suffix}")
    end

    def error_fields(body)
      data = JSON.parse(body.to_s)
      err = data["error"].is_a?(Hash) ? data["error"] : data["detail"] if data.is_a?(Hash)
      return [] unless err.is_a?(Hash)

      err.values_at("type", "code", "status").filter_map { |v| v.to_s[/\A[\w.-]{1,64}\z/] }.uniq
    rescue JSON::ParserError # skippable: a non-JSON body adds no fields
      []
    end

    def parse_segments(raw_segments)
      (raw_segments || []).map do |s|
        {
          start: s["start"].to_f,
          end: s["end"].to_f,
          text: s["text"].to_s,
          no_speech_prob: s["no_speech_prob"].to_f,
          compression_ratio: s["compression_ratio"].to_f,
          avg_logprob: s["avg_logprob"].to_f
        }
      end
    end

    def speech_boundaries(parsed_segments, duration: nil)
      speech_start = parsed_segments.any? ? parsed_segments.first[:start] : 0.0
      speech_end = parsed_segments.any? ? parsed_segments.last[:end] : (duration || 0.0)
      [speech_start, speech_end]
    end

    def log_transcription_start(audio_path)
      size_mb = (File.size(audio_path) / (1024.0 * 1024)).round(2)
      log("Transcribing #{audio_path} (#{size_mb} MB, model: #{@model}, language: #{@language})")
    end
  end
end
