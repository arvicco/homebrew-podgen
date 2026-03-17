# frozen_string_literal: true

require "yaml"
require_relative "atomic_writer"

# Tracks LingQ lesson uploads to prevent duplicate uploads.
# Shared by LanguagePipeline (record during generate) and PublishCommand (check before upload).
# Storage: output/<podcast>/lingq_uploads.yml
class LingqTracker
  def initialize(path)
    @path = path
  end

  # Build a tracker from a PodcastConfig.
  def self.for_config(config)
    path = File.join(File.dirname(config.episodes_dir), "lingq_uploads.yml")
    new(path)
  end

  # Load tracking data. Returns Hash of collection → { basename → lesson_id }.
  def load
    return {} unless File.exist?(@path)

    data = YAML.load_file(@path)
    return {} unless data.is_a?(Hash)

    data.transform_keys(&:to_s).transform_values { |v| v.is_a?(Hash) ? v.transform_keys(&:to_s) : v }
  rescue => _e
    {}
  end

  # Save tracking data atomically.
  def save(tracking)
    AtomicWriter.write_yaml(@path, tracking)
  end

  # Record a new upload.
  def record(collection, base_name, lesson_id)
    tracking = load
    collection_key = collection.to_s
    tracking[collection_key] ||= {}
    tracking[collection_key][base_name] = lesson_id
    save(tracking)
  end

  # Remove all entries for a basename across all collections.
  # Returns true if anything was removed.
  def remove(base_name)
    tracking = load
    changed = false
    tracking.each_value do |collection_entries|
      next unless collection_entries.is_a?(Hash)
      changed = true if collection_entries.delete(base_name)
    end
    save(tracking) if changed
    changed
  end

  # Check if a basename is already tracked in a collection.
  def tracked?(collection, base_name)
    tracking = load
    tracking.dig(collection.to_s, base_name) ? true : false
  end
end
