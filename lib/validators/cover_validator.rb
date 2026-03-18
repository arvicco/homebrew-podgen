# frozen_string_literal: true

require_relative "base_validator"

module Validators
  class CoverValidator < BaseValidator
    private

    def check
      unless @config.image
        @warnings << "Cover: no image configured in guidelines"
        return
      end

      output_dir = File.dirname(@config.episodes_dir)
      output_cover = File.join(output_dir, @config.image)
      source_cover = File.join(@config.podcast_dir, @config.image)

      if File.exist?(output_cover)
        size = File.size(output_cover)
        if size < 10_000
          @warnings << "Cover: #{@config.image} is very small (#{format_size(size)})"
        elsif size > 5_000_000
          @warnings << "Cover: #{@config.image} is very large (#{format_size(size)})"
        else
          @passes << "Cover: #{@config.image} (#{format_size(size)})"
        end
      elsif File.exist?(source_cover)
        @warnings << "Cover: #{@config.image} only in podcasts/ dir (run podgen rss to copy)"
      else
        @errors << "Cover: #{@config.image} not found"
      end
    end
  end
end
