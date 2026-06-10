# frozen_string_literal: true

require_relative "upload_tracker"
require_relative "transcript_parser"
require_relative "episode_scanner"

# Helpers shared by R2Publisher / LingQPublisher / YouTubePublisher.
# Expects the including class to set @config, @options, @tracker_path and
# @episode_id in its constructor.
module PublisherShared
  private

  def regenerate!
    require_relative "cli/rss_command"
    require_relative "site_generator"
    PodgenCLI::RssCommand.new([@config.name], {verbosity: @options[:verbosity]}).run
    SiteGenerator.new(config: @config, clean: true).generate
  rescue => e # skippable: stale feed/site is acceptable; next publish regenerates
    $stderr.puts "Warning: site/feed regen failed: #{e.class}: #{e.message}"
  end

  def scan_episodes
    EpisodeScanner.scan(@config.episodes_dir, episode_id: @episode_id)
  end

  def parse_transcript(path)
    parsed = TranscriptParser.parse(path)
    [parsed.title, parsed.description, parsed.body]
  end

  def tracker
    @tracker ||= @tracker_path ? UploadTracker.new(@tracker_path) : UploadTracker.for_config(@config)
  end

  def quiet?
    @options[:verbosity] == :quiet
  end
end
