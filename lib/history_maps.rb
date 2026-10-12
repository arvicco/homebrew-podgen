# frozen_string_literal: true

require_relative "yaml_loader"
require_relative "episode_naming"

# Builds filename → title/timestamp/duration maps from history.yml.
# Shared by RssGenerator and SiteGenerator.
module HistoryMaps
  # Build maps from history.yml entries.
  # Returns [title_map, timestamp_map, duration_map].
  #
  # Options:
  #   history_path:  path to history.yml
  #   podcast_name:  podcast name prefix for filenames
  #   episodes_dir:  episodes directory (for finding translated script titles)
  #   languages:     array of language codes to map (default: none, English-only)
  def self.build(history_path:, podcast_name:, episodes_dir:, languages: [])
    empty = [{}, {}, {}]
    return empty unless history_path && File.exist?(history_path)

    entries = YamlLoader.load(history_path, default: nil)
    return empty unless entries.is_a?(Array)

    title_map = {}
    timestamp_map = {}
    duration_map = {}

    # `languages` here is the codes to map variants for (RssGenerator passes
    # only its own feed language), not a primary-first config list, so the
    # suffix-less primary is excluded by code.
    non_english = languages.reject { |c| c == "en" }

    EpisodeNaming.each_history_basename(entries, podcast_name) do |entry, basename|
      filename = "#{basename}.mp3"
      title_map[filename] = entry["title"] if entry["title"]
      timestamp_map[filename] = entry["timestamp"] if entry["timestamp"]
      duration_map[filename] = entry["duration"] if entry["duration"]

      non_english.each do |code|
        lang_basename = EpisodeNaming.with_language(basename, code)
        lang_filename = "#{lang_basename}.mp3"
        lang_script = File.join(episodes_dir, "#{lang_basename}_script.md")
        if File.exist?(lang_script)
          translated_title = File.read(lang_script)[/^# (.+)$/, 1]
          title_map[lang_filename] = translated_title if translated_title
        end
        title_map[lang_filename] ||= entry["title"] if entry["title"]
        timestamp_map[lang_filename] = entry["timestamp"] if entry["timestamp"]
        # P5-0: a translated mp3 has its own length (recorded by `voice`);
        # the English duration is only the fallback.
        lang_meta = entry["languages"][code] if entry["languages"].is_a?(Hash)
        lang_duration = lang_meta["duration"] if lang_meta.is_a?(Hash)
        lang_duration = entry["duration"] unless lang_duration.is_a?(Numeric) && lang_duration.positive?
        duration_map[lang_filename] = lang_duration if lang_duration
      end
    end

    [title_map, timestamp_map, duration_map]
  end
end
