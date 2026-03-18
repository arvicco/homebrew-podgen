# frozen_string_literal: true

require "yaml"
require_relative "base_validator"

module Validators
  class GuidelinesValidator < BaseValidator
    KNOWN_SOURCES = %w[exa hackernews rss claude_web bluesky x].freeze

    private

    def check
      unless File.exist?(@config.guidelines_path)
        @errors << "Guidelines: guidelines.md not found"
        return
      end

      text = @config.guidelines

      required = %w[Format Tone]
      required << "Topics" if @config.type == "news"

      missing = required.select { |s| !text.match?(/^## #{Regexp.escape(s)}\b/m) }
      if missing.empty?
        @passes << "Guidelines: all required sections present"
      else
        @errors << "Guidelines: missing required sections: #{missing.join(', ')}"
      end

      @config.sources.each_key do |key|
        unless KNOWN_SOURCES.include?(key)
          @warnings << "Guidelines: unrecognized source '#{key}'"
        end
      end

      if @config.type == "news" && File.exist?(@config.queue_path)
        begin
          data = YAML.load_file(@config.queue_path)
          unless data.is_a?(Hash) && data["topics"].is_a?(Array)
            @warnings << "Guidelines: queue.yml has unexpected format"
          end
        rescue => e
          @warnings << "Guidelines: queue.yml parse error: #{e.message}"
        end
      end
    end
  end
end
