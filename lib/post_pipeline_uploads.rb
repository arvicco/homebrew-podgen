# frozen_string_literal: true

require_relative "upload_tracker"
require_relative "subtitle_generator"
require_relative "video_generator"
require_relative "cover_resolver"
require_relative "youtube_publisher"
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
  rescue LingQAgent::LessonExists => e # tracking success: the lesson is on LingQ, record it as LingQPublisher does (Q-82)
    begin
      record_lingq_upload(lc[:collection], base_name, e.lesson_id)
      @logger.log("  LingQ: lesson already exists (#{e.lesson_id}) — recorded")
      @logger.phase_end("LingQ Upload")
    rescue => record_error # skippable: side effect after commit; tracker-based retry on next publish
      @logger.log("Warning: LingQ upload failed: recording existing lesson #{e.lesson_id}: " \
        "#{record_error.class}: #{record_error.message} (non-fatal, continuing)")
      @warnings << "LingQ upload failed (#{record_error.class}: #{record_error.message})"
    end
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

    # One upload routine shared with publish/yt-batch (P4-8). The pipeline's
    # in-memory title/description win over the transcript file, and its fresh
    # timestamps are authoritative (no re-transcription, no second reconcile).
    # The uploader authorizes lazily on first API call.
    publisher = YouTubePublisher.new(config: @config, logger: @logger)
    ep = {
      base_name: base_name,
      mp3_path: output_path,
      transcript_path: File.join(@config.episodes_dir, "#{base_name}_transcript.md")
    }
    result = publisher.upload_episode(ep,
      metadata: {title: episode[:title], description: episode[:description]},
      timestamps_authoritative: true)

    # The routine records the upload right after upload_video (P4-0), so a
    # captions/playlist failure still leaves the video tracked.
    @logger.log("Recorded YouTube upload: #{base_name} → #{result.video_id}") if result.video_id
    raise_for(result) unless result.status == :uploaded

    @logger.phase_end("YouTube Upload")
  rescue => e # skippable: side effect after commit; tracker-based retry on next publish
    text = YouTubePublisher.auth_failure_summary(e) || "#{e.class}: #{e.message}" # no token-endpoint body in the log
    @logger.log("Warning: YouTube upload failed: #{text} (non-fatal, continuing)")
    @logger.log(e.backtrace.first(3).join("\n"))
    @warnings << "YouTube upload failed (#{text})"
  end

  private

  # Maps the routine's typed result onto the pipeline's skippable-warning
  # path (the rescue above); a quota stop is just another warning here.
  def raise_for(result)
    raise result.exception if result.exception
    raise "No episode cover found for video generation" if result.error[:type] == :missing_cover

    raise result.error[:message]
  end
end
