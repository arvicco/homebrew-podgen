# frozen_string_literal: true

require_relative "base_validator"
require_relative "../remote_image_cache"
require_relative "../tell/hunspell"

module Validators
  class LanguagePipelineValidator < BaseValidator
    # allow_missing_dictionary: a missing hunspell dictionary is a warning,
    # not an error (`validate --allow-missing-dictionary`).
    def initialize(config, allow_missing_dictionary: false)
      super(config)
      @allow_missing_dictionary = allow_missing_dictionary
    end

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

      check_dictionary

      if @config.lingq_config
        lc = @config.lingq_config
        # A URL is fetched by LingQPublisher (Q-56); say so, not "not found".
        if lc[:image]&.match?(%r{\Ahttps?://}i)
          @warnings << "LingQ: image is a URL, downloaded to the podcast cache (output/<podcast>/cache/) at publish time: #{RemoteImageCache.redact(lc[:image])}"
        elsif lc[:image] && !File.exist?(lc[:image])
          @warnings << "LingQ: image file not found: #{lc[:image]}"
        end
        if lc[:base_image] && !File.exist?(lc[:base_image])
          @warnings << "LingQ: base_image file not found: #{lc[:base_image]}"
        end
      end
    end

    # Vocabulary annotation expands inflections from the transcription
    # language's hunspell dictionary; without it the annotator degrades.
    def check_dictionary
      lang = @config.transcription_language
      return unless @config.vocabulary_level && lang

      problem = Tell::Hunspell.missing_message(lang)
      unless problem
        @passes << "Vocabulary: hunspell dictionary for '#{lang}' installed"
        return
      end

      missing = Tell::Hunspell.missing_for(lang)
      problem += " (#{missing.join(" + ")} in none of #{Tell::Hunspell.dict_dirs.join(", ")})" if missing
      (@allow_missing_dictionary ? @warnings : @errors) << "Vocabulary: #{problem}"
    end
  end
end
