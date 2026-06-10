# frozen_string_literal: true

require_relative "upload_tracker"
require_relative "subtitle_generator"
require_relative "video_generator"
require_relative "cover_resolver"
require_relative "agents/lingq_agent"

# Post-commit upload side effects for the language pipeline (LingQ and
# YouTube), extracted from LanguagePipeline so they are testable without
# running a pipeline.
#
# Both steps are skippable per the error-severity policy: the canonical
# episode is already committed, failures are logged with their exception
# class and recorded in #warnings, and the UploadTracker-based retry on the
# next `podgen publish` picks them up.
class PostPipelineUploads
  attr_reader :warnings

  def initialize(config:, logger:, dry_run: false)
    @config = config
    @logger = logger
    @dry_run = dry_run
    @warnings = []
  end

  # image_path: pre-resolved episode cover (the pipeline owns cover
  # resolution); nil uploads without an image.
  def upload_to_lingq(episode:, transcript:, audio_path:, base_name:, image_path: nil)
    return unless @config.lingq_enabled?

    if @dry_run
      @logger.log("[dry-run] Skipping LingQ upload")
      return
    end

    @logger.phase_start("LingQ Upload")
    lc = @config.lingq_config

    agent = LingQAgent.new(logger: @logger, api_key: lc&.[](:token))
    lesson_id = agent.upload(
      title: episode[:title],
      text: transcript,
      audio_path: audio_path,
      language: @config.transcription_language,
      collection: lc[:collection],
      level: lc[:level],
      tags: lc[:tags],
      image_path: image_path,
      accent: lc[:accent],
      status: lc[:status],
      description: episode[:description],
      original_url: episode[:link]
    )

    # Record in tracking so publish --lingq doesn't re-upload
    record_lingq_upload(lc[:collection], base_name, lesson_id)

    @logger.phase_end("LingQ Upload")
  rescue => e # skippable: side effect after commit; tracker-based retry on next publish
    @logger.log("Warning: LingQ upload failed: #{e.class}: #{e.message} (non-fatal, continuing)")
    @logger.log(e.backtrace.first(3).join("\n"))
    @warnings << "LingQ upload failed (#{e.class}: #{e.message})"
  end

  def record_lingq_upload(collection, base_name, lesson_id)
    UploadTracker.for_config(@config).record(:lingq, collection, base_name, lesson_id)
    @logger.log("Recorded LingQ upload: #{base_name} → lesson #{lesson_id}")
  end

  def upload_to_youtube(episode:, base_name:, output_path:)
    unless @config.youtube_enabled?
      @logger.log("YouTube not configured — skipping upload")
      return
    end

    if @dry_run
      @logger.log("[dry-run] Skipping YouTube upload")
      return
    end

    @logger.phase_start("YouTube Upload")
    yt_config = @config.youtube_config
    language = @config.transcription_language || "en"

    # Generate SRT from timestamps
    ts_path = File.join(@config.episodes_dir, "#{base_name}_timestamps.json")
    srt_path = File.join(@config.episodes_dir, "#{base_name}.srt")
    SubtitleGenerator.generate_srt(ts_path, srt_path) if File.exist?(ts_path)

    # Generate video from cover + audio
    cover_path = CoverResolver.find_episode_cover(@config.episodes_dir, base_name)
    raise "No episode cover found for video generation" unless cover_path

    video_path = File.join(@config.episodes_dir, "#{base_name}.mp4")
    VideoGenerator.new(logger: @logger).generate(output_path, cover_path, video_path)

    # Upload to YouTube (lazy require to avoid loading google-apis gems unless needed)
    require_relative "youtube_uploader"
    uploader = YouTubeUploader.new(logger: @logger)
    uploader.authorize!

    # Verify playlist exists before uploading
    uploader.verify_playlist!(yt_config[:playlist]) if yt_config[:playlist]

    video_id = uploader.upload_video(
      video_path,
      title: episode[:title],
      description: episode[:description].to_s,
      language: language,
      privacy: yt_config[:privacy] || "unlisted",
      category: yt_config[:category] || "27",
      tags: yt_config[:tags] || []
    )

    # Upload captions if SRT exists
    uploader.upload_captions(video_id, srt_path, language: language) if File.exist?(srt_path)

    # Add to playlist if configured
    uploader.add_to_playlist(video_id, yt_config[:playlist]) if yt_config[:playlist]

    # Record upload
    playlist = yt_config[:playlist] || "default"
    UploadTracker.for_config(@config).record(:youtube, playlist, base_name, video_id)
    @logger.log("Recorded YouTube upload: #{base_name} → #{video_id}")

    @logger.phase_end("YouTube Upload")
  rescue => e # skippable: side effect after commit; tracker-based retry on next publish
    @logger.log("Warning: YouTube upload failed: #{e.class}: #{e.message} (non-fatal, continuing)")
    @logger.log(e.backtrace.first(3).join("\n"))
    @warnings << "YouTube upload failed (#{e.class}: #{e.message})"
  end
end
