# frozen_string_literal: true

require "yaml"
require "date"
require "set"
require_relative "atomic_writer"

class EpisodeHistory
  LOOKBACK_DAYS = 7

  def initialize(history_path, excluded_urls_path: nil)
    @path = history_path
    @excluded_urls_path = excluded_urls_path
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

  # Returns Set of all URLs from recent episodes + excluded URLs
  def recent_urls
    urls = recent_episodes.flat_map { |e| e["urls"] || [] }.to_set
    urls.merge(excluded_urls)
  end

  # Returns Set of all URLs ever recorded + excluded URLs
  def all_urls
    urls = all_episodes.flat_map { |e| e["urls"] || [] }.to_set
    urls.merge(excluded_urls)
  end

  # Returns array of excluded URLs from the separate file
  def excluded_urls
    return [] unless @excluded_urls_path && File.exist?(@excluded_urls_path)

    data = YAML.load_file(@excluded_urls_path)
    data.is_a?(Array) ? data : []
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

  # Remove a specific entry by basename. Returns the removed entry, or nil if not found.
  def remove_by_basename!(basename)
    entries = File.exist?(@path) ? (YAML.load_file(@path) || []) : []
    idx = entries.index { |e| e["basename"] == basename }
    return nil unless idx

    removed = entries.delete_at(idx)
    write_entries!(entries)
    removed
  end

  # Append a new episode entry.
  # Uses atomic write (temp file + rename) to prevent corruption from interrupted writes.
  def record!(date:, title:, topics:, urls:, duration: nil, timestamp: nil, basename: nil)
    entries = File.exist?(@path) ? (YAML.load_file(@path) || []) : []
    entry = {
      "date" => date.to_s,
      "title" => title,
      "topics" => topics,
      "urls" => urls
    }
    entry["duration"] = duration if duration
    entry["timestamp"] = timestamp if timestamp
    entry["basename"] = basename if basename

    entries << entry
    write_entries!(entries)
  end

  private

  def write_entries!(entries)
    AtomicWriter.write_yaml(@path, entries)
  end
end
