# frozen_string_literal: true

require "yaml"
require "date"
require "set"
require "fileutils"

class EpisodeHistory
  LOOKBACK_DAYS = 7

  def initialize(history_path)
    @path = history_path
  end

  # Returns all episode hashes
  def all_episodes
    return [] unless File.exist?(@path)

    YAML.load_file(@path) || []
  end

  # Returns array of recent episode hashes (within lookback window)
  def recent_episodes
    cutoff = (Date.today - LOOKBACK_DAYS).to_s
    all_episodes.select { |e| e["date"] >= cutoff }
  end

  # Returns Set of all URLs from recent episodes
  def recent_urls
    recent_episodes.flat_map { |e| e["urls"] || [] }.to_set
  end

  # Returns Set of all URLs ever recorded (for language pipeline dedup)
  def all_urls
    all_episodes.flat_map { |e| e["urls"] || [] }.to_set
  end

  # Returns formatted string of recent topics for the topic agent prompt
  def recent_topics_summary
    summary = recent_episodes.map { |e|
      "- #{e['date']}: #{(e['topics'] || []).join('; ')}"
    }.join("\n")
    summary.empty? ? nil : summary
  end

  # Remove the last entry and return it (or nil if empty).
  # Uses atomic write (temp file + rename) to prevent corruption.
  def remove_last!
    entries = File.exist?(@path) ? (YAML.load_file(@path) || []) : []
    return nil if entries.empty?

    removed = entries.pop
    write_entries!(entries)
    removed
  end

  # Append a new episode entry.
  # Uses atomic write (temp file + rename) to prevent corruption from interrupted writes.
  def record!(date:, title:, topics:, urls:)
    entries = File.exist?(@path) ? (YAML.load_file(@path) || []) : []
    entries << {
      "date" => date.to_s,
      "title" => title,
      "topics" => topics,
      "urls" => urls
    }

    write_entries!(entries)
  end

  private

  # Atomic write: temp file + rename to prevent corruption.
  def write_entries!(entries)
    dir = File.dirname(@path)
    FileUtils.mkdir_p(dir)
    tmp_path = File.join(dir, ".history.yml.tmp.#{Process.pid}")
    begin
      File.write(tmp_path, entries.to_yaml)
      File.rename(tmp_path, @path)
    rescue => e
      File.delete(tmp_path) if File.exist?(tmp_path)
      raise e
    end
  end
end
