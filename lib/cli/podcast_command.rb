# frozen_string_literal: true

root = File.expand_path("../..", __dir__)
require_relative File.join(root, "lib", "podcast_config")

module PodgenCLI
  # Shared helpers for CLI commands that operate on a single podcast.
  # Include in command classes that accept a podcast name argument.
  module PodcastCommand
    private

    # Validates that @podcast_name is set. Prints usage and available podcasts
    # if missing. Returns exit code 2 on failure, nil on success.
    def require_podcast!(command_name)
      return nil if @podcast_name

      available = PodcastConfig.available
      $stderr.puts "Usage: podgen #{command_name} <podcast_name>"
      $stderr.puts
      if available.any?
        $stderr.puts "Available podcasts:"
        available.each { |name| $stderr.puts "  - #{name}" }
      end
      2
    end

    # Creates and returns a PodcastConfig, calling load_env! automatically.
    def load_config!
      @config = PodcastConfig.new(@podcast_name)
      @config.load_env!
      @config
    end
  end
end
