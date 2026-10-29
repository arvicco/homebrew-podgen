# frozen_string_literal: true

require "fileutils"
require "time"
require_relative "atomic_writer"
require_relative "yaml_loader"

# Listening archive (P11-0, Q-104): writes what the owner's interactive
# listening decided, as labelled examples for later automation.
#   kept:     <root>/<basename>.source<ext> + <root>/<basename>.trim.yml
#   rejected: <root>/rejected/<date>-<slug><ext> + a row in <root>/rejected.yml
# Write-only owner data: nothing in the pipeline, feed, site, status or
# stats reads it. Files are copied, never moved — the caller's file (a temp
# download or the owner's own local file) stays where it was.
class ListeningArchive
  def initialize(root:, clock: -> { Time.now })
    @root = root
    @clock = clock
  end

  # Copies the untrimmed source, then writes the sidecar: the pair is
  # complete exactly when both exist.
  def keep(source_path, basename:, record:)
    FileUtils.mkdir_p(@root)
    FileUtils.cp(source_path, File.join(@root, "#{basename}.source#{File.extname(source_path)}"))
    AtomicWriter.write_yaml(File.join(@root, "#{basename}.trim.yml"), stamp(record))
  end

  # Copies the rejected download (when there is one) and appends a row.
  def reject(source_path, date:, record:)
    file = nil
    if source_path && File.exist?(source_path)
      file = free_name(date, record[:title], File.extname(source_path))
      FileUtils.mkdir_p(File.join(@root, "rejected"))
      FileUtils.cp(source_path, File.join(@root, file))
    end
    path = File.join(@root, "rejected.yml")
    rows = YamlLoader.load(path, default: [])
    rows << stamp(record.merge(file: file))
    AtomicWriter.write_yaml(path, rows)
  end

  private

  def stamp(record)
    record.to_h { |k, v| [k.to_s, v] }.merge("recorded_at" => @clock.call.iso8601)
  end

  def free_name(date, title, ext)
    base = "rejected/#{date.strftime("%Y-%m-%d")}-#{slug(title)}"
    candidate = "#{base}#{ext}"
    n = 1
    candidate = "#{base}-#{n += 1}#{ext}" while File.exist?(File.join(@root, candidate))
    candidate
  end

  def slug(title)
    s = title.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase
      .gsub(/[^a-z0-9]+/, "-").delete_prefix("-").delete_suffix("-")[0, 60].to_s.delete_suffix("-")
    s.empty? ? "episode" : s
  end
end
