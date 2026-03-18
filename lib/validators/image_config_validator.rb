# frozen_string_literal: true

require_relative "base_validator"

module Validators
  class ImageConfigValidator < BaseValidator
    private

    def check
      checked = false

      base_image = @config.cover_base_image
      if base_image && base_image != :auto
        checked = true
        if File.exist?(base_image)
          @passes << "Image: base_image exists (#{File.basename(base_image)})"
        else
          @errors << "Image: base_image not found: #{base_image}"
        end
      end

      rss_feeds = @config.sources["rss"]
      if rss_feeds.is_a?(Array)
        rss_feeds.each do |feed|
          next unless feed.is_a?(Hash) && feed[:base_image]
          checked = true
          if File.exist?(feed[:base_image])
            @passes << "Image: per-feed base_image exists (#{File.basename(feed[:base_image])})"
          else
            url = feed[:url] || "unknown"
            @errors << "Image: per-feed base_image not found for #{url}: #{feed[:base_image]}"
          end
        end
      end

      @passes << "Image: no base_image paths to check" unless checked
    end
  end
end
