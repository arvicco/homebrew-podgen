# frozen_string_literal: true

require "yaml"

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "podcast_config")
require_relative File.join(root, "lib", "episode_history")

module PodgenCLI
  class ScrapCommand
    def initialize(args, options)
      @podcast_name = args.shift
      @options = options
      @dry_run = options[:dry_run] || false
    end

    def run
      unless @podcast_name
        available = PodcastConfig.available
        $stderr.puts "Usage: podgen scrap <podcast_name>"
        $stderr.puts
        if available.any?
          $stderr.puts "Available podcasts:"
          available.each { |name| $stderr.puts "  - #{name}" }
        end
        return 2
      end

      config = PodcastConfig.new(@podcast_name)
      episodes_dir = config.episodes_dir

      # Find all episode MP3s (excluding ffmpeg intermediaries)
      all_mp3s = Dir.glob(File.join(episodes_dir, "#{@podcast_name}-*.mp3"))
        .reject { |f| File.basename(f).include?("_concat") }
        .sort

      if all_mp3s.empty?
        $stderr.puts "No episodes found for '#{@podcast_name}'"
        return 1
      end

      # Find English (base) episodes — name-YYYY-MM-DD[a-z]?.mp3 (no language suffix)
      english_pattern = /^#{Regexp.escape(@podcast_name)}-\d{4}-\d{2}-\d{2}[a-z]?\.mp3$/
      english_mp3s = all_mp3s.select { |f| File.basename(f).match?(english_pattern) }

      if english_mp3s.empty?
        $stderr.puts "No base episodes found for '#{@podcast_name}'"
        return 1
      end

      # Latest base name (without extension)
      latest_base = File.basename(english_mp3s.last, ".mp3")

      # Find all files related to this episode (mp3 + scripts, all languages)
      related_files = Dir.glob(File.join(episodes_dir, "#{latest_base}*"))
        .reject { |f| File.basename(f).include?("_concat") }
        .sort

      # Load history
      history = EpisodeHistory.new(config.history_path)
      entries = File.exist?(config.history_path) ? (YAML.load_file(config.history_path) || []) : []
      last_entry = entries.last

      # Display what will be removed
      puts "Last episode for '#{@podcast_name}':"
      if last_entry
        puts "  Title:  #{last_entry['title']}"
        puts "  Date:   #{last_entry['date']}"
        topics = last_entry['topics'] || []
        topics.each { |t| puts "  Topic:  #{t}" }
        source_count = last_entry['urls']&.length || 0
        puts "  Sources: #{source_count} (will be freed for reuse)"
        puts
      end

      puts "Files to remove:"
      related_files.each { |f| puts "  #{File.basename(f)}" }
      puts

      if @dry_run
        puts "[dry-run] Would remove #{related_files.length} file(s) and last history entry."
        return 0
      end

      # Confirm
      $stdout.write "Proceed? [y/N] "
      $stdout.flush
      answer = $stdin.gets&.strip&.downcase
      unless answer == "y"
        puts "Aborted."
        return 0
      end

      # Delete files
      related_files.each do |f|
        File.delete(f)
      end

      # Remove last history entry (atomic write)
      removed = history.remove_last!

      # Remove LingQ tracking entry for this episode
      remove_lingq_tracking(config, latest_base)

      title = removed ? "\"#{removed['title']}\"" : latest_base
      puts "\u2713 Scrapped #{related_files.length} file(s): #{title}"
      0
    end

    private

    def remove_lingq_tracking(config, base_name)
      tracking_path = File.join(File.dirname(config.episodes_dir), "lingq_uploads.yml")
      return unless File.exist?(tracking_path)

      tracking = YAML.load_file(tracking_path)
      return unless tracking.is_a?(Hash)

      changed = false
      tracking.each_value do |collection_entries|
        next unless collection_entries.is_a?(Hash)
        changed = true if collection_entries.delete(base_name)
      end

      return unless changed

      tmp = "#{tracking_path}.tmp.#{Process.pid}"
      begin
        File.write(tmp, tracking.to_yaml)
        File.rename(tmp, tracking_path)
      rescue => e
        File.delete(tmp) if File.exist?(tmp)
        raise e
      end
    end
  end
end
