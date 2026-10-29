# frozen_string_literal: true

require "set"
require "tmpdir"
require "uri"
require "open3"
require_relative "loggable"
require_relative "sources/rss_source"
require_relative "http_downloader"
require_relative "time_value"
require_relative "title_match"

class EpisodeSource
  include Loggable

  MIME_TO_EXT = {
    "audio/mpeg" => ".mp3",
    "audio/mp3" => ".mp3",
    "audio/mp4" => ".m4a",
    "audio/x-m4a" => ".m4a",
    "audio/m4a" => ".m4a",
    "audio/aac" => ".aac",
    "audio/ogg" => ".ogg",
    "audio/opus" => ".opus",
    "audio/flac" => ".flac",
    "audio/x-flac" => ".flac",
    "audio/wav" => ".wav",
    "audio/x-wav" => ".wav",
    "audio/webm" => ".webm"
  }.freeze

  SUPPORTED_EXTENSIONS = MIME_TO_EXT.values.uniq.freeze

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

  # duplicate_prompt: nil (unattended) or a callable (episode, match) →
  # answer; "k" keeps an other-feed title match, anything else skips it.
  def fetch_next(force: false, rss_filter: nil, duplicate_prompt: nil)
    @title_index = nil # built at most once per call (fetch_weighted tries several feeds)
    rss_feeds = @config.sources["rss"]
    unless rss_feeds.is_a?(Array) && rss_feeds.any?
      raise "Language pipeline requires RSS sources in guidelines.md (## Sources → - rss:)"
    end

    feeds = resolve_feeds(rss_feeds, rss_filter)
    mode = rss_filter ? "latest" : select_mode

    case mode
    when "cycle", "weights"
      fetch_weighted(feeds, force: force, duplicate_prompt: duplicate_prompt)
    else
      fetch_from_feeds(feeds, force: force, duplicate_prompt: duplicate_prompt)
    end
  end

  def download_audio(episode)
    ext = audio_extension_for(episode)
    path = File.join(Dir.tmpdir, "podgen_source_#{Process.pid}#{ext}")
    HttpDownloader.new(logger: @logger).download(episode[:audio_url], path)
    probe_and_fix_extension(path)
  end

  def exclude_url!(url)
    require_relative "atomic_writer"
    require_relative "yaml_loader"
    path = @config.respond_to?(:excluded_urls_path) ? @config.excluded_urls_path : nil
    return unless path

    current = YamlLoader.load(path, default: [])
    unless current.include?(url)
      current << url
      AtomicWriter.write_yaml(path, current)
    end
  end

  private

  # ffprobe format_name → correct extension mapping
  FORMAT_TO_EXT = {
    "mp3" => ".mp3",
    "mov,mp4,m4a,3gp,3g2,mj2" => ".m4a",
    "ogg" => ".ogg",
    "flac" => ".flac",
    "wav" => ".wav",
    "aac" => ".aac",
    "matroska,webm" => ".webm",
    "opus" => ".opus"
  }.freeze

  # Probe actual audio format after download and rename if extension is wrong.
  # Returns the (possibly renamed) file path.
  def probe_and_fix_extension(path)
    stdout, _, status = Open3.capture3(
      "ffprobe", "-v", "quiet",
      "-show_entries", "format=format_name",
      "-of", "csv=p=0",
      path
    )
    return path unless status.success?

    format_name = stdout.strip
    correct_ext = FORMAT_TO_EXT[format_name]
    return path unless correct_ext

    current_ext = File.extname(path).downcase
    return path if current_ext == correct_ext

    new_path = path.sub(/\.[^.]+\z/, correct_ext)
    File.rename(path, new_path)
    log("Audio format mismatch: renamed #{current_ext} → #{correct_ext}")
    new_path
  rescue Errno::ENOENT
    path # ffprobe not installed, keep as-is
  end

  # Determine file extension from MIME type (preferred) or URL path.
  def audio_extension_for(episode)
    # 1. MIME type from RSS enclosure (most reliable)
    if (mime = episode[:content_type])
      ext = MIME_TO_EXT[mime.downcase]
      return ext if ext
    end

    # 2. URL path extension (handles encoded nested URLs like Anchor.fm)
    url = episode[:audio_url].to_s
    decoded = URI.decode_www_form_component(url) rescue url # skippable: silent fallback — the undecoded URL
    [decoded, url].each do |candidate|
      ext = File.extname(candidate.split("?").first.split("#").first).downcase
      return ext if SUPPORTED_EXTENSIONS.include?(ext)
    end

    ".mp3" # fallback
  end

  def select_mode
    mode = @config.sources["select"]
    mode = mode.first if mode.is_a?(Array)
    mode || "latest"
  end

  def fetch_from_feeds(feeds, force: false, duplicate_prompt: nil)
    source = RSSSource.new(feeds: feeds, logger: @logger)
    exclude = force ? Set.new : @history.all_urls
    episodes = source.fetch_episodes(exclude_urls: exclude)

    if episodes.empty?
      log("No episodes with audio enclosures found")
      return nil
    end

    log("Found #{episodes.length} episodes with audio enclosures")
    episodes, pending = guard_titles(episodes, force: force, prompt: duplicate_prompt)
    return nil if episodes.empty?
    episodes = filter_by_length(episodes)
    return nil if episodes.empty?

    pick_first(episodes, pending, duplicate_prompt)
  end

  def fetch_weighted(feeds, force: false, duplicate_prompt: nil)
    mode = select_mode
    default_weight = mode == "cycle" ? 1 : 0
    pool = feeds.select { |f| feed_weight(f, default_weight) > 0 }

    if pool.empty?
      log("No feeds with positive weight")
      return nil
    end

    exclude = force ? Set.new : @history.all_urls
    log("Feed selection: #{mode} mode, #{pool.length} feed(s) in pool")

    while pool.any?
      feed = weighted_pick(pool, default_weight)
      source = RSSSource.new(feeds: [feed], logger: @logger)
      episodes = source.fetch_episodes(exclude_urls: exclude)
      episodes, pending = guard_titles(episodes, force: force, prompt: duplicate_prompt)
      episodes = filter_by_length(episodes) if episodes.any?
      picked = pick_first(episodes, pending, duplicate_prompt) if episodes.any?

      if picked
        tag = feed.is_a?(Hash) ? feed[:tag] : nil
        log("Selected feed#{tag ? " '#{tag}'" : ""} (weight #{feed_weight(feed, default_weight)}): #{episodes.length} episode(s) available")
        return picked
      end

      pool.delete(feed)
    end

    log("No episodes with audio enclosures found (all feeds exhausted)")
    nil
  end

  # Re-post guard (Q-88, P10-0): sources re-post a story under a new audio
  # URL with an extended title, which the URL exclusion cannot see. A
  # candidate whose title matches a history title (TitleMatch) is skipped
  # when no prompt is given. Under a prompt (--ask-trim) matches stay in
  # the list as `pending` and are asked about only when they would be the
  # pick (still before any download); the match says whether its feed_key
  # equals one recorded on that entry (same feed — likely a re-post).
  # Returns [kept_episodes, pending (identity hash episode → match)].
  def guard_titles(episodes, force:, prompt:)
    pending = {}.compare_by_identity
    return [episodes, pending] if force || episodes.empty?

    index = (@title_index ||= history_title_index)
    return [episodes, pending] if index.empty?

    kept = episodes.reject do |ep|
      match = title_match_for(ep, index)
      next false unless match

      if prompt.nil?
        report_title_duplicate(match)
        next true
      end
      pending[ep] = match
      false
    end
    [kept, pending]
  end

  def pick_first(episodes, pending, prompt)
    episodes.find do |ep|
      match = pending[ep]
      next true unless match

      if prompt.call(ep, match).to_s.strip.downcase == "k"
        log("Keeping \"#{ep[:title]}\" (earlier: #{match[:basename]})")
        next true
      end
      report_title_duplicate(match)
      false
    end
  end

  def report_title_duplicate(match)
    line = "Already processed as #{match[:basename]} (#{match[:date]}): title match \"#{match[:title]}\""
    log(line)
    $stderr.puts line
  end

  # The history match for a candidate (a same-feed match wins over an
  # other-feed one), or nil when no history title matches.
  def title_match_for(episode, index)
    key = TitleMatch.key(episode[:title])
    return nil if key.stem.empty?

    matches = index.select { |entry| TitleMatch.keys_match?(entry[:key], key) }
    return nil if matches.empty?

    feed = feed_key(episode[:audio_url])
    same = feed && matches.find { |m| m[:feeds].include?(feed) }
    (same || matches.first).merge(same_feed: !same.nil?)
  end

  def history_title_index
    @history.all_episodes.filter_map do |e|
      title = e["title"].to_s
      next if title.strip.empty?

      {basename: e["basename"] || e["date"], date: e["date"], title: title,
       key: TitleMatch.key(title), feeds: (e["urls"] || []).filter_map { |u| feed_key(u) }.to_set}
    end
  end

  # Path segments that name a redirector or a hosting platform's show
  # prefix, not the feed: the next segment joins the key (podtrac's
  # `redirect.mp3/<real host>`, anchor.fm's `s/<show>`).
  REDIRECT_SEGMENTS = %w[redirect r track e p s].freeze

  # Same-feed key (P10-0b): host + first path segment, plus the next
  # segment when the first is a redirector (ends in .mp3 or is listed).
  def feed_key(url)
    uri = URI.parse(url.to_s)
    return nil unless uri.host

    segments = uri.path.to_s.split("/").reject(&:empty?)
    first = segments.first.to_s.downcase
    take = (first.end_with?(".mp3") || REDIRECT_SEGMENTS.include?(first)) ? 2 : 1
    [uri.host.downcase, *segments.first(take)].join("/")
  rescue URI::InvalidURIError
    nil
  end

  def feed_weight(feed, default)
    feed.is_a?(Hash) ? (feed[:weight] || default) : default
  end

  # Filters episodes by config min_length / max_length using each item's
  # itunes_duration metadata. Episodes with missing or unparseable
  # :duration are kept (will be checked post-download).
  def filter_by_length(episodes)
    min_s = @config.respond_to?(:min_length_seconds) ? @config.min_length_seconds : nil
    max_s = @config.respond_to?(:max_length_seconds) ? @config.max_length_seconds : nil
    return episodes unless min_s || max_s

    too_short = 0
    too_long = 0
    unknown = 0
    kept = episodes.select do |ep|
      secs = TimeValue.parse_duration_seconds(ep[:duration])
      if secs.nil?
        unknown += 1
        next true
      end
      if min_s && secs < min_s
        too_short += 1
        next false
      end
      if max_s && secs > max_s
        too_long += 1
        next false
      end
      true
    end

    range = "#{format_length(min_s)}–#{format_length(max_s)}"
    parts = ["#{kept.length}/#{episodes.length} kept"]
    parts << "#{too_short} too short" if too_short > 0
    parts << "#{too_long} too long" if too_long > 0
    parts << "#{unknown} unknown duration" if unknown > 0
    log("Length filter [#{range}]: #{parts.join(', ')}")
    kept
  end

  def format_length(secs)
    return "?" unless secs
    m = (secs / 60).to_i
    s = (secs % 60).round
    "#{m}:#{s.to_s.rjust(2, '0')}"
  end

  public

  # Returns :ok, :too_short, or :too_long for the given audio duration in
  # seconds. Used by the language pipeline post-download to validate
  # episodes whose RSS metadata didn't include a usable :duration.
  def length_check(seconds)
    min_s = @config.respond_to?(:min_length_seconds) ? @config.min_length_seconds : nil
    max_s = @config.respond_to?(:max_length_seconds) ? @config.max_length_seconds : nil
    return :ok unless seconds.is_a?(Numeric)
    return :too_short if min_s && seconds < min_s
    return :too_long if max_s && seconds > max_s
    :ok
  end

  private

  def weighted_pick(feeds, default_weight)
    total = feeds.sum { |f| feed_weight(f, default_weight) }
    point = rand * total
    cumulative = 0.0

    feeds.each do |feed|
      cumulative += feed_weight(feed, default_weight)
      return feed if cumulative > point
    end

    feeds.last
  end

  # Resolves which feeds to use given an optional rss_filter.
  # - nil: use all configured feeds
  # - substring match: use only matching configured feed(s)
  # - no match + looks like URL: warn and use as ad-hoc feed
  # - no match + not a URL: raises RuntimeError (likely a typo)
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
      log("No configured feed matches '#{rss_filter}' — using as ad-hoc URL")
      [rss_filter]
    else
      raise "No configured RSS feed matches '#{rss_filter}'"
    end
  end
end
