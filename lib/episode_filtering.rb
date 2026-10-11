# frozen_string_literal: true

require "date"

# Shared episode filtering helpers.
# Centralizes logic for excluding ffmpeg intermediary files (_concat)
# and matching episodes to language codes.
module EpisodeFiltering
  # Check if basename matches a language code.
  # English = no language suffix; others end with -xx (e.g. -es, -fr).
  # With `languages:` (the podcast's configured codes) only a CONFIGURED
  # code counts as a suffix, so a title-derived "-ai" stays English (P1-15,
  # Q-06); without it any trailing -xx is treated as a suffix (legacy).
  def self.matches_language?(basename, lang_code, languages: nil)
    if lang_code == "en"
      suffix = basename[/-([a-z]{2})\z/, 1]
      return true if suffix.nil?
      # nil/empty (no language config) keeps the legacy any-suffix rule
      (languages.nil? || languages.empty?) ? false : !languages.include?(suffix)
    else
      basename.end_with?("-#{lang_code}")
    end
  end

  # All MP3 episodes in dir, excluding ffmpeg intermediaries (_concat).
  def self.all_episodes(dir)
    return [] unless Dir.exist?(dir)

    Dir.glob(File.join(dir, "*.mp3"))
      .reject { |f| File.basename(f).include?("_concat") }
  end

  # All transcript markdown files in dir, sorted.
  def self.all_transcripts(dir)
    return [] unless Dir.exist?(dir)

    Dir.glob(File.join(dir, "*_transcript.md")).sort
  end

  # English/primary episodes only (no language suffix).
  def self.english_episodes(dir, languages: nil)
    all_episodes(dir)
      .select { |f| matches_language?(File.basename(f, ".mp3"), "en", languages: languages) }
  end

  # Episodes matching a specific language.
  def self.episodes_for_language(dir, lang_code, languages: nil)
    all_episodes(dir)
      .select { |f| matches_language?(File.basename(f, ".mp3"), lang_code, languages: languages) }
  end

  # Extract date from an episode filename or path.
  # Handles: "show-2026-03-01.mp3", "show-2026-03-01a.mp3", "show-2026-03-01-es.mp3"
  # Returns Date or nil if no valid date found.
  def self.parse_date(filename)
    basename = File.basename(filename)
    match = basename.match(/(\d{4}-\d{2}-\d{2})/)
    return nil unless match

    Date.parse(match[1])
  rescue Date::Error
    nil
  end
end
