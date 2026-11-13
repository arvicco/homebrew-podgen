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
#   youtube_pending:            # additive, present only while steps are owed
#     <playlist_id>:
#       <basename>: [captions, playlist]
class UploadTracker
  PENDING_SUFFIX = "_pending"

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
  # strict: true (the writers) raises on a corrupt file instead of returning {}
  # that would then be saved over it (Q-108); display reads keep the default.
  def load(strict: false)
    migrate_legacy_file(strict: strict) unless @migrated
    data = YamlLoader.load(@path, default: {}, raise_on_error: strict)
    normalize_keys(data)
  end

  # Strict read of uploads.yml as it is on disk, without the legacy
  # migration (which writes): a preflight that raises on corruption and
  # never touches a file, dry runs included (Q-140). With only the legacy
  # file on disk, that file is the ledger and is read the same way.
  def verify!
    YamlLoader.load(@path, default: {}, raise_on_error: true)
    YamlLoader.load(legacy_path, default: {}, raise_on_error: true) unless File.exist?(@path)
    nil
  end

  # Save tracking data atomically.
  def save(tracking)
    AtomicWriter.write_yaml(@path, tracking)
  end

  # Record a new upload.
  def record(platform, group, base_name, upload_id)
    tracking = load(strict: true)
    platform_key = platform.to_s
    group_key = group.to_s
    tracking[platform_key] ||= {}
    tracking[platform_key][group_key] ||= {}
    tracking[platform_key][group_key][base_name] = upload_id
    save(tracking)
  end

  # Record the post-upload steps still owed for a tracked upload (e.g.
  # captions after a live video); an empty list clears the marker. Writes
  # only when something changes, so a clean upload never touches the file
  # twice.
  def mark_pending(platform, group, base_name, steps)
    tracking = load(strict: true)
    key = "#{platform}#{PENDING_SUFFIX}"
    groups = tracking[key] ||= {}
    entries = groups[group.to_s] ||= {}
    return if entries[base_name] == (steps.empty? ? nil : steps)

    if steps.empty?
      entries.delete(base_name)
    else
      entries[base_name] = steps
    end
    groups.delete(group.to_s) if entries.empty?
    tracking.delete(key) if groups.empty?
    save(tracking)
  end

  # Steps still owed per basename: { basename → [step, ...] }. A file
  # without the marker reads as nothing pending. strict: true raises on a
  # corrupt file (a caller about to upload must not read it as empty).
  def pending_steps(platform, group, strict: false)
    entries = load(strict: strict).dig("#{platform}#{PENDING_SUFFIX}", group.to_s)
    entries.is_a?(Hash) ? entries : {}
  end

  # Remove all entries for a basename across all platforms and groups.
  # Returns true if anything was removed.
  def remove(base_name)
    tracking = load(strict: true)
    changed = false
    tracking.each_value do |groups|
      next unless groups.is_a?(Hash)
      groups.each_value do |entries|
        next unless entries.is_a?(Hash)
        changed = true if entries.delete(base_name)
      end
    end
    prune_empty_pending(tracking)
    save(tracking) if changed
    changed
  end

  # Rename all entries from old_base_name to new_base_name across all platforms
  # and groups. Used by `podgen move`. Returns true if anything was renamed.
  def rename(old_base_name, new_base_name)
    tracking = load(strict: true)
    changed = false
    tracking.each_value do |groups|
      next unless groups.is_a?(Hash)
      groups.each_value do |entries|
        next unless entries.is_a?(Hash) && entries.key?(old_base_name)
        entries[new_base_name] = entries.delete(old_base_name)
        changed = true
      end
    end
    prune_empty_pending(tracking)
    save(tracking) if changed
    changed
  end

  # Check if a basename is already tracked for a platform/group.
  def tracked?(platform, group, base_name)
    tracking = load
    tracking.dig(platform.to_s, group.to_s, base_name) ? true : false
  end

  # Return all entries for a platform/group. Returns Hash of { basename → id }.
  # strict: true raises on a corrupt file instead of returning {}.
  def entries_for(platform, group, strict: false)
    tracking = load(strict: strict)
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

  # A *_pending key goes once nothing is owed (as mark_pending leaves it):
  # drop emptied groups, then the key itself.
  def prune_empty_pending(tracking)
    tracking.each_key.select { |k| k.end_with?(PENDING_SUFFIX) }.each do |key|
      groups = tracking[key]
      next unless groups.is_a?(Hash)
      groups.delete_if { |_group, entries| entries.is_a?(Hash) && entries.empty? }
      tracking.delete(key) if groups.empty?
    end
  end

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
  # strict: a corrupt legacy file raises (and the migration stays owed)
  # instead of reading as {} under a fresh uploads.yml.
  def migrate_legacy_file(strict: false)
    return @migrated = true if File.exist?(@path) || !File.exist?(legacy_path)

    legacy_data = YamlLoader.load(legacy_path, default: {}, raise_on_error: strict)
    @migrated = true
    return unless legacy_data.is_a?(Hash) && !legacy_data.empty?

    save({ "lingq" => legacy_data })
    File.delete(legacy_path)
  end

  def legacy_path
    File.join(File.dirname(@path), "lingq_uploads.yml")
  end
end
