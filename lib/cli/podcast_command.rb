# frozen_string_literal: true

require "optparse"
require "did_you_mean"

root = File.expand_path("../..", __dir__)
require_relative File.join(root, "lib", "podcast_config")

module PodgenCLI
  # Shared helpers for CLI commands that operate on a single podcast.
  # Include in command classes that accept a podcast name argument.
  module PodcastCommand
    private

    # Validates that @podcast_name is set and exists. Prints usage and available
    # podcasts if missing or unknown. Returns exit code 2 on failure, nil on success.
    def require_podcast!(command_name)
      available = PodcastConfig.available

      unless @podcast_name
        $stderr.puts "Usage: podgen #{command_name} <podcast_name>"
        $stderr.puts
        if available.any?
          $stderr.puts "Available podcasts:"
          available.each { |name| $stderr.puts "  - #{name}" }
        end
        return 2
      end

      return nil if available.include?(@podcast_name)

      $stderr.puts "Unknown podcast: #{@podcast_name}"
      $stderr.puts
      suggest_similar(@podcast_name, available)
      $stderr.puts "Available podcasts:"
      available.each { |name| $stderr.puts "  - #{name}" }
      2
    end

    # Q-159 (11): DidYouMean's distance raises on invalid UTF-8 argv, so
    # the name is scrubbed first; the suggestion list still prints.
    def suggest_similar(name, available)
      clean = name.scrub
      close = available.select { |a| DidYouMean::Levenshtein.distance(clean, a) <= [clean.length / 3, 2].max }
      return if close.empty?

      $stderr.puts "Did you mean?"
      close.each { |c| $stderr.puts "  - #{c}" }
      $stderr.puts
    end

    # Creates and returns a PodcastConfig, calling load_env! automatically.
    def load_config!
      @config = PodcastConfig.new(@podcast_name)
      @config.load_env!
      @config
    end

    # Raises if any positional args remain after expected positionals were
    # extracted. Catches typos like `-rss URL` (parsed as `--rss=ss` plus a
    # leftover `URL`) and stray words like `generate <pod> extra_arg`.
    def reject_leftover_args!(args)
      return if args.empty?
      raise OptionParser::ParseError, "unexpected argument(s): #{args.join(' ')}"
    end
  end
end
