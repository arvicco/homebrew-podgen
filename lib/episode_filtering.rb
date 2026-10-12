# frozen_string_literal: true

require_relative "episode_naming"

# Shared episode filtering helpers.
# Centralizes logic for excluding ffmpeg intermediary files (_concat)
# and matching episodes to language codes.
module EpisodeFiltering
  # Check if basename matches a language code.
  # Primary (languages.first, "en" without config) = no language suffix;
  # others end with -xx (e.g. -es, -fr). With `languages:` (the podcast's
  # configured codes) only a CONFIGURED code counts as a suffix, so a
  # title-derived "-ai" stays primary (P1-15, Q-06); without it any
  # trailing -xx is treated as a suffix (legacy). Rule: EpisodeNaming.
  def self.matches_language?(basename, lang_code, languages: nil)
    EpisodeNaming.matches_language?(basename, lang_code, languages: languages)
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

  # Primary-language episodes only (no language suffix).
  def self.english_episodes(dir, languages: nil)
    all_episodes(dir)
      .select { |f| matches_language?(File.basename(f, ".mp3"), EpisodeNaming.primary_language(languages), languages: languages) }
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
    EpisodeNaming.parse_date(filename)
  end
end
