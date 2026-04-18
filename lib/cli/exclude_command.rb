# frozen_string_literal: true

root = File.expand_path("../..", __dir__)

require "optparse"
require_relative File.join(root, "lib", "cli", "podcast_command")
require_relative File.join(root, "lib", "episode_history")
require_relative File.join(root, "lib", "url_cleaner")
require_relative File.join(root, "lib", "atomic_writer")
require_relative File.join(root, "lib", "yaml_loader")

module PodgenCLI
  class ExcludeCommand
    include PodcastCommand

    DEFAULT_ASK_COUNT = 5

    def initialize(args, options)
      @options = options
      @rss_filter = nil
      @ask = nil

      OptionParser.new do |opts|
        opts.on("--rss FILTER", "RSS feed filter (URL substring or tag)") { |v| @rss_filter = v }
        opts.on("--ask [N]", Integer, "Show next N episodes to pick from (default #{DEFAULT_ASK_COUNT})") { |n| @ask = n || DEFAULT_ASK_COUNT }
      end.parse!(args)

      @podcast_name = args.shift
      @urls = args.dup
    end

    def run
      code = require_podcast!("exclude")
      return code if code

      return run_ask if @ask
      return run_rss_next if @rss_filter && @urls.empty?

      if @urls.empty?
        $stderr.puts "Usage: podgen exclude <podcast> <url> [url...]"
        $stderr.puts "       podgen exclude <podcast> --rss <filter> [--ask N]"
        return 2
      end

      exclude_urls(@urls)
    end

    private

    def run_rss_next
      config = PodcastConfig.new(@podcast_name)

      unless config.type == "language"
        $stderr.puts "Error: --rss requires a language pipeline podcast (type: language)"
        return 2
      end

      history = EpisodeHistory.new(config.history_path, excluded_urls_path: config.excluded_urls_path)
      exclude_set = history.all_urls

      configured_feeds = config.sources["rss"]
      unless configured_feeds.is_a?(Array) && configured_feeds.any?
        $stderr.puts "Error: No RSS sources configured in guidelines.md"
        return 2
      end

      begin
        feeds = resolve_feeds(configured_feeds, @rss_filter)
      rescue RuntimeError => e
        $stderr.puts "Error: #{e.message}"
        return 1
      end

      require_relative File.join(File.expand_path("../..", __dir__), "lib", "sources", "rss_source")
      source = RSSSource.new(feeds: feeds)
      episodes = source.fetch_episodes(exclude_urls: exclude_set)

      if episodes.empty?
        $stderr.puts "No unprocessed episodes in '#{@rss_filter}'."
        return 1
      end

      ep = episodes.first
      info = "#{ep[:title]}"
      info += " (#{ep[:duration]})" if ep[:duration]
      info += " [#{(ep[:file_size] / (1024.0 * 1024)).round(1)} MB]" if ep[:file_size]&.positive?
      puts "Excluding next episode from '#{@rss_filter}': #{info}"
      exclude_urls([ep[:audio_url]])
    end

    def run_ask
      config = PodcastConfig.new(@podcast_name)

      unless config.type == "language"
        $stderr.puts "Error: --ask requires a language pipeline podcast (type: language)"
        return 2
      end

      history = EpisodeHistory.new(config.history_path, excluded_urls_path: config.excluded_urls_path)
      exclude_set = history.all_urls

      configured_feeds = config.sources["rss"]
      unless configured_feeds.is_a?(Array) && configured_feeds.any?
        $stderr.puts "Error: No RSS sources configured in guidelines.md"
        return 2
      end

      begin
        feeds = resolve_feeds(configured_feeds, @rss_filter)
      rescue RuntimeError => e
        $stderr.puts "Error: #{e.message}"
        return 1
      end

      require_relative File.join(File.expand_path("../..", __dir__), "lib", "sources", "rss_source")
      source = RSSSource.new(feeds: feeds)
      episodes = source.fetch_episodes(exclude_urls: exclude_set)

      if episodes.empty?
        $stderr.puts "No unprocessed episodes found."
        return 1
      end

      episodes = episodes.first(@ask)

      puts "Next unprocessed episodes:"
      episodes.each_with_index do |ep, i|
        date = ep[:pub_date]&.strftime("%Y-%m-%d") || "unknown"
        info = "  #{i + 1}. [#{date}] #{ep[:title]}"
        info += " (#{ep[:duration]})" if ep[:duration]
        info += " [#{(ep[:file_size] / (1024.0 * 1024)).round(1)} MB]" if ep[:file_size]&.positive?
        puts info
      end
      puts

      $stdout.write "Exclude (comma-separated numbers, or Enter to cancel): "
      $stdout.flush
      input = $stdin.gets&.strip
      return 0 if input.nil? || input.empty?

      indices = input.split(",").map(&:strip).filter_map { |s|
        n = s.to_i
        n if n >= 1 && n <= episodes.length
      }.uniq

      if indices.empty?
        puts "No valid selections."
        return 0
      end

      urls = indices.map { |i| episodes[i - 1][:audio_url] }
      exclude_urls(urls)
    end

    def resolve_feeds(configured_feeds, rss_filter)
      return configured_feeds if rss_filter.nil?

      filter = rss_filter.downcase
      matched = configured_feeds.select do |feed|
        if feed.is_a?(Hash)
          feed[:url].downcase.include?(filter) || feed[:tag]&.downcase&.include?(filter)
        else
          feed.downcase.include?(filter)
        end
      end

      return matched unless matched.empty?

      if rss_filter.match?(%r{\Ahttps?://})
        [rss_filter]
      else
        raise "No configured RSS feed matches '#{rss_filter}'"
      end
    end

    def exclude_urls(urls)
      config = PodcastConfig.new(@podcast_name)
      history = EpisodeHistory.new(config.history_path, excluded_urls_path: config.excluded_urls_path)

      cleaned = urls.map { |u| UrlCleaner.clean(u) }
      existing = history.all_urls
      new_urls = cleaned.reject { |u| existing.include?(u) }
      dupes = cleaned.length - new_urls.length

      if new_urls.empty?
        puts "All #{cleaned.length} URL(s) already excluded."
        return 0
      end

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
