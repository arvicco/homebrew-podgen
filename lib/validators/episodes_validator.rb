# frozen_string_literal: true

require_relative "base_validator"
require_relative "../episode_filtering"

module Validators
  class EpisodesValidator < BaseValidator
    private

    def check
      episodes_dir = @config.episodes_dir
      unless Dir.exist?(episodes_dir)
        @warnings << "Episodes: directory not found (no episodes generated yet?)"
        return
      end

      mp3s = EpisodeFiltering.all_episodes(episodes_dir)

      if mp3s.empty?
        @warnings << "Episodes: no MP3 files found"
        return
      end

      zero_byte = mp3s.select { |f| File.size(f) == 0 }
      unless zero_byte.empty?
        @errors << "Episodes: #{zero_byte.length} zero-byte MP3 file#{'s' unless zero_byte.length == 1}"
      end

      name_pattern = /^#{Regexp.escape(@config.name)}-\d{4}-\d{2}-\d{2}[a-z]?(-[a-z]{2})?\.mp3$/
      bad_names = mp3s.reject { |f| File.basename(f).match?(name_pattern) }
      unless bad_names.empty?
        @warnings << "Episodes: #{bad_names.length} file#{'s' unless bad_names.length == 1} with unexpected naming"
      end

      total_size = mp3s.sum { |f| File.size(f) rescue 0 }
      avg_size = total_size / mp3s.length
      @passes << "Episodes: #{mp3s.length} MP3 files (#{format_size(avg_size)} avg)"
    end
  end
end
