# frozen_string_literal: true

require_relative "base_validator"
require_relative "../episode_filtering"
require_relative "../yaml_loader"

module Validators
  class HistoryValidator < BaseValidator
    private

    def check
      unless File.exist?(@config.history_path)
        @warnings << "History: history.yml not found"
        return
      end

      entries = YamlLoader.load(@config.history_path, default: nil, raise_on_error: true)
      unless entries.is_a?(Array)
        @errors << "History: unexpected format (expected array)"
        return
      end

      bad_entries = entries.reject { |e|
        e.is_a?(Hash) && e["date"] && e["title"] && e["topics"]
      }
      unless bad_entries.empty?
        @warnings << "History: #{bad_entries.length} entries missing date/title/topics"
      end

      if Dir.exist?(@config.episodes_dir)
        mp3_count = EpisodeFiltering.english_episodes(@config.episodes_dir).length

        if entries.length == mp3_count
          @passes << "History: #{entries.length} entries"
        else
          @warnings << "History: entry count (#{entries.length}) differs from episode count (#{mp3_count})"
        end
      else
        @passes << "History: #{entries.length} entries"
      end
    rescue => e
      @errors << "History: parse error: #{e.message}"
    end
  end
end
