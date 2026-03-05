# frozen_string_literal: true

require "fileutils"

module Tell
  class History
    DEFAULT_MAX_ENTRIES = 1000

    def initialize(path, max_entries: DEFAULT_MAX_ENTRIES)
      @path = path
      @max_entries = max_entries
      @entries = nil
      @reline_synced = false
    end

    # Lazy-loaded, deduped entries (last occurrence wins)
    def entries
      @entries ||= load_entries
    end

    # Push entries into Reline::HISTORY for interactive readline
    def load_into_reline!
      require "reline"
      Reline::HISTORY.clear
      entries.each { |e| Reline::HISTORY << e }
      @reline_synced = true
    end

    # Add entry: dedup (move to end), cap at max_entries, persist
    def add(text)
      entries.reject! { |e| e == text }
      entries << text
      cap_entries!

      if @reline_synced
        # Remove all old occurrences, then append
        while (idx = Reline::HISTORY.to_a.rindex(text))
          Reline::HISTORY.delete_at(idx)
        end
        Reline::HISTORY << text
      end

      save!
    end

    # Remove all occurrences, persist. Returns count removed.
    def delete(text)
      before = entries.size
      entries.reject! { |e| e == text }
      count = before - entries.size

      if @reline_synced
        Reline::HISTORY.delete(text)
      end

      save!
      count
    end

    # Atomic write: temp file + rename, 0o600 permissions, UTF-8
    def save!
      if entries.empty?
        File.delete(@path) if File.exist?(@path)
        return
      end

      dir = File.dirname(@path)
      FileUtils.mkdir_p(dir)
      tmp_path = "#{@path}.tmp.#{Process.pid}"
      begin
        File.open(tmp_path, "w:UTF-8", perm: 0o600) do |f|
          f.write(entries.join("\n") + "\n")
        end
        File.rename(tmp_path, @path)
      rescue => e
        File.delete(tmp_path) if File.exist?(tmp_path)
        raise e
      end
    end

    private

    def load_entries
      return [] unless File.exist?(@path)

      raw = File.binread(@path).force_encoding("UTF-8")
      raw = raw.encode("UTF-8", "UTF-8", invalid: :replace, undef: :replace, replace: "\uFFFD") unless raw.valid_encoding?
      lines = raw.split("\n")
                  .map(&:strip)
                  .reject(&:empty?)

      # Dedup keeping last occurrence: reverse, take first seen, reverse back
      seen = {}
      deduped = []
      lines.reverse_each do |line|
        next if seen[line]
        seen[line] = true
        deduped.unshift(line)
      end

      deduped.last(@max_entries)
    end

    def cap_entries!
      @entries = entries.last(@max_entries) if entries.size > @max_entries
    end
  end
end
