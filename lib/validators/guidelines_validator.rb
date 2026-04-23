# frozen_string_literal: true

require_relative "base_validator"
require_relative "../yaml_loader"

module Validators
  class GuidelinesValidator < BaseValidator
    KNOWN_SOURCES = %w[exa hackernews rss claude_web bluesky x select].freeze

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
          data = YamlLoader.load(@config.queue_path, default: nil, raise_on_error: true)
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
