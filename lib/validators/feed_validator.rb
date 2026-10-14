# frozen_string_literal: true

require_relative "base_validator"
require_relative "../episode_filtering"
require_relative "../podcast_config"

module Validators
  class FeedValidator < BaseValidator
    private

    def check
      unless File.exist?(@config.feed_path)
        @warnings << "Feed: feed.xml not found (run podgen rss)"
        return
      end

      require "rexml/document"
      begin
        doc = REXML::Document.new(File.read(@config.feed_path))
        items = doc.elements.to_a("//item")

        mp3_count = EpisodeFiltering.english_episodes(@config.episodes_dir, languages: @config.language_codes).length

        if items.length == mp3_count
          @passes << "Feed: well-formed XML, #{items.length} episodes"
        elsif items.length > 0
          @warnings << "Feed: #{items.length} episodes in feed vs #{mp3_count} MP3s (stale feed?)"
        else
          @warnings << "Feed: well-formed XML but no episodes"
        end
      rescue REXML::ParseException => e
        @errors << "Feed: XML parse error: #{e.message.lines.first&.strip}"
      end

      if @config.languages.length > 1
        primary = EpisodeNaming.primary_language(@config.language_codes)
        @config.languages.each do |lang|
          code = lang["code"]
          next if code == primary
          lang_feed_name = PodcastConfig.feed_file_name(code, primary)
          lang_feed = File.join(File.dirname(@config.feed_path), lang_feed_name)
          unless File.exist?(lang_feed)
            @warnings << "Feed: missing #{lang_feed_name} for language '#{code}'"
          end
        end
      end
    end
  end
end
