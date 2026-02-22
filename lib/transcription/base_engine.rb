# frozen_string_literal: true

module Transcription
  class BaseEngine
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

    def log(message)
      tag = "[#{self.class.name}]"
      if @logger
        @logger.log("#{tag} #{message}")
      else
        puts "#{tag} #{message}"
      end
    end
  end
end
