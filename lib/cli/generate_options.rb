# frozen_string_literal: true

require "date"
require "optparse"

root = File.expand_path("../..", __dir__)
require_relative File.join(root, "lib", "time_value")
require_relative File.join(root, "lib", "snip_interval")

module PodgenCLI
  # The single definition of `podgen generate`'s options. GenerateCommand
  # parses with it; the owner guard in lib/cli.rb dry-parses with it, so the
  # guard sees exactly what the real parser would set. Keep requires light:
  # the guard loads this before any command class.
  module GenerateOptions
    def self.define(opts, options)
      opts.on("--file PATH", "Local audio file (language pipeline)") { |f| options[:file] = f }
      opts.on("--url URL", "YouTube video URL (language pipeline)") { |u| options[:url] = u }
      opts.on("--rss URL", "RSS feed: URL or substring of configured feed") { |u| options[:rss] = u }
      opts.on("--title TEXT", "Episode title (with --file or --url)") { |t| options[:title] = t }
      opts.on("--skip-intro N", "--skip N", String, "Seconds or min:sec to skip from start") { |n| options[:skip] = TimeValue.parse(n) }
      opts.on("--cut-outro N", "--cut N", String, "Seconds or min:sec to cut from end (min:sec = absolute)") { |n| options[:cut] = TimeValue.parse(n) }
      opts.on("--snip INTERVALS", String, "Remove interior segments (e.g. 1:20-2:30,3:40+33)") { |s| options[:snip] = SnipInterval.parse(s) }
      opts.on("--autotrim", "Enable outro auto-detection via word timestamps") { options[:autotrim] = true }
      opts.on("--no-autotrim", "Disable autotrim even if configured") { options[:no_autotrim] = true }
      opts.on("--no-skip", "Disable skip even if configured") { options[:no_skip] = true }
      opts.on("--ask-trim", "--ask-skip", "Download audio, play it, then prompt for skip and cut values") { options[:ask_trim] = true }
      opts.on("--no-cut", "Disable cut even if configured") { options[:no_cut] = true }
      opts.on("--force", "Process even if already in history (skip dedup check)") { options[:force] = true }
      opts.on("--image PATH", "Cover: file path, 'thumb' (YouTube), 'last' (~/Desktop screenshot), or 'auto' (DDG search)") { |p| options[:image] = p }
      opts.on("--base-image PATH", "Base image for cover generation (with --file or --url)") { |p| options[:base_image] = p }
      opts.on("--lingq", "Enable LingQ upload during generation") { options[:lingq] = true }
      opts.on("--youtube", "Enable YouTube upload during generation") { options[:youtube] = true }
      opts.on("--date DATE", "Episode date (YYYY-MM-DD, default: today)") { |d| options[:date] = Date.parse(d) }
      opts.on("--include WORDS", "Force-include vocabulary lemmas (comma-separated)") { |v| options[:include_words] = Set.new(v.split(",").map { |w| w.strip.downcase }) }
      opts.on("--from-script", "DEPRECATED: prefer 'podgen voice <pod> [--lang LANG]'. Resumes voicing from saved script JSON.") {
        options[:from_script] = true
        options[:force] = true
      }
      opts.on("--dry-run", "Validate config, skip API calls") { options[:dry_run] = true }
    end

    # Parses a copy of argv exactly as GenerateCommand does and returns the
    # options hash it would build, or nil when the real parse would fail
    # (invalid, ambiguous or needless option, bad date/time value) or would
    # print and exit instead of running (--help, --version, completion).
    def self.dry_parse(argv)
      options = {}
      parser = OptionParser.new { define(it, options) }
      # Shadow the built-in help/version switches so a dry parse never prints.
      %w[--help --version].each { |name| parser.on(name) { throw :generate_options_exit } }
      parsed = catch(:generate_options_exit) do
        parser.parse!(argv.dup)
        true
      end
      parsed ? options : nil
    rescue OptionParser::ParseError, ArgumentError, SystemExit
      nil
    end
  end
end
