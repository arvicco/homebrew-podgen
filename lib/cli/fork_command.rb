# frozen_string_literal: true

require "yaml"
require "fileutils"

root = File.expand_path("../..", __dir__)
require_relative File.join(root, "lib", "cli", "podcast_command")

module PodgenCLI
  class ForkCommand
    include PodcastCommand

    def initialize(args, options)
      @options = options
      @podcast_name = args.shift
      @new_name = args.shift
    end

    def run
      code = require_podcast!("fork")
      return code if code

      unless @new_name
        $stderr.puts "Usage: podgen fork <old_podcast> <new_podcast>"
        return 2
      end

      new_podcast_dir = File.join(PodcastConfig.root, "podcasts", @new_name)
      if Dir.exist?(new_podcast_dir)
        $stderr.puts "Podcast '#{@new_name}' already exists at #{new_podcast_dir}"
        return 1
      end

      old_config = PodcastConfig.new(@podcast_name)
      old_output_dir = File.dirname(old_config.episodes_dir)
      new_output_dir = File.join(PodcastConfig.root, "output", @new_name)
      new_episodes_dir = File.join(new_output_dir, "episodes")

      # 1. Copy config directory
      FileUtils.cp_r(old_config.podcast_dir, new_podcast_dir)
      puts "Config: #{old_config.podcast_dir} → #{new_podcast_dir}"

      # 2. Create output structure and copy+rename episodes
      FileUtils.mkdir_p(new_episodes_dir)
      episode_count = 0

      if Dir.exist?(old_config.episodes_dir)
        Dir.glob(File.join(old_config.episodes_dir, "*")).each do |src|
          basename = File.basename(src)
          new_basename = basename.sub(/\A#{Regexp.escape(@podcast_name)}/, @new_name)
          FileUtils.cp(src, File.join(new_episodes_dir, new_basename))
          episode_count += 1
        end
      end
      puts "Episodes: #{episode_count} files copied and renamed"

      # 3. Copy history
      old_history = File.join(old_output_dir, "history.yml")
      if File.exist?(old_history)
        FileUtils.cp(old_history, File.join(new_output_dir, "history.yml"))
        puts "History: copied"
      end

      # 4. Copy and rename LingQ tracking
      old_tracking = File.join(old_output_dir, "lingq_uploads.yml")
      if File.exist?(old_tracking)
        data = YAML.load_file(old_tracking)
        if data.is_a?(Hash)
          renamed = data.transform_values do |entries|
            next entries unless entries.is_a?(Hash)
            entries.transform_keys { |k| k.sub(/\A#{Regexp.escape(@podcast_name)}/, @new_name) }
          end
          File.write(File.join(new_output_dir, "lingq_uploads.yml"), renamed.to_yaml)
          puts "LingQ tracking: copied and renamed"
        end
      end

      puts
      puts "Forked '#{@podcast_name}' → '#{@new_name}'"
      puts
      puts "Next steps:"
      puts "  1. Edit podcasts/#{@new_name}/guidelines.md — update Name, title, base_url"
      puts "  2. podgen rss #{@new_name}     — generate new feed with new GUIDs"
      puts "  3. podgen site #{@new_name}    — generate new site"
      puts "  4. podgen publish #{@new_name} — publish to R2"
      puts "  5. podgen unpublish #{@podcast_name} — remove old podcast from R2 (when ready)"
      0
    end
  end
end
