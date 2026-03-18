# frozen_string_literal: true

require_relative "base_validator"

module Validators
  class LanguagePipelineValidator < BaseValidator
    private

    def check
      engines = @config.transcription_engines
      if engines.empty?
        @warnings << "Language: no transcription engines configured"
      else
        @passes << "Language: engines #{engines.join(', ')}"
      end

      if engines.length >= 2 && engines.include?("groq")
        tails_dir = File.join(File.dirname(@config.episodes_dir), "tails")
        unless Dir.exist?(tails_dir)
          @warnings << "Language: tails/ directory missing (expected for multi-engine+groq)"
        end
      end

      if @config.lingq_config
        lc = @config.lingq_config
        if lc[:image] && !File.exist?(lc[:image])
          @warnings << "LingQ: image file not found: #{lc[:image]}"
        end
        if lc[:base_image] && !File.exist?(lc[:base_image])
          @warnings << "LingQ: base_image file not found: #{lc[:base_image]}"
        end
      end
    end
  end
end
