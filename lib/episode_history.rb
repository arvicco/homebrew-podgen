# frozen_string_literal: true

require "yaml"
require "date"
require "set"
require_relative "atomic_writer"

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

  # Remove a specific entry by date and suffix index (0-based position among
  # entries sharing that date). Returns the removed entry, or nil if not found.
  def remove_by_date!(date, suffix_index)
    entries = File.exist?(@path) ? (YAML.load_file(@path) || []) : []

    # Find all entries with this date, in order
    matches = entries.each_with_index.select { |e, _| e["date"] == date.to_s }
    return nil if matches.empty? || suffix_index >= matches.length

    _, global_index = matches[suffix_index]
    removed = entries.delete_at(global_index)
    write_entries!(entries)
    removed
  end

  # Append a new episode entry.
  # Uses atomic write (temp file + rename) to prevent corruption from interrupted writes.
  def record!(date:, title:, topics:, urls:, duration: nil, timestamp: nil)
    entries = File.exist?(@path) ? (YAML.load_file(@path) || []) : []
    entry = {
      "date" => date.to_s,
      "title" => title,
      "topics" => topics,
      "urls" => urls
    }
    entry["duration"] = duration if duration
    entry["timestamp"] = timestamp if timestamp

    entries << entry
    write_entries!(entries)
  end

  private

  def write_entries!(entries)
    AtomicWriter.write_yaml(@path, entries)
  end
end
