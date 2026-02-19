# frozen_string_literal: true

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "podcast_config")
require_relative File.join(root, "lib", "rss_generator")

module PodgenCLI
  class RssCommand
    def initialize(args, options)
      @podcast_name = args.shift
      @options = options
    end

    def run
      unless @podcast_name
        available = PodcastConfig.available
        $stderr.puts "Usage: podgen rss <podcast_name>"
        $stderr.puts
        if available.any?
          $stderr.puts "Available podcasts:"
          available.each { |name| $stderr.puts "  - #{name}" }
        end
        return 2
      end

      config = PodcastConfig.new(@podcast_name)
      config.load_env!

      feed_paths = []

      config.languages.each do |lang|
        lang_code = lang["code"]

        feed_path = if lang_code == "en"
          config.feed_path
        else
          config.feed_path.sub(/\.xml$/, "-#{lang_code}.xml")
        end

        generator = RssGenerator.new(
          episodes_dir: config.episodes_dir,
          feed_path: feed_path,
          title: config.title,
          author: config.author,
          language: lang_code
        )
        generator.generate
        feed_paths << feed_path
      end

      unless @options[:verbosity] == :quiet
        feed_paths.each { |fp| puts "Feed: #{fp}" }
        puts
        puts "To serve locally:"
        puts "  cd #{File.dirname(config.feed_path)} && ruby -run -e httpd . -p 8080"
        puts "  Feed URL: http://localhost:8080/feed.xml"
      end

      0
    end
  end
end
