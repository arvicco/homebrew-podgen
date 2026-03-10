# frozen_string_literal: true

# Shared episode filtering helpers.
# Centralizes logic for excluding ffmpeg intermediary files (_concat)
# and matching episodes to language codes.
module EpisodeFiltering
  # Check if basename matches a language code.
  # English = no language suffix; others end with -xx (e.g. -es, -fr).
  def self.matches_language?(basename, lang_code)
    if lang_code == "en"
      !basename.match?(/-[a-z]{2}$/)
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

  # English/primary episodes only (no language suffix).
  def self.english_episodes(dir)
    all_episodes(dir)
      .reject { |f| File.basename(f, ".mp3").match?(/-[a-z]{2}$/) }
  end

  # Episodes matching a specific language.
  def self.episodes_for_language(dir, lang_code)
    all_episodes(dir)
      .select { |f| matches_language?(File.basename(f, ".mp3"), lang_code) }
  end
end
