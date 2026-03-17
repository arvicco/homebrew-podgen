# frozen_string_literal: true

require "fileutils"
require "yaml"

# Atomic file writes via temp file + rename.
# Prevents corruption from interrupted writes or concurrent access.
module AtomicWriter
  # Write content to path atomically.
  # Creates parent directories if needed.
  # Options:
  #   perm: file permissions (default 0o644)
  def self.write(path, content, perm: 0o644)
    dir = File.dirname(path)
    FileUtils.mkdir_p(dir)

    tmp = "#{path}.tmp.#{Process.pid}"
    begin
      File.open(tmp, "w:UTF-8", perm: perm) { |f| f.write(content) }
      File.rename(tmp, path)
    rescue => e
      File.delete(tmp) if File.exist?(tmp)
      raise e
    end
  end

  # Write data as YAML atomically.
  def self.write_yaml(path, data, perm: 0o644)
    write(path, data.to_yaml, perm: perm)
  end

  # Delete a file if it exists (used when data becomes empty).
  def self.delete_if_exists(path)
    File.delete(path) if File.exist?(path)
  end
end
