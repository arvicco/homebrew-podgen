# frozen_string_literal: true

require_relative "regen_cache"
require_relative "upload_tracker"
require_relative "transcript_parser"
require_relative "cover_resolver"
require_relative "episode_scanner"
require_relative "publisher_shared"

# Publishes pending episodes to YouTube for a single podcast configuration.
#
# Extracted from PublishCommand#publish_to_youtube so that batch flows
# (e.g. yt-batch) can call it in-process and inspect a structured Result
# instead of parsing subprocess stdout for "uploaded N" / "rate limited".
#
# Calls RegenCache.ensure_regen so RSS+site regen happens once per podcast
# per process — when run from yt-batch, the second-and-later ticks per pod
# (round-robin) skip regen automatically.
class YouTubePublisher
  include PublisherShared

  Result = Struct.new(:uploaded, :attempted, :rate_limited, :errors, keyword_init: true) do
    def success? = errors.empty? && !rate_limited
  end

  TIMESTAMP_ENGINE_PRIORITY = %w[groq elab open].freeze

  # In-process cache of (pod_name, playlist_id) verifications. Round-robin
  # creates a fresh publisher per upload, so without this each tick would
  # hit YouTube's playlists API N×M times (M = pending eps per pod) instead
  # of once per pod per tick.
  @verified_playlists = {}
  @verify_mutex = Mutex.new

  class << self
    def playlist_verified?(key)
      @verify_mutex.synchronize { @verified_playlists[key] }
    end

    def mark_playlist_verified(key)
      @verify_mutex.synchronize { @verified_playlists[key] = true }
    end

    def reset_playlist_cache!
      @verify_mutex.synchronize { @verified_playlists.clear }
    end

    # Class names only for a token-endpoint failure: googleauth's message
    # inspects the cause, which for a Google 5xx (or a rejected grant)
    # carries the response body — never into a log line. nil otherwise.
    def auth_failure_summary(e)
      return nil unless defined?(Signet::AuthorizationError) && e.is_a?(Signet::AuthorizationError)

      e.cause ? "#{e.class} (cause #{e.cause.class})" : e.class.name
    end
  end

  # Outcome of #upload_episode. status: :uploaded, :skipped (never reached
  # upload_video), :failed, or :rate_limited (quota — callers stop a batch).
  # error is the typed {type:, base:, message:} entry; exception the cause
  # when one was raised. video_id is set once upload_video succeeded, even
  # if captions/playlist failed after it (the upload is already recorded).
  EpisodeResult = Struct.new(:status, :base, :video_id, :attempted, :error, :exception, keyword_init: true)

  # logger: optional; when given, routine output goes to logger.log instead
  # of stdout/stderr (the generate pipeline passes its run logger).
  def initialize(config:, options: {}, uploader: nil, tracker_path: nil, episode_id: nil, logger: nil)
    @config = config
    @options = options
    @uploader = uploader
    @tracker_path = tracker_path
    @episode_id = episode_id
    @logger = logger
  end

  def run
    unless @config.youtube_enabled?
      msg = "YouTube not configured. Add ## YouTube section to guidelines.md and set YOUTUBE_CLIENT_ID/YOUTUBE_CLIENT_SECRET."
      $stderr.puts msg
      return Result.new(uploaded: 0, attempted: 0, rate_limited: false,
                        errors: [{ type: :not_configured, message: msg }])
    end

    RegenCache.ensure_regen(@config) { regenerate! }

    yt_config = @config.youtube_config
    playlist = yt_config[:playlist] || "default"

    episodes = scan_episodes
    if episodes.empty? && @episode_id
      $stderr.puts "No episode found matching '#{@episode_id}'"
      return Result.new(uploaded: 0, attempted: 0, rate_limited: false, errors: [])
    end

    uploaded_map = @options[:force] ? {} : tracker.entries_for(:youtube, playlist)
    pending = episodes.reject { |ep| uploaded_map.key?(ep[:base_name]) }
    pending = pending.first(@options[:max]) if @options[:max]

    if pending.empty?
      puts "All episodes already uploaded to YouTube#{yt_config[:playlist] ? " playlist #{yt_config[:playlist]}" : ""}." unless quiet?
      return Result.new(uploaded: 0, attempted: 0, rate_limited: false, errors: [])
    end

    puts "#{pending.length} episode(s) to upload to YouTube" unless quiet?

    if @options[:dry_run]
      pending.each { |ep| puts "  would upload: #{ep[:base_name]}" } unless quiet?
      puts "(dry run)" unless quiet?
      return Result.new(uploaded: 0, attempted: 0, rate_limited: false, errors: [])
    end

    require_relative "youtube_uploader"
    require_relative "subtitle_generator"
    require_relative "video_generator"

    uploader = active_uploader

    # Q-80: authorize before any per-episode work (subtitles, mp4), so a
    # refused consent or an auth failure costs nothing.
    begin
      uploader.authorize!
    rescue YouTubeUploader::NotInteractive => e # fatal for the whole batch: nobody can authorize (Q-77)
      $stderr.puts "YouTube not authorized: #{e.message}"
      return Result.new(uploaded: 0, attempted: 0, rate_limited: false,
                        errors: [not_authorized_error(e)])
    rescue => e # fatal for this run: every episode would fail the same way; the token is kept (Q-79)
      # Class names only: googleauth's message inspects the cause, which for a
      # Google 5xx carries the response body — never into a log line.
      summary = self.class.auth_failure_summary(e) || "#{e.class}: #{e.message}"
      $stderr.puts "YouTube authorization failed: #{summary}"
      return Result.new(uploaded: 0, attempted: 0, rate_limited: false,
                        errors: [{ type: :authorization, error_class: e.class.name,
                                   cause_class: e.cause&.class&.name, message: summary }.compact])
    end

    if yt_config[:playlist]
      begin
        verify_playlist_cached!(uploader, yt_config[:playlist])
      rescue YouTubeUploader::NotInteractive => e # fatal for the whole batch: nobody can authorize (Q-77)
        $stderr.puts "YouTube not authorized: #{e.message}"
        return Result.new(uploaded: 0, attempted: 0, rate_limited: false,
                          errors: [not_authorized_error(e)])
      rescue => e # fatal for this run: uploading into the wrong/missing playlist is worse than not uploading
        $stderr.puts "YouTube playlist verification failed: #{e.class}: #{e.message}"
        return Result.new(uploaded: 0, attempted: 0, rate_limited: false,
                          errors: [{ type: :playlist_verification, message: e.message }])
      end
    end

    upload_loop(pending)
  end

  # The one per-episode YouTube upload routine (P4-8), shared by publish /
  # yt-batch (via #run) and the generate pipeline (PostPipelineUploads).
  # Steps: verify playlist (cached per pod+playlist) → cover check (before
  # any paid subtitle work) → subtitles → video (existing mp4 reused) →
  # upload → record → captions → playlist.
  #
  # ep: {base_name:, mp3_path:, transcript_path:}.
  # metadata: optional {title:, description:} from the caller's in-memory
  #   episode; a non-nil field wins, the transcript file is the fallback.
  # timestamps_authoritative: the caller just produced (and, where it could,
  #   reconciled) the timestamps file itself — skip re-transcription and the
  #   reconcile pass; only render the srt from whatever file exists.
  def upload_episode(ep, metadata: nil, timestamps_authoritative: false)
    require_relative "youtube_uploader"
    require_relative "subtitle_generator"
    require_relative "video_generator"
    require_relative "video_builder"

    base = ep[:base_name]
    yt_config = @config.youtube_config
    language = @config.transcription_language || "en"
    video_id = nil
    attempted = false

    if yt_config[:playlist]
      begin
        verify_playlist_cached!(active_uploader, yt_config[:playlist])
      rescue YouTubeUploader::NotInteractive
        raise # typed below: the batch stops, it does not retry per episode
      rescue => e # skippable per-episode: nothing uploaded; the caller decides whether to continue
        summary = self.class.auth_failure_summary(e)
        say_err "  ✗ #{base} skipped: YouTube playlist verification failed: #{summary || "#{e.class}: #{e.message}"}"
        return EpisodeResult.new(status: :skipped, base: base, attempted: false, exception: e,
          error: { type: :playlist_verification, base: base, message: summary || e.message })
      end
    end

    video_path = File.join(@config.episodes_dir, "#{base}.mp4")
    cover_path = CoverResolver.find_episode_cover(@config.episodes_dir, base)
    unless cover_path || VideoBuilder.reusable?(mp3_path: ep[:mp3_path], video_path: video_path)
      say_err "  ✗ #{base} skipped: no cover image found"
      return EpisodeResult.new(status: :skipped, base: base, attempted: false,
        error: { type: :missing_cover, base: base, message: "no cover image" })
    end

    title, description = episode_metadata(ep, metadata)
    srt_path = prepare_subtitles(ep, timestamps_authoritative: timestamps_authoritative)

    video_error = ensure_video(ep, cover_path, video_path)
    if video_error
      return EpisodeResult.new(status: :skipped, base: base, attempted: false, error: video_error)
    end
    attempted = true

    say "  uploading: #{base} — \"#{title}\""

    uploader = active_uploader
    video_id = uploader.upload_video(
      video_path,
      title: title,
      description: description.to_s,
      language: language,
      privacy: yt_config[:privacy] || "unlisted",
      category: yt_config[:category] || "27",
      tags: yt_config[:tags] || []
    )

    tracker.record(:youtube, yt_config[:playlist] || "default", base, video_id)

    uploader.upload_captions(video_id, srt_path, language: language) if srt_path && File.exist?(srt_path)
    uploader.add_to_playlist(video_id, yt_config[:playlist]) if yt_config[:playlist]

    say "  ✓ #{base} → https://youtu.be/#{video_id}"
    EpisodeResult.new(status: :uploaded, base: base, video_id: video_id, attempted: true)
  rescue Google::Apis::ClientError => e
    say_err "  ✗ #{base} failed: #{e.message}"
    if e.message.include?("uploadLimitExceeded") || e.message.include?("quotaExceeded")
      say_err "  YouTube quota exceeded — stopping batch. Retry after quota resets."
      return EpisodeResult.new(status: :rate_limited, base: base, video_id: video_id, attempted: attempted,
        exception: e, error: { type: :rate_limit, base: base, message: e.message })
    end
    EpisodeResult.new(status: :failed, base: base, video_id: video_id, attempted: attempted,
      exception: e, error: { type: :upload, base: base, message: e.message })
  rescue YouTubeUploader::NotInteractive => e # fatal for the batch: no human can authorize; later episodes would fail the same way (Q-77)
    say_err "  ✗ #{base} skipped: YouTube not authorized: #{e.message}"
    EpisodeResult.new(status: :not_authorized, base: base, attempted: false, # nothing reached YouTube
      exception: e, error: not_authorized_error(e, base: base))
  rescue => e # skippable per-episode: remaining episodes still upload; tracker retries this one
    summary = self.class.auth_failure_summary(e)
    say_err "  ✗ #{base} failed: #{summary || "#{e.class}: #{e.message}"}"
    EpisodeResult.new(status: :failed, base: base, video_id: video_id, attempted: attempted,
      exception: e, error: { type: :upload, base: base, message: summary || e.message })
  end

  private

  def upload_loop(pending)
    uploaded = 0
    attempted = 0
    rate_limited = false
    errors = []

    pending.each do |ep|
      result = upload_episode(ep)
      attempted += 1 if result.attempted
      uploaded += 1 if result.status == :uploaded
      errors << result.error if result.error
      break if result.status == :not_authorized # Q-77: one attempt per run, never per episode
      if result.status == :rate_limited
        rate_limited = true
        break
      end
    end

    Result.new(uploaded: uploaded, attempted: attempted, rate_limited: rate_limited, errors: errors)
  end

  def not_authorized_error(e, base: nil)
    { type: :not_authorized, error_class: e.class.name, message: e.message, base: base }.compact
  end

  def verify_playlist_cached!(uploader, playlist_id)
    verify_key = "#{@config.name}:#{playlist_id}"
    return if self.class.playlist_verified?(verify_key)

    uploader.verify_playlist!(playlist_id)
    self.class.mark_playlist_verified(verify_key)
  end

  def episode_metadata(ep, metadata)
    title = metadata&.[](:title)
    description = metadata&.[](:description)
    if (title.nil? || description.nil?) && ep[:transcript_path] && File.exist?(ep[:transcript_path])
      file_title, file_description, _ = parse_transcript(ep[:transcript_path])
      title ||= file_title
      description ||= file_description
    end
    [title, description]
  end

  def prepare_subtitles(ep, timestamps_authoritative: false)
    episodes_dir = @config.episodes_dir
    ts_path = File.join(episodes_dir, "#{ep[:base_name]}_timestamps.json")
    unless timestamps_authoritative
      retranscribe_for_timestamps(ep[:mp3_path], ts_path, ep[:base_name]) unless File.exist?(ts_path)
      reconcile_subtitles_if_needed(ts_path, ep[:transcript_path]) if File.exist?(ts_path)
    end
    srt_path = File.join(episodes_dir, "#{ep[:base_name]}.srt")
    SubtitleGenerator.generate_srt(ts_path, srt_path) if File.exist?(ts_path)
    srt_path
  end

  # Returns nil when the mp4 is ready (built or reused), else a typed error.
  def ensure_video(ep, cover_path, video_path)
    reusable = VideoBuilder.reusable?(mp3_path: ep[:mp3_path], video_path: video_path)
    say "  generating video #{ep[:base_name]}..." if !reusable && cover_path
    result = VideoBuilder.build(mp3_path: ep[:mp3_path], cover_path: cover_path, video_path: video_path, logger: @logger)

    case result.status
    when :built
      say "  #{ep[:base_name]}: #{result.message}" if result.message.start_with?("video regenerated")
      nil
    when :exists then nil
    when :no_cover
      say_err "  ✗ #{ep[:base_name]} skipped: no cover image found"
      { type: :missing_cover, base: ep[:base_name], message: "no cover image" }
    when :no_audio, :failed
      say_err "  ✗ #{ep[:base_name]} video step failed: #{result.message}"
      { type: :video, base: ep[:base_name], message: result.message }
    end
  end

  def say(msg)
    if @logger
      @logger.log(msg)
    else
      puts msg unless quiet?
    end
  end

  def say_err(msg)
    @logger ? @logger.log(msg) : $stderr.puts(msg)
  end

  def reconcile_subtitles_if_needed(ts_path, transcript_path)
    require_relative "subtitle_reconciliation_runner"

    result = SubtitleReconciliationRunner.run(ts_path: ts_path, transcript_path: transcript_path)
    case result.status
    when :reconciled
      puts "  reconciled subtitles: #{File.basename(ts_path)}" unless quiet?
    when :failed
      $stderr.puts "  Warning: subtitle reconciliation failed: #{result.message} (using raw segments)"
    # :already_reconciled, :no_api_key, :no_transcript, :no_timestamps —
    # steady-state skips, intentionally silent to match pre-refactor behavior.
    end
  end

  def retranscribe_for_timestamps(mp3_path, ts_path, base_name)
    language = @config.transcription_language
    unless language
      puts "  ⚠ #{base_name}: no transcription language configured, skipping subtitles" unless quiet?
      return
    end

    engine_code = pick_timestamp_engine
    unless engine_code
      puts "  ⚠ #{base_name}: no transcription engine configured, skipping subtitles" unless quiet?
      return
    end

    puts "  transcribing #{base_name} for subtitles (#{engine_code})..." unless quiet?

    require_relative "transcription/engine_manager"
    require_relative "timestamp_persister"

    manager = Transcription::EngineManager.new(
      engine_codes: [engine_code],
      language: language,
      target_language: @config.target_language
    )
    result = manager.transcribe(mp3_path)
    segments, engine_code = TimestampPersister.extract_segments(result, engine_codes: [engine_code])

    if segments && !segments.empty?
      TimestampPersister.persist(
        segments: segments,
        engine: engine_code,
        intro_duration: 0.0,
        output_path: ts_path
      )
    else
      puts "  ⚠ #{base_name}: transcription returned no segments" unless quiet?
    end
  rescue => e # skippable: video uploads without subtitles; regen can add them later
    $stderr.puts "  ⚠ #{base_name}: retranscription failed (#{e.class}: #{e.message}), uploading without subtitles"
  end

  def pick_timestamp_engine
    configured = @config.transcription_engines
    TIMESTAMP_ENGINE_PRIORITY.find { |e| configured.include?(e) } || configured.first
  end

  def active_uploader
    @uploader ||= YouTubeUploader.new(logger: @logger)
  end
end
