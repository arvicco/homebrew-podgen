# frozen_string_literal: true

require "optparse"

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "podcast_config")
require_relative File.join(root, "lib", "site_generator")

module PodgenCLI
  class SiteCommand
    def initialize(args, options)
      @options = options
      @clean = false
      @base_url = nil

      OptionParser.new do |opts|
        opts.on("--clean", "Remove existing site/ before generating") { @clean = true }
        opts.on("--base-url URL", "Override base_url from config") { |url| @base_url = url }
      end.parse!(args)

      @podcast_name = args.shift
    end

    def run
      unless @podcast_name
        available = PodcastConfig.available
        $stderr.puts "Usage: podgen site <podcast_name>"
        $stderr.puts
        if available.any?
          $stderr.puts "Available podcasts:"
          available.each { |name| $stderr.puts "  - #{name}" }
        end
        return 2
      end

      @config = PodcastConfig.new(@podcast_name)
      @config.load_env!

      generator = SiteGenerator.new(
        config: @config,
        base_url: @base_url,
        clean: @clean
      )

      generator.generate
      0
    end
  end
end
