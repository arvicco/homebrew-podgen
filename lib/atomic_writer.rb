# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "yaml"

# Atomic file writes via temp file + rename.
# Prevents corruption from interrupted writes or concurrent access.
module AtomicWriter
  # Write content to path atomically.
  # Creates parent directories if needed.
  # Options:
  #   perm: file permissions (default: an existing file keeps its mode,
  #         a new one gets 0o644)
  def self.write(path, content, perm: nil)
    dir = File.dirname(path)
    FileUtils.mkdir_p(dir)
    kept_mode = File.stat(path).mode & 0o7777 if perm.nil? && File.file?(path)

    tmp = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
    begin
      File.open(tmp, "w:UTF-8", perm: perm || 0o644) do |f|
        f.write(content)
        f.chmod(kept_mode) if kept_mode
      end
      File.rename(tmp, path)
    rescue => e # fatal: re-raised after removing the temp file
      File.delete(tmp) if File.exist?(tmp)
      raise e
    end
  end

  # Write data as YAML atomically.
  def self.write_yaml(path, data, perm: nil)
    write(path, data.to_yaml, perm: perm)
  end

  # Delete a file if it exists (used when data becomes empty).
  def self.delete_if_exists(path)
    File.delete(path) if File.exist?(path)
  end
end
