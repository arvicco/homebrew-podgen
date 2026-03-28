# frozen_string_literal: true

require_relative "atomic_writer"
require_relative "yaml_loader"

# Tracks uploads across platforms (LingQ, YouTube) to prevent duplicates.
# Shared by LanguagePipeline (record during generate) and PublishCommand (check before upload).
# Storage: output/<podcast>/uploads.yml
#
# Format:
#   lingq:
#     <collection_id>:
#       <basename>: <lesson_id>
#   youtube:
#     <playlist_id>:
#       <basename>: <video_id>
class UploadTracker
  def initialize(path)
    @path = path
  end

  # Build a tracker from a PodcastConfig.
  def self.for_config(config)
    path = File.join(File.dirname(config.episodes_dir), "uploads.yml")
    new(path)
  end

  # Load tracking data. Returns Hash of platform → group → { basename → id }.
  # Migrates from legacy lingq_uploads.yml on first load if needed.
  def load
    migrate_legacy_file
    data = YamlLoader.load(@path, default: {})
    normalize_keys(data)
  end

  # Save tracking data atomically.
  def save(tracking)
    AtomicWriter.write_yaml(@path, tracking)
  end

  # Record a new upload.
  def record(platform, group, base_name, upload_id)
    tracking = load
    platform_key = platform.to_s
    group_key = group.to_s
    tracking[platform_key] ||= {}
    tracking[platform_key][group_key] ||= {}
    tracking[platform_key][group_key][base_name] = upload_id
    save(tracking)
  end

  # Remove all entries for a basename across all platforms and groups.
  # Returns true if anything was removed.
  def remove(base_name)
    tracking = load
    changed = false
    tracking.each_value do |groups|
      next unless groups.is_a?(Hash)
      groups.each_value do |entries|
        next unless entries.is_a?(Hash)
        changed = true if entries.delete(base_name)
      end
    end
    save(tracking) if changed
    changed
  end

  # Check if a basename is already tracked for a platform/group.
  def tracked?(platform, group, base_name)
    tracking = load
    tracking.dig(platform.to_s, group.to_s, base_name) ? true : false
  end

  # Return all entries for a platform/group. Returns Hash of { basename → id }.
  def entries_for(platform, group)
    tracking = load
    tracking.dig(platform.to_s, group.to_s) || {}
  end

  # Return all YouTube video IDs for a given basename (across all playlists).
  def video_ids_for(base_name)
    tracking = load
    youtube = tracking["youtube"]
    return [] unless youtube.is_a?(Hash)

    youtube.each_value.filter_map do |entries|
      entries[base_name] if entries.is_a?(Hash) && entries.key?(base_name)
    end
  end

  private

  def normalize_keys(data)
    data.transform_keys(&:to_s).transform_values do |groups|
      next groups unless groups.is_a?(Hash)
      groups.transform_keys(&:to_s).transform_values do |entries|
        entries.is_a?(Hash) ? entries.transform_keys(&:to_s) : entries
      end
    end
  end

  # Migrate from legacy lingq_uploads.yml (flat: collection → { basename → id })
  # to unified uploads.yml (nested: lingq → collection → { basename → id }).
  def migrate_legacy_file
    return if File.exist?(@path)

    legacy_path = File.join(File.dirname(@path), "lingq_uploads.yml")
    return unless File.exist?(legacy_path)

    legacy_data = YamlLoader.load(legacy_path, default: {})
    return unless legacy_data.is_a?(Hash) && !legacy_data.empty?

    save({ "lingq" => legacy_data })
    File.delete(legacy_path)
  end
end
