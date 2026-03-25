# frozen_string_literal: true

require "set"
require "tmpdir"
require_relative "loggable"
require_relative "sources/rss_source"
require_relative "http_downloader"

class EpisodeSource
  include Loggable

  def initialize(config:, history:, logger: nil)
    @config = config
    @history = history
    @logger = logger
  end

  def build_local(path, title = nil)
    expanded = File.expand_path(path)
    raise "File not found: #{expanded}" unless File.exist?(expanded)
    raise "File is empty: #{expanded}" unless File.size(expanded) > 0

    title ||= File.basename(path, File.extname(path))
      .gsub(/[_-]/, " ")
      .gsub(/\b\w/) { |m| m.upcase }

    # Use filename:size as the dedup key so moving the file doesn't break history
    file_id = "file://#{File.basename(path)}:#{File.size(expanded)}"

    {
      title: title,
      description: "",
      audio_url: file_id,
      source_path: expanded,
      pub_date: Time.now,
      link: nil
    }
  end

  def build_youtube(metadata, title_override: nil)
    {
      title: title_override || metadata[:title],
      description: metadata[:description].to_s,
      audio_url: metadata[:url],
      source_path: nil,
      pub_date: Time.now,
      link: metadata[:url]
    }
  end

  def already_processed?(episode, force: false, dry_run: false)
    return false if force || dry_run
    return false unless @history.all_urls.include?(episode[:audio_url])

    log("Warning: Already processed: #{episode[:audio_url]}")
    $stderr.puts "Already processed: \"#{episode[:title]}\" — use --force to re-process"
    true
  end

  def fetch_next(force: false, rss_filter: nil)
    rss_feeds = @config.sources["rss"]
    unless rss_feeds.is_a?(Array) && rss_feeds.any?
      raise "Language pipeline requires RSS sources in guidelines.md (## Sources → - rss:)"
    end

    feeds = resolve_feeds(rss_feeds, rss_filter)
    source = RSSSource.new(feeds: feeds, logger: @logger)
    exclude = force ? Set.new : @history.all_urls
    episodes = source.fetch_episodes(exclude_urls: exclude)

    if episodes.empty?
      log("No episodes with audio enclosures found")
      return nil
    end

    log("Found #{episodes.length} episodes with audio enclosures")
    episodes.first
  end

  def download_audio(url)
    path = File.join(Dir.tmpdir, "podgen_source_#{Process.pid}.mp3")
    HttpDownloader.new(logger: @logger).download(url, path)
    path
  end

  private

  # Resolves which feeds to use given an optional rss_filter.
  # - nil: use all configured feeds
  # - substring match: use only matching configured feed(s)
  # - no match: treat as ad-hoc URL
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

    raise "No configured RSS feed matches '#{rss_filter}'" if matched.empty?

    matched
  end
end
