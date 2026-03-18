# frozen_string_literal: true

require_relative "../loggable"

module Transcription
  class BaseEngine
    include Loggable
    MAX_RETRIES = 3
    TIMEOUT = 300 # 5 minutes

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

    def retryable?(error)
      message = error.message.to_s
      message.include?("429") || message.include?("503") ||
        error.is_a?(Net::OpenTimeout) || error.is_a?(Net::ReadTimeout) ||
        error.is_a?(Errno::ETIMEDOUT)
    end

    def with_engine_retries
      retries = 0
      begin
        retries += 1
        yield
      rescue => e
        if retries <= MAX_RETRIES && retryable?(e)
          sleep_time = 2**retries
          log("Error (attempt #{retries}/#{MAX_RETRIES}): #{e.message}. Retrying in #{sleep_time}s...")
          sleep(sleep_time)
          retry
        end
        raise "#{self.class.name.split('::').last} failed after #{retries} attempts: #{e.message}"
      end
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
