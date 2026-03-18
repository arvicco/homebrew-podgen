# frozen_string_literal: true

require_relative "base_validator"
require_relative "../episode_filtering"

module Validators
  class TranscriptsValidator < BaseValidator
    private

    def check
      episodes_dir = @config.episodes_dir
      return unless Dir.exist?(episodes_dir)

      mp3s = EpisodeFiltering.all_episodes(episodes_dir)
      return if mp3s.empty?

      missing_md = 0
      missing_html = 0

      mp3s.each do |mp3|
        base = File.basename(mp3, ".mp3")
        has_md = File.exist?(File.join(episodes_dir, "#{base}_script.md")) ||
                 File.exist?(File.join(episodes_dir, "#{base}_transcript.md"))
        has_html = File.exist?(File.join(episodes_dir, "#{base}_script.html")) ||
                   File.exist?(File.join(episodes_dir, "#{base}_transcript.html"))
        missing_md += 1 unless has_md
        missing_html += 1 unless has_html
      end

      if missing_md == 0
        @passes << "Transcripts: #{mp3s.length}/#{mp3s.length} episodes have transcripts"
      else
        @warnings << "Transcripts: #{missing_md}/#{mp3s.length} episodes missing transcript/script"
      end

      if missing_html > 0
        @warnings << "Transcripts: #{missing_html} episodes missing HTML version (run podgen rss)"
      end
    end
  end
end
