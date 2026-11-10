# frozen_string_literal: true

require "optparse"

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "cli", "podcast_command")
require_relative File.join(root, "lib", "cli", "publish_options")
require_relative File.join(root, "lib", "cli", "episode_selector")
require_relative File.join(root, "lib", "episode_scanner")
require_relative File.join(root, "lib", "cli", "rss_command")
require_relative File.join(root, "lib", "site_generator")
require_relative File.join(root, "lib", "regen_cache")
require_relative File.join(root, "lib", "r2_publisher")
require_relative File.join(root, "lib", "lingq_publisher")
require_relative File.join(root, "lib", "youtube_publisher")

module PodgenCLI
  # Thin dispatcher over R2Publisher / LingQPublisher / YouTubePublisher.
  # All the per-target logic (rclone sync, LingQ upload, YouTube upload,
  # subtitle reconciliation, retranscription, cover generation, upload
  # tracking) lives in the publisher classes — this command only:
  #   - parses CLI flags
  #   - regenerates RSS + site once before dispatch (memoized via RegenCache)
  #   - threads @episode_id into each publisher
  #   - maps publisher errors to exit codes
  class PublishCommand
    include PodcastCommand

    def initialize(args, options)
      @options = options
      OptionParser.new do |opts|
        PublishOptions.define(opts, @options) { |v| @episode_id = v }
      end.parse!(args)
      @podcast_name = args.shift
      @episode_id ||= args.shift # optional: e.g. "2026-03-31" or "2026-03-31b"
      reject_leftover_args!(args)
      @episode_id = normalize_episode_id(@episode_id) if @episode_id
    end

    def run
      code = require_podcast!("publish")
      return code if code

      load_config!

      # Regenerate RSS feed and static site before publishing.
      # Memoized per-podcast in-process so batch flows (e.g. yt-batch) skip
      # repeated regen when the same publisher runs against the same pod.
      RegenCache.ensure_regen(@config) do
        regenerate_rss
        regenerate_site
      end

      dispatch_publish
    end

    private

    # Q-132: the short forms the other episode commands accept (MMDD, DD,
    # …) resolve to one full YYYY-MM-DD[a-z]; a raw "17" would otherwise
    # suffix-match the 17th of every month. A full basename of this podcast
    # (<pod>-YYYY-MM-DD[a-z]) is kept as is and matched exactly.
    def normalize_episode_id(raw)
      prefix = "#{@podcast_name}-"
      return raw if raw.start_with?(prefix) && raw.delete_prefix(prefix).match?(EpisodeScanner::EPISODE_ID_RE)

      date, suffix = EpisodeSelector::DateParser.parse(raw)
      "#{date.strftime("%Y-%m-%d")}#{suffix}"
    rescue ArgumentError => e
      raise OptionParser::ParseError, e.message
    end

    # Dispatch table:
    #   no flags          → [:r2]
    #   --lingq           → [:lingq]
    #   --youtube         → [:youtube]
    #   --lingq --youtube → [:lingq, :youtube]
    #   --all             → [:r2, :lingq, :youtube]
    #
    # Targets run sequentially. Failures don't halt later targets. Final
    # exit code is the worst (highest) of all per-target codes.
    def dispatch_publish
      targets = if @options[:all]
        %i[r2 lingq youtube]
      elsif @options[:lingq] || @options[:youtube]
        [].tap do |t|
          t << :lingq   if @options[:lingq]
          t << :youtube if @options[:youtube]
        end
      else
        [:r2]
      end

      codes = targets.map do |target|
        case target
        when :r2      then publish_to_r2
        when :lingq   then publish_to_lingq
        when :youtube then publish_to_youtube
        end
      end
      codes.max || 0
    end

    # Unrescued on purpose — fatal: a feed that fails to regenerate aborts
    # the publish rather than shipping a stale feed.
    def regenerate_rss
      rss_opts = { verbosity: @options[:verbosity] }
      rss = RssCommand.new([@podcast_name], rss_opts)
      rss.run
    end

    def regenerate_site
      generator = SiteGenerator.new(config: @config, clean: true)
      generator.generate
    rescue => e # skippable: the feed already regenerated; a stale site is repaired by the next publish
      $stderr.puts "Warning: site/feed regen failed: #{e.class}: #{e.message}"
    end

    def publish_to_r2
      result = R2Publisher.new(config: @config, options: @options, episode_id: @episode_id).run
      return 2 if result.errors.any? { |e| %i[rclone_missing missing_env].include?(e[:type]) }
      return 1 if result.errors.any? { |e| e[:type] == :rclone_failed }
      0
    end

    def publish_to_lingq
      result = LingQPublisher.new(config: @config, options: @options, episode_id: @episode_id).run
      not_configured = result.errors.any? { |e| %i[not_configured no_language].include?(e[:type]) }
      if not_configured && @options[:all]
        puts "  LingQ: skipped (not configured)" unless @options[:verbosity] == :quiet
        return 0
      end
      return 2 if not_configured
      result.errors.any? ? 1 : 0 # Q-132: a failed episode upload (or unreadable ledger) is a failed run
    end

    def publish_to_youtube
      # Lazy-load the google-apis gems before constructing the uploader.
      # build_youtube_uploader instantiates YouTubeUploader; the constant must
      # exist at that call site, not deferred to YouTubePublisher#run.
      require_relative File.join(File.expand_path("../..", __dir__), "lib", "youtube_uploader")

      publisher = YouTubePublisher.new(
        config: @config,
        options: @options,
        uploader: build_youtube_uploader,
        episode_id: @episode_id
      )
      result = publisher.run
      not_configured = result.errors.any? { |e| e[:type] == :not_configured }
      if not_configured && @options[:all]
        puts "  YouTube: skipped (not configured)" unless @options[:verbosity] == :quiet
        return 0
      end
      return 2 if not_configured
      # Playlist/authorization failures upload nothing (Q-77/Q-80); per-episode
      # upload, video, cover, quota and ledger errors fail the run too (Q-132).
      result.errors.any? ? 1 : 0
    end

    def build_youtube_uploader
      YouTubeUploader.new
    end
  end
end
