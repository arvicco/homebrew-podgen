# frozen_string_literal: true

require "yaml"

# Builds filename → title/timestamp/duration maps from history.yml.
# Shared by RssGenerator and SiteGenerator.
module HistoryMaps
  SUFFIXES = [""] + ("a".."z").to_a

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

    entries = YAML.load_file(history_path) rescue nil
    return empty unless entries.is_a?(Array)

    by_date = {}
    entries.each do |entry|
      date = entry["date"]
      next unless date
      (by_date[date] ||= []) << entry
    end

    title_map = {}
    timestamp_map = {}
    duration_map = {}

    non_english = languages.reject { |c| c == "en" }

    by_date.each do |date, date_entries|
      date_entries.each_with_index do |entry, idx|
        basename = if entry["basename"]
          entry["basename"]
        else
          suffix = SUFFIXES[idx] || idx.to_s
          "#{podcast_name}-#{date}#{suffix}"
        end

        filename = "#{basename}.mp3"
        title_map[filename] = entry["title"] if entry["title"]
        timestamp_map[filename] = entry["timestamp"] if entry["timestamp"]
        duration_map[filename] = entry["duration"] if entry["duration"]

        non_english.each do |code|
          lang_filename = "#{basename}-#{code}.mp3"
          lang_script = File.join(episodes_dir, "#{basename}-#{code}_script.md")
          if File.exist?(lang_script)
            translated_title = File.read(lang_script)[/^# (.+)$/, 1]
            title_map[lang_filename] = translated_title if translated_title
          end
          title_map[lang_filename] ||= entry["title"] if entry["title"]
          timestamp_map[lang_filename] = entry["timestamp"] if entry["timestamp"]
          duration_map[lang_filename] = entry["duration"] if entry["duration"]
        end
      end
    end

    [title_map, timestamp_map, duration_map]
  end
end
