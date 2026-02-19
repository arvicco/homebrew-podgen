# frozen_string_literal: true

require "digest"
require "yaml"
require "fileutils"

class ResearchCache
  TTL_SECONDS = 24 * 3600 # 24 hours

  def initialize(cache_dir)
    @cache_dir = cache_dir
    FileUtils.mkdir_p(@cache_dir)
  end

  # Returns cached results or nil if not found / stale.
  def get(source_name, topics)
    path = cache_path(source_name, topics)
    return nil unless File.exist?(path)
    return nil if (Time.now - File.mtime(path)) > TTL_SECONDS

    YAML.load_file(path)
  rescue => e
    # Corrupted cache file — treat as miss
    File.delete(path) if File.exist?(path)
    nil
  end

  # Writes results to cache using atomic write (temp + rename).
  def set(source_name, topics, results)
    path = cache_path(source_name, topics)
    tmp_path = "#{path}.tmp.#{Process.pid}"
    begin
      File.write(tmp_path, results.to_yaml)
      File.rename(tmp_path, path)
    rescue => e
      File.delete(tmp_path) if File.exist?(tmp_path)
    end
  end

  # Deletes cache entries older than TTL.
  def prune!
    return unless Dir.exist?(@cache_dir)

    Dir.glob(File.join(@cache_dir, "*.yml")).each do |path|
      File.delete(path) if (Time.now - File.mtime(path)) > TTL_SECONDS
    end
  end

  private

  def cache_path(source_name, topics)
    key = Digest::SHA256.hexdigest("#{source_name}:#{topics.sort.join(',')}")
    File.join(@cache_dir, "#{key}.yml")
  end
end
