# frozen_string_literal: true

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "cli", "podcast_command")
require_relative File.join(root, "lib", "episode_history")
require_relative File.join(root, "lib", "url_cleaner")
require_relative File.join(root, "lib", "atomic_writer")
require_relative File.join(root, "lib", "yaml_loader")

module PodgenCLI
  class ExcludeCommand
    include PodcastCommand

    def initialize(args, options)
      @options = options
      @podcast_name = args.shift
      @urls = args.dup
    end

    def run
      code = require_podcast!("exclude")
      return code if code

      if @urls.empty?
        $stderr.puts "Usage: podgen exclude <podcast> <url> [url...]"
        return 2
      end

      config = PodcastConfig.new(@podcast_name)
      history = EpisodeHistory.new(config.history_path, excluded_urls_path: config.excluded_urls_path)

      # Clean tracking params
      cleaned = @urls.map { |u| UrlCleaner.clean(u) }

      # Check for duplicates against existing history + excluded URLs
      existing = history.all_urls
      new_urls = cleaned.reject { |u| existing.include?(u) }
      dupes = cleaned.length - new_urls.length

      if new_urls.empty?
        puts "All #{cleaned.length} URL(s) already excluded."
        return 0
      end

      # Append to excluded_urls.yml (separate from history)
      excluded_path = config.excluded_urls_path
      current = YamlLoader.load(excluded_path, default: [])
      current.concat(new_urls)
      AtomicWriter.write_yaml(excluded_path, current)

      puts "Excluded #{new_urls.length} URL(s) for '#{@podcast_name}'."
      puts "  #{dupes} already excluded." if dupes > 0
      new_urls.each { |u| puts "  #{u}" }
      0
    end
  end
end
